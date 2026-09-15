#!/usr/bin/env bash
# Find branches deployed to production whose commits are not in the default branch.
# Data source: GitHub REST + GraphQL only (CircleCI results arrive as GitHub check runs).
set -uo pipefail

REPO=""
DAYS=30
PATTERN="BuildAndDeploy_Prod"
FORMAT="text"
JOBS=4

usage() {
  cat <<USAGE
Usage: check-prod-drift.sh [options]

  --repo <owner/name>   Repository. Default: inferred from the current git remote.
  --days <n>            Only scan branches with commits newer than n days. Default: 30.
  --pattern <str>       Check-run name prefix that means "production deploy".
                        Default: BuildAndDeploy_Prod
  --jobs <n>            Parallel branch probes. Default: 4. Higher values can trip
                        GitHub secondary rate limits.
  --json                Emit JSON instead of a table.
USAGE
}

# Internal mode: probe one branch. Args: repo base pattern "date<TAB>branch<TAB>sha"
if [ "${1:-}" = "--probe" ]; then
  _repo="$2"; _base="$3"; _pattern="$4"
  IFS=$'\t' read -r _date _branch _oid <<< "$5"

  _deploy=$(gh api "repos/$_repo/commits/$_oid/check-runs" --paginate \
    --jq "[.check_runs[] | select(.name | startswith(\"$_pattern\")) | select(.conclusion == \"success\")]
          | sort_by(.completed_at) | last // empty" 2>/dev/null)
  [ -n "$_deploy" ] || exit 0

  _cmp=$(gh api "repos/$_repo/compare/$_base...$_oid" --jq '{status, ahead_by}' 2>/dev/null)
  case "$(jq -r .status <<< "$_cmp")" in
    ahead|diverged) ;;
    *) exit 0 ;;   # identical or behind: already contained in the base branch
  esac

  # PR lookup, with one retry and a branch-name fallback: GitHub secondary rate
  # limits make a single parallel call unreliable, and a silent miss here would
  # read as "no PR" rather than "lookup failed".
  _pr=""
  for _try in 1 2; do
    _pr=$(gh api "repos/$_repo/commits/$_oid/pulls" \
      --jq '[.[] | {number, title, state, url: .html_url, author: .user.login}] | first // empty' 2>/dev/null)
    [ -z "$_pr" ] || break
    sleep 1
  done
  if [ -z "$_pr" ]; then
    _pr=$(gh api "repos/$_repo/pulls?state=all&head=${_repo%%/*}:$_branch" \
      --jq '[.[] | {number, title, state, url: .html_url, author: .user.login}] | first // empty' 2>/dev/null)
  fi

  jq -n --argjson deploy "$_deploy" --argjson cmp "$_cmp" --argjson pr "${_pr:-null}" \
    --arg branch "$_branch" --arg oid "$_oid" '
      {branch: $branch, sha: $oid, ahead_by: $cmp.ahead_by, compare: $cmp.status,
       deployed_at: $deploy.completed_at, workflow_url: $deploy.details_url, pr: $pr}'
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
[ -n "$REPO" ] || { echo "No repo given and none inferred. Use --repo owner/name." >&2; exit 1; }

if date -u -v-1d +%Y-%m-%d >/dev/null 2>&1; then
  CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%d)
else
  CUTOFF=$(date -u -d "${DAYS} days ago" +%Y-%m-%d)
fi

BASE=$(gh api "repos/$REPO" --jq .default_branch) || exit 1

BRANCHES=$(gh api graphql --paginate -f query='
  query($owner:String!, $name:String!, $endCursor:String) {
    repository(owner:$owner, name:$name) {
      refs(refPrefix:"refs/heads/", first:100, after:$endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { name target { ... on Commit { oid committedDate } } }
      }
    }
  }' -f owner="${REPO%%/*}" -f name="${REPO##*/}" \
  --jq '.data.repository.refs.nodes[] | select(.target != null)
        | "\(.target.committedDate)\t\(.name)\t\(.target.oid)"') || exit 1

CANDIDATES=$(awk -F'\t' -v cutoff="$CUTOFF" -v base="$BASE" '
  substr($1,1,10) > cutoff && $2 != base && $2 !~ /^dependabot\// {print}' <<< "$BRANCHES")
SCANNED=$(grep -c . <<< "$CANDIDATES")
[ -n "$CANDIDATES" ] || SCANNED=0

SELF="${BASH_SOURCE[0]}"
RESULTS="[]"
if [ "$SCANNED" -gt 0 ]; then
  TMPDIR_RUN=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_RUN"' EXIT
  i=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i + 1))
    "$SELF" --probe "$REPO" "$BASE" "$PATTERN" "$line" > "$TMPDIR_RUN/$i.json" 2>/dev/null &
    while [ "$(jobs -pr | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; done
  done <<< "$CANDIDATES"
  wait
  RESULTS=$(cat "$TMPDIR_RUN"/*.json 2>/dev/null | jq -s 'sort_by(.deployed_at) | reverse')
  [ -n "$RESULTS" ] || RESULTS="[]"
fi

if [ "$FORMAT" = "json" ]; then
  jq -n --argjson r "$RESULTS" --arg repo "$REPO" --arg base "$BASE" \
    --argjson scanned "$SCANNED" --arg cutoff "$CUTOFF" \
    '{repo:$repo, base:$base, since:$cutoff, branches_scanned:$scanned, deployed_not_merged:$r}'
  exit 0
fi

COUNT=$(jq 'length' <<< "$RESULTS")
echo "Repo: $REPO   Base: $BASE   Branches scanned: $SCANNED (since $CUTOFF)"
if [ "$COUNT" -eq 0 ]; then
  echo "Nothing deployed to prod that is missing from $BASE."
  exit 0
fi
echo "Deployed to prod, NOT merged into $BASE: $COUNT"
echo
jq -r '.[] | "  \(.branch)\n    deployed: \(.deployed_at)   commits ahead: \(.ahead_by)\n    PR: \(if .pr then "#\(.pr.number) [\(.pr.state)] \(.pr.title) — \(.pr.author)\n    \(.pr.url)" else "none found for \(.sha[0:9])" end)\n"' <<< "$RESULTS"
