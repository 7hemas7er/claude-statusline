#!/usr/bin/env bash
# Tests for the status line and its installer. Needs bash, git and jq; no network.
# Usage: tests/run.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
W=$(cd "$(mktemp -d)" && pwd -P)
trap 'cd /; rm -rf "$W"' EXIT

H=$W/home
mkdir -p "$H"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$W/gitconfig
git config --global user.email test@example.com
git config --global user.name test
git config --global init.defaultBranch main
git config --global protocol.file.allow always

HOME=$H bash "$ROOT/install.sh" >/dev/null

passed=0 failed=0
ok()     { printf 'ok     - %s\n' "$1"; passed=$((passed + 1)); }
not_ok() { printf 'NOT OK - %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; failed=$((failed + 1)); }
expect() {  # $1=name $2=haystack $3=needle
  case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1" "missing '$3' in: $2" ;; esac
}
reject() {  # $1=name $2=haystack $3=needle
  case "$2" in *"$3"*) not_ok "$1" "unexpected '$3' in: $2" ;; *) ok "$1" ;; esac
}

ESC=$(printf '\033')
json() {
  jq -n --arg d "$1" '{
    workspace: {current_dir: $d}, model: {display_name: "Opus"}, effort: {level: "high"},
    context_window: {used_percentage: 42.7, context_window_size: 200000},
    cost: {total_cost_usd: 1.2345, total_lines_added: 10, total_lines_removed: 2, total_duration_ms: 125000},
    rate_limits: {five_hour: {used_percentage: 12.5}, seven_day: {used_percentage: 33.3, resets_at: 1999999999}}}'
}
raw()    { json "$1" | HOME=$H bash "$H/.claude/hooks/statusline-git.sh" 2>"$W/stderr"; }
render() { raw "$1" | sed -E "s/$ESC\[[0-9;]*m//g"; }

new_repo() {
  git init -q "$1"
  echo x > "$1/f.txt"
  git -C "$1" add .
  git -C "$1" commit -qm init
}

# Script that leaves a marker when something executes it.
mark() {
  printf '#!/bin/sh\ntouch "%s/hit-%s"\nexit 0\n' "$W" "$1" > "$W/$1.sh"
  chmod +x "$W/$1.sh"
}

