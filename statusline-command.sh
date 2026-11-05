#!/usr/bin/env bash
# ~/.claude/statusline-command.sh
# Riga 1 della statusline: identita' PS1 (user@host:dir) + modello + contesto.
# Prima usava gsd-statusline.js (plugin GSD); dal 2026-11-01 il segmento contesto
# e' nativo, letto dal JSON che Claude Code passa in stdin. Se gsd-statusline.js
# torna a esistere, viene usato al posto del segmento nativo.

# printf di bash usa il separatore decimale della locale: con it_IT/de_DE "1.23"
# dal JSON e' un numero non valido. Forza il punto, mantenendo l'UTF-8 per i testi.
if [ -n "${LC_ALL:-}" ]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C

input=$(cat)

user=$(whoami)
host=$(hostname -s)
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
[ -z "$dir" ] && dir=$(pwd)
short_dir=$(basename "$dir")
identity="\033[01;32m${user}@${host}\033[00m:\033[01;34m${short_dir}\033[00m"

gsd="$HOME/.claude/hooks/gsd-statusline.js"
if [ -f "$gsd" ] && command -v node >/dev/null 2>&1; then
  rest=$(printf '%s' "$input" | node "$gsd" 2>/dev/null)
else
  model=$(printf '%s' "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
  used=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
  size=$(printf '%s' "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
  rest=""
  [ -n "$model" ] && rest="$model"
  if [ -n "$used" ]; then
    # barra a 10 blocchi, colore: verde <50, giallo 50-79, rosso >=80
    filled=$(awk -v u="$used" 'BEGIN{printf "%d", (u+5)/10}')
    [ "$filled" -gt 10 ] && filled=10
    bar=""
    for i in $(seq 1 10); do
      if [ "$i" -le "$filled" ]; then bar="${bar}▰"; else bar="${bar}▱"; fi
    done
    code=$(awk -v u="$used" 'BEGIN{c=32; if(u>=50)c=33; if(u>=80)c=31; print c}')
    ctx=$(printf '\033[%dmctx %s %.0f%%\033[0m' "$code" "$bar" "$used")
    if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
      k=$(awk -v s="$size" 'BEGIN{printf "%dk", s/1000}')
      ctx="$ctx $(printf '\033[2m/%s\033[0m' "$k")"
    fi
    rest="${rest:+$rest } $ctx"
  fi
fi

printf "${identity} │ %s" "$rest"
