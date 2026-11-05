#!/usr/bin/env bash
# Installa/aggiorna la statusline di Claude Code su questo sistema.
#   curl -fsSL https://raw.githubusercontent.com/7hemas7er/claude-statusline/main/install.sh | bash
# Idempotente: rilanciarlo aggiorna all'ultima versione.
set -euo pipefail

REPO_URL="https://github.com/7hemas7er/claude-statusline.git"
CLONE_DIR="${CLAUDE_STATUSLINE_DIR:-$HOME/.local/share/claude-statusline}"
CLAUDE_DIR="$HOME/.claude"
CMD='bash "$HOME/.claude/hooks/statusline-git.sh"'

for bin in git jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Errore: serve '$bin', installalo e rilancia." >&2; exit 1; }
done

# Lanciato da un checkout usa quello; lanciato via curl clona o aggiorna CLONE_DIR.
src="${BASH_SOURCE[0]:-}"
here=""
[ -n "$src" ] && [ -f "$src" ] && here=$(cd "$(dirname "$src")" && pwd)
if [ -n "$here" ] && [ -f "$here/statusline-git.sh" ]; then
  repo="$here"
elif [ -d "$CLONE_DIR/.git" ]; then
  repo="$CLONE_DIR"
  git -C "$repo" pull --ff-only --quiet
else
  repo="$CLONE_DIR"
  mkdir -p "$(dirname "$repo")"
  git clone --quiet "$REPO_URL" "$repo"
fi

stamp=$(date +%Y%m%d-%H%M%S)

link() {  # $1=sorgente $2=destinazione; un file esistente diverso va in backup
  mkdir -p "$(dirname "$2")"
  [ "$(readlink "$2" 2>/dev/null)" = "$1" ] && return 0
  if [ -e "$2" ] && [ ! -L "$2" ]; then
    mv "$2" "$2.bak.$stamp"
    echo "Backup: $2.bak.$stamp"
  fi
  ln -sfn "$1" "$2"
}

link "$repo/statusline-git.sh"     "$CLAUDE_DIR/hooks/statusline-git.sh"
link "$repo/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"

# settings.json: tocca solo .statusLine. Se il JSON non e' valido jq fallisce e il
# file resta intatto; si scrive con cat per non rompere un eventuale symlink.
settings="$CLAUDE_DIR/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
current=$(jq -r '.statusLine.command // empty' "$settings")
if [ "$current" != "$CMD" ]; then
  tmp=$(mktemp)
  jq --arg cmd "$CMD" '.statusLine = {type: "command", command: $cmd}' "$settings" > "$tmp"
  cp "$settings" "$settings.bak.$stamp"
  echo "Backup: $settings.bak.$stamp"
  cat "$tmp" > "$settings"
  rm -f "$tmp"
fi

echo "Statusline installata da $repo"
