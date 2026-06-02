# hansel-pr-arm

A [SwiftBar](https://swiftbar.app) menu-bar widget that lists your open authored GitHub PRs, grouped by status, and **auto-merges the ones you arm** the moment they're approved + green.

```
🔖 7  ⚡2          ← total open · armed (menu-bar title)

7 open · 2 ready · 2 armed · updated just now
Refresh · Arm ALL · Disarm ALL · Logs
──────────────────────────────────
✅ READY TO MERGE  ·  2
   actions#597            bump eslint…
   user-profile#300       fix dep…        ⚡
⚡ ARMED · WAITING  ·  1
   configs#519            add column…      ⚡
⚠️ NEEDS ATTENTION  ·  2
   orders#42              refactor…
   rates#85               revert…
⏳ WAITING ON REVIEW / CI  ·  1
💤 DRAFTS  ·  1
```

Click any PR row to **arm/disarm** auto-merge. Each row's submenu: **Arm/Disarm · Open in browser · Merge + Delete**.

## How it works

- Lists PRs via `gh api graphql` (`author:@me is:pr is:open`), paginated at 25/page (the `statusCheckRollup` field 502s above that).
- The menu **renders instantly from a cached snapshot** (`~/.pr-merge-queue/last.json`); a detached background fetch refreshes GitHub data + runs the merge engine, then asks SwiftBar to redraw. Opening the menu never blocks on the network.
- **Merge engine** (runs each fetch): any *armed* PR that is `APPROVED` and has checks `SUCCESS` **or no checks** (`NONE`) is merged with **merge commit + delete branch** (`gh pr merge --merge --delete-branch`), then a native notification fires. PRs with `PENDING`/`FAILURE` checks are never auto-merged.
- **Completeness gate:** if a fetch returns fewer PRs than `issueCount` (search rate-limit / 502), the engine is skipped that cycle — a partial fetch can never trigger a wrong merge.
- **Blacklist:** repos in the `BLACKLIST` var are never listed, armed, or merged.
- **Audit log** (`~/.pr-merge-queue/merge.log`): every action is tagged `[user]` (menu clicks) or `[engine]` (auto-merge / background fetch), so you can tell what merged on its own vs. what you did.

## Install

1. Install SwiftBar: `brew install --cask swiftbar`
2. Point SwiftBar at a plugin folder, drop `prmerge.1m.sh` in it, `chmod +x` it.
3. Ensure the GitHub CLI is installed and authenticated: `gh auth status`.
4. **Edit the config block at the top of the script** for your machine:
   - `SELF` — absolute path to the installed script (used by click-actions).
   - `BLACKLIST` — space-separated `owner/repo` entries to hide.
   - `PATH` — adjust if `gh`/`jq` live elsewhere (SwiftBar runs with a minimal PATH).

The `.1m.` in the filename sets the refresh interval (1 minute).

## State files

| Path | Role |
|------|------|
| `~/.pr-merge-queue/armed.txt` | armed PRs (one `owner/repo#number` per line) |
| `~/.pr-merge-queue/last.json` | cached PR snapshot the menu renders from |
| `~/.pr-merge-queue/merge.log` | audit log of arms/disarms/merges |

## Requirements

macOS · SwiftBar · `gh` (authenticated, `repo` scope) · `jq`
