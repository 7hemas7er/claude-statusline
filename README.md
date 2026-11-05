# claude-statusline

A two-line status line for [Claude Code](https://claude.com/claude-code).

```
user@host:dir │ Opus ctx ▰▰▰▰▱▱▱▱▱▱ 43% /200k
⚙ high │ ⎇ main ↑1 ✱3 │ ▶ GSD phase │ $1.23 +10/-2 ⏱ 2m05s ◷ 5h 12% · 7g 33%
```

- **Line 1:** identity, model, context bar.
- **Line 2:** effort, git (branch, ahead/behind, changes, worktree), the active GSD
  action when `.planning/STATE.md` exists, cost, lines changed, duration, and 5-hour
  and 7-day quota.

The 7-day quota is colored by pace rather than by absolute value: it turns yellow or
red when the current rate would run out before the reset.

## Install

Requires `git` and `jq`.

```sh
curl -fsSL https://raw.githubusercontent.com/7hemas7er/claude-statusline/main/install.sh | bash
```

The script clones the repo into `~/.local/share/claude-statusline` (override with
`CLAUDE_STATUSLINE_DIR`), symlinks the scripts into `~/.claude` and sets `statusLine`
in `settings.json`, leaving the other keys untouched. Any file it replaces is kept
next to the original with a `.bak.<date>` suffix.

## Update

Run the same command again.

## Customize

The files in `~/.claude` are symlinks to the clone: edit them there, then commit and
push.

## Untrusted repositories

The status line refreshes in whatever directory Claude Code is running, so it treats
repositories as untrusted. Repo-local configuration cannot make it run commands
through `core.fsmonitor`, hooks, nested bare repositories, submodules or lazy fetches
in partial clones, and control characters are stripped from directory names, branch
names and `STATE.md` before they are printed.

Clean filters defined in a repository's own config cannot be disabled, so the change
count is skipped there and shows `✱?`. Filters from your global config, such as
`git-lfs`, are not affected.

## Tests

```sh
tests/run.sh
```

Needs `bash`, `git` and `jq`. CI runs them on Linux and macOS.
