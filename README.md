# prod-not-merged

Find code that is **deployed to production but not merged** into the default branch.

Some teams deploy a feature branch to production before merging it. When the merge is
forgotten, production runs code that no longer exists in `master`, and the next deploy
from `master` silently reverts it. This tool finds that state.

It is both a standalone shell script and a [Claude Code](https://claude.com/claude-code) skill.

## Requirements

- [`gh`](https://cli.github.com) — authenticated (`gh auth login`)
- [`jq`](https://jqlang.github.io/jq/)
- `bash` 4+ (macOS ships 3.2; the script is tested against the system `bash` via `/usr/bin/env bash`)

No CI token is needed. CircleCI, GitHub Actions and most other providers report each
workflow back to GitHub as a **check run**, and that is what the script reads.

## Use as a script

```bash
./check-prod-drift.sh --repo owner/name --days 30
```

```
Repo: owner/name   Base: master   Branches scanned: 54 (since 2026-08-16)
Deployed to prod, NOT merged into master: 1

  feature/work-39809-dd-library-layout-updates
    deployed: 2026-09-15T14:45:07Z   commits ahead: 7
    PR: #9041 [open] DD :: Library Layout Updates — tetiana-husieva-op
    https://github.com/owner/name/pull/9041
```

| Option | Meaning |
|---|---|
| `--repo <owner/name>` | Repository. Defaults to the repo of the current directory. |
| `--days <n>` | Only scan branches with commits newer than n days. Default 30. |
| `--pattern <str>` | Check-run name prefix that means "production deploy". Default `BuildAndDeploy_Prod`. |
| `--jobs <n>` | Parallel probes. Default 4. Higher values can trip GitHub secondary rate limits. |
| `--json` | Machine-readable output, for chaining into Slack or a report. |

A 650-branch repo scanned over a 30-day window takes about 10 seconds.

## Use as a Claude Code skill

Clone the repo and link it into your skills directory:

```bash
git clone git@github.com:jackmparker/prod-not-merged.git ~/Developer/prod-not-merged
ln -s ~/Developer/prod-not-merged ~/.claude/skills/prod-not-merged
```

Then ask Claude "is anything deployed to prod but not merged in?", or run `/prod-not-merged`.

## Configure for your repo

The `--pattern` default matches one CircleCI workflow name. List the check runs on a
recent commit to find yours:

```bash
gh api "repos/<owner>/<name>/commits/<sha>/check-runs" --jq '.check_runs[].name'
```

Then pass the production one:

```bash
./check-prod-drift.sh --repo owner/name --pattern 'Deploy Production'
```

## How it decides

1. List every branch with its head commit, via the GitHub GraphQL API.
2. Keep branches with commits newer than `--days`. Skip `dependabot/*` and the default branch.
3. For each head commit, read its check runs. Keep the branch only if a check run whose
   name starts with `--pattern` concluded `success`.
4. Compare `default_branch...head`. Status `ahead` or `diverged` means commits are missing
   from the default branch; `identical` or `behind` means it is already merged.
5. Attach the pull request for that commit.

## Limits

- Only the **head commit** of each branch is checked. A deploy from an older commit on a
  branch that has since moved is not reported.
- Branches older than `--days` are not scanned.
- A branch deleted after its production deploy cannot be found at all.
- A `cancelled` or still-on-hold check run is ignored, which is correct: nothing shipped.

## Exit codes

`0` on success, whether or not drift was found. Non-zero only on a real failure
(missing `gh`/`jq`, unknown repo, API error).

## License

MIT