# The status line must not fire the vector, and plain git must: without the second
# half a git upgrade that defuses the fixture would turn this into an empty pass.
no_exec() {  # $1=vector $2=repo [git args that fire it, default: status]
  local name=$1 repo=$2
  shift 2
  [ $# -gt 0 ] || set -- status --porcelain
  set -- "$name" "$repo" "$@"
  render "$2" >/dev/null
  if [ -e "$W/hit-$1" ]; then not_ok "exec: $1 is blocked"; else ok "exec: $1 is blocked"; fi
  git -C "$repo" "${@:3}" >/dev/null 2>&1
  if [ -e "$W/hit-$1" ]; then ok "exec: $1 fixture fires with plain git"
  else not_ok "exec: $1 fixture fires with plain git"; fi
}

# --- Code execution from repo-controlled config --------------------------------
mark fsmonitor
new_repo "$W/fsmonitor"
git -C "$W/fsmonitor" config core.fsmonitor "$W/fsmonitor.sh"
no_exec fsmonitor "$W/fsmonitor"

mark hook
new_repo "$W/hook"
printf '#!/bin/sh\n"%s/hook.sh"\n' "$W" > "$W/hook/.git/hooks/post-index-change"
chmod +x "$W/hook/.git/hooks/post-index-change"
sleep 1; touch "$W/hook/f.txt"
no_exec hook "$W/hook"

mark filter
new_repo "$W/filter"
echo '*.txt filter=x' > "$W/filter/.gitattributes"
git -C "$W/filter" add .
git -C "$W/filter" commit -qm attrs
git -C "$W/filter" config filter.x.clean "$W/filter.sh; cat"
sleep 1; touch "$W/filter/f.txt"
no_exec filter "$W/filter"

mark submodule
new_repo "$W/sub-src"
new_repo "$W/submodule"
git -C "$W/submodule" submodule --quiet add "$W/sub-src" sub
git -C "$W/submodule" commit -qm sub
git config -f "$(git -C "$W/submodule/sub" rev-parse --absolute-git-dir)/config" core.fsmonitor "$W/submodule.sh"
sleep 1; touch "$W/submodule/sub/f.txt"
no_exec submodule "$W/submodule"

mark bare
mkdir -p "$W/bare/objects" "$W/bare/refs" "$W/bare/wt"
echo 'ref: refs/heads/main' > "$W/bare/HEAD"
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = wt\n\tfsmonitor = %s\n' "$W/bare.sh" > "$W/bare/config"
no_exec bare "$W/bare"

mark lazy
git init -q "$W/srv"
git -C "$W/srv" config uploadpack.allowFilter true
git -C "$W/srv" config uploadpack.allowAnySHA1InWant true
seq 1 200 > "$W/srv/f.txt"
git -C "$W/srv" add .
git -C "$W/srv" commit -qm one
old_blob=$(git -C "$W/srv" rev-parse HEAD:f.txt)
echo end >> "$W/srv/f.txt"
git -C "$W/srv" add .
git -C "$W/srv" commit -qm two
git clone -q --no-checkout --filter=blob:none "file://$W/srv" "$W/lazy" 2>/dev/null
git -C "$W/lazy" config remote.origin.url ssh://x/y
git -C "$W/lazy" config core.sshCommand "$W/lazy.sh"
git -C "$W/lazy" read-tree --empty
printf '100644 %s\trenamed.txt\n' "$old_blob" | git -C "$W/lazy" update-index --index-info
no_exec lazy "$W/lazy"

# Taken before the server moves on, so the commit below is missing from it.
git clone -q --no-checkout --filter=blob:none "file://$W/srv" "$W/lazy-upstream" 2>/dev/null

echo more >> "$W/srv/f.txt"
git -C "$W/srv" add .
git -C "$W/srv" commit -qm three
missing=$(git -C "$W/srv" rev-parse HEAD)

promisor_clone() {  # $1=repo $2=filter
  git clone -q --no-checkout "--filter=$2" "file://$W/srv" "$1" 2>/dev/null
  git -C "$1" config remote.origin.url ssh://x/y
}
ahead_behind=(rev-list --left-right --count '@{upstream}...HEAD')

# @{upstream} points at a commit the repo does not have.
mark lazy-upstream
git -C "$W/lazy-upstream" config remote.origin.url ssh://x/y
git -C "$W/lazy-upstream" config core.sshCommand "$W/lazy-upstream.sh"
echo "$missing" > "$W/lazy-upstream/.git/refs/remotes/origin/main"
no_exec lazy-upstream "$W/lazy-upstream" "${ahead_behind[@]}"

# HEAD exists but its tree is missing: status needs it even with --no-renames.
mark lazy-tree
promisor_clone "$W/lazy-tree" tree:0
git -C "$W/lazy-tree" config core.sshCommand "$W/lazy-tree.sh"
no_exec lazy-tree "$W/lazy-tree"

# The repo re-enables a transport that runs commands, so protocol.allow is not enough.
mark lazy-ext
promisor_clone "$W/lazy-ext" tree:0
git -C "$W/lazy-ext" config remote.origin.url "ext::$W/lazy-ext.sh"
git -C "$W/lazy-ext" config protocol.ext.allow always
no_exec lazy-ext "$W/lazy-ext"
expect "status failure shows unknown, not clean" "$(render "$W/lazy-ext")" '✱?'

# --- Terminal escapes and format strings ----------------------------------------
D=$W/$'esc\033]0;title\007%s%n\\x41'
new_repo "$D"
mkdir "$D/.planning" "$D/sub"
printf 'stopped_at: ok\033[2Jend\302\233""31m\302\302\233\233\n' > "$D/.planning/STATE.md"
git -C "$D" checkout -qb $'branch\302\233name'

has_controls() {  # true if anything but newlines is a control character
  printf '%s' "$1" | jq -Rrs 'gsub("\n"; "") | test("\\p{Cc}")'
}
out=$(render "$D")
[ "$(has_controls "$out")" = false ] && ok "escape: stripped from dir, branch, STATE.md" \
  || not_ok "escape: stripped from dir, branch, STATE.md" "$(printf '%s' "$out" | cat -v)"
expect "escape: format specifiers stay literal" "$out" '%s%n\x41'
expect "escape: model segment survives"          "$out" 'Opus'
out=$(render "$D/sub")
[ "$(has_controls "$out")" = false ] && ok "escape: stripped from worktree name" \
  || not_ok "escape: stripped from worktree name" "$(printf '%s' "$out" | cat -v)"

# --- Normal behavior ------------------------------------------------------------
new_repo "$W/up"
git clone -q "$W/up" "$W/r"

out=$(render "$W/r")
expect "git: branch"             "$out" '⎇ main'
reject "git: clean has no count" "$out" '✱'
expect "line 1: identity+context" "$out" 'ctx ▰▰▰▰▱▱▱▱▱▱ 43% /200k'
expect "line 2: cost and quota"  "$out" '$1.23 +10/-2 ⏱ 2m05s ◷ 5h 12%'
[ -s "$W/stderr" ] && not_ok "no stderr" "$(cat "$W/stderr")" || ok "no stderr"

echo y > "$W/r/f.txt"; echo n > "$W/r/new.txt"
expect "git: two changes" "$(render "$W/r")" '✱2'

git -C "$W/r" add f.txt
git -C "$W/r" commit -qm local
out=$(render "$W/r")
expect "git: ahead"       "$out" '↑1'
expect "git: still dirty" "$out" '✱1'

mkdir "$W/r/dir"
expect "git: subdirectory shows worktree name" "$(render "$W/r/dir")" '⌂ r'

(cd "$W/up" && echo 2 > g.txt && git add . && git commit -qm upstream)
git -C "$W/r" fetch -q
expect "git: behind" "$(render "$W/r")" '↓1'

git -C "$W/r" checkout -q --detach
expect "git: detached shows short sha" "$(render "$W/r")" "⎇ $(git -C "$W/r" rev-parse --short HEAD)"
git -C "$W/r" checkout -q main

git config --global filter.lfs.clean 'git-lfs clean -- %f'
out=$(render "$W/r")
expect "filter: global one keeps the count" "$out" '✱1'
git config --global --unset filter.lfs.clean

git -C "$W/r" config filter.x.clean cat
reject "filter: local one hides the number" "$(render "$W/r")" '✱1'
expect "filter: local one shows unknown" "$(render "$W/r")" '✱?'
git -C "$W/r" config --unset filter.x.clean

printf '[filter "x"]\n\tclean = cat\n' > "$W/included"
git -C "$W/r" config include.path "$W/included"
expect "filter: included from local config shows unknown" "$(render "$W/r")" '✱?'
git -C "$W/r" config --unset include.path

mkdir "$W/plain"
reject "git: outside a repo there is no segment" "$(render "$W/plain")" '⎇'

mkdir "$W/r/.planning"
printf 'stopped_at: "Phase 3: più caffè"\n' > "$W/r/.planning/STATE.md"
expect "gsd: action with UTF-8" "$(render "$W/r")" '▶ Phase 3: più caffè'
printf 'stopped_at: %s\n' "$(printf 'è%.0s' $(seq 1 80))" > "$W/r/.planning/STATE.md"
expect "gsd: truncated on characters" "$(render "$W/r")" "$(printf 'è%.0s' $(seq 1 60))…"

# --- Locale ---------------------------------------------------------------------
it=$(locale -a 2>/dev/null | grep -iE '^it_IT\.utf-?8$' | head -1)
if [ -n "$it" ]; then
  for var in LC_ALL LANG; do
    out=$(json "$W/plain" | env "$var=$it" HOME="$H" bash "$H/.claude/hooks/statusline-git.sh" 2>"$W/stderr" \
      | sed -E "s/$ESC\[[0-9;]*m//g")
    expect "locale: $var keeps the decimal point" "$out" '$1.23'
    expect "locale: $var rounds percentages"      "$out" '43%'
    [ -s "$W/stderr" ] && not_ok "locale: $var no stderr" "$(cat "$W/stderr")" || ok "locale: $var no stderr"
  done
elif [ -n "${CI:-}" ]; then
  not_ok "locale: it_IT is available in CI"
else
  printf 'skip   - locale: it_IT not installed\n'
fi

# --- Installer ------------------------------------------------------------------
I=$W/i1
mkdir -p "$I/.claude"
echo '{"theme":"dark","statusLine":{"type":"command","command":"old"}}' > "$I/.claude/settings.json"
echo old > "$I/.claude/statusline-command.sh"
HOME=$I bash "$ROOT/install.sh" >/dev/null
expect "install: sets the command"  "$(cat "$I/.claude/settings.json")" 'statusline-git.sh'
expect "install: keeps other keys"  "$(cat "$I/.claude/settings.json")" '"theme": "dark"'
[ "$(readlink "$I/.claude/statusline-command.sh")" = "$ROOT/statusline-command.sh" ] \
  && ok "install: symlinks the scripts" || not_ok "install: symlinks the scripts"
count_backups() {
  set -- "$I/.claude"/*.bak.*
  if [ -e "$1" ]; then echo "$#"; else echo 0; fi
}
baks=$(count_backups)
[ "$baks" = 2 ] && ok "install: backs up replaced files" || not_ok "install: backs up replaced files" "got $baks"
expect "install: backup holds the old file" "$(cat "$I/.claude"/statusline-command.sh.bak.*)" old
HOME=$I bash "$ROOT/install.sh" >/dev/null
[ "$(count_backups)" = "$baks" ] && ok "install: idempotent" || not_ok "install: idempotent"

I=$W/i2
mkdir -p "$I/.claude"
echo '{broken' > "$I/.claude/settings.json"
if HOME=$I bash "$ROOT/install.sh" >/dev/null 2>&1; then not_ok "install: fails on invalid settings"
else ok "install: fails on invalid settings"; fi
[ "$(cat "$I/.claude/settings.json")" = '{broken' ] && ok "install: leaves invalid settings untouched" \
  || not_ok "install: leaves invalid settings untouched"

I=$W/i3
mkdir -p "$I/.claude" "$I/dotfiles"
echo '{}' > "$I/dotfiles/settings.json"
ln -s "$I/dotfiles/settings.json" "$I/.claude/settings.json"
HOME=$I bash "$ROOT/install.sh" >/dev/null
[ -L "$I/.claude/settings.json" ] && ok "install: keeps a symlinked settings.json" \
  || not_ok "install: keeps a symlinked settings.json"
expect "install: writes through the symlink" "$(cat "$I/dotfiles/settings.json")" 'statusline-git.sh'

# Same path as `curl | bash`: no script on disk, so it must update the clone.
new_repo "$W/origin"
cp "$ROOT"/*.sh "$W/origin/"
git -C "$W/origin" add .
git -C "$W/origin" commit -qm scripts
git clone -q "$W/origin" "$W/clone"
echo '# update' >> "$W/origin/statusline-git.sh"
git -C "$W/origin" commit -qam update
I=$W/i4
mkdir -p "$I"
HOME=$I CLAUDE_STATUSLINE_DIR=$W/clone bash < "$ROOT/install.sh" >/dev/null
[ "$(readlink "$I/.claude/hooks/statusline-git.sh")" = "$W/clone/statusline-git.sh" ] \
  && ok "install: piped run links the clone" || not_ok "install: piped run links the clone"
expect "install: piped run pulls updates" "$(tail -1 "$W/clone/statusline-git.sh")" '# update'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
