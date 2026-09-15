---
name: prod-not-merged
description: Find code that is deployed to production but not merged into the default branch. Use when the user asks "what is in prod but not merged", "is anything deployed but not merged in", "check for prod drift", or asks which branch is currently live in production. Works on any GitHub repo whose production deploy reports a check run.
---

# Prod-not-merged check

Source: https://github.com/jackmparker/prod-not-merged

Reports every branch that has a **successful production deploy** whose commits are **not contained in the default branch**.

On teams that deploy this way, engineers deploy a feature branch to production before merging it. If the merge is forgotten, production runs code that is not in `master`. The next deploy from `master` silently reverts it. This skill finds that state.

## Run it

Run the script from this skill's base directory:

```bash
<skill-base-dir>/check-prod-drift.sh --repo owner/name --days 30
```

When installed the usual way, that path is
`~/.claude/skills/prod-not-merged/check-prod-drift.sh`.

Options:

| Option | Meaning |
|---|---|
| `--repo <owner/name>` | Repository. Defaults to the repo of the current directory. |
| `--days <n>` | Only scan branches with commits newer than n days. Default 30. |
| `--pattern <str>` | Check-run name prefix that means "production deploy". Default `BuildAndDeploy_Prod`. |
| `--jobs <n>` | Parallel probes. Default 4. Raising it can trip GitHub secondary rate limits. |
| `--json` | Machine-readable output, for chaining into Slack or a report. |

A 650-branch repo scanned over a 30-day window takes about 10 seconds.

## How it decides

1. List every branch with its head commit, via the GitHub GraphQL API.
2. Keep branches with commits newer than `--days`. Skip `dependabot/*` and the default branch.
3. For each head commit, read its GitHub check runs. Keep the branch only if a check run whose name starts with `--pattern` has conclusion `success`.
4. Compare `default_branch...head`. Status `ahead` or `diverged` means commits are missing from the default branch. `identical` or `behind` means it is already merged.
5. Attach the pull request for that commit.

Authentication is the `gh` CLI only. CircleCI needs no token, because CircleCI reports each workflow back to GitHub as a check run.

## Configure for your repo

The `--pattern` default matches one CircleCI workflow name. For another repo, list the check-run names on a recent commit first:

```bash
gh api "repos/<owner>/<name>/commits/<sha>/check-runs" --jq '.check_runs[].name'
```

Then pass the production one to `--pattern`.

## Known limits

State these when you report results:

- Only the **head commit** of each branch is checked. A deploy from an older commit on a branch that has since moved is not reported.
- Branches older than `--days` are not scanned. Raise `--days` for a wider sweep.
- A branch deleted after its prod deploy cannot be found at all.
- A check run that was `cancelled` or is still on hold is correctly ignored — nothing shipped.

## Reporting to the user

Lead with the count. For each hit give: PR number, title, author, deploy time, commits ahead, and the PR URL. Close with one action — merge the PR, or ping the author.
