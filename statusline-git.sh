#!/usr/bin/env bash
# Statusline wrapper (2 righe):
#   riga 1 = statusline-command.sh (identità user@host:dir  +  gsd-statusline.js)
#   riga 2 = segmenti aggiuntivi: effort, git, azione GSD, costo/attività, quota
# File NON gestito da GSD (sopravvive ai /gsd:update; statusline-command.sh e
# gsd-statusline.js restano intatti).

# printf di bash usa il separatore decimale della locale: con it_IT/de_DE "1.23"
# dal JSON e' un numero non valido. Forza il punto, mantenendo l'UTF-8 per i testi.
if [ -n "${LC_ALL:-}" ]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C

input=$(cat)

# --- Riga 1: identità PS1 + statusline GSD di base ---------------------------
base=$(printf '%s' "$input" | bash "$HOME/.claude/statusline-command.sh" 2>/dev/null)
printf '%s' "$base"

# --- Riga 2: effort + git + azione GSD + costo + quota -----------------------
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
sep=$(printf ' \033[2m│\033[0m ')
line2=""
add2() { [ -z "$line2" ] && line2="$1" || line2="$line2$sep$1"; }

# 0) Effort/ragionamento della sessione.
effort=$(printf '%s' "$input" | jq -r '.effort.level // empty' 2>/dev/null)
[ -n "$effort" ] && add2 "$(printf '\033[94m⚙ %s\033[0m' "$effort")"

# a) Segmento git: branch, ahead/behind, dirty, worktree.
if [ -n "$dir" ]; then
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    [ "$branch" = "HEAD" ] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    g=$(printf '\033[36m⎇ %s\033[0m' "$branch")
    counts=$(git -C "$dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
    if [ -n "$counts" ]; then
      behind=$(printf '%s' "$counts" | awk '{print $1}')
      ahead=$(printf '%s' "$counts" | awk '{print $2}')
      [ -n "$ahead" ]  && [ "$ahead"  -gt 0 ] 2>/dev/null && g="$g$(printf '\033[32m ↑%s\033[0m' "$ahead")"
      [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && g="$g$(printf '\033[31m ↓%s\033[0m' "$behind")"
    fi
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$dirty" ] && [ "$dirty" -gt 0 ] 2>/dev/null && g="$g$(printf '\033[33m ✱%s\033[0m' "$dirty")"
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$top" ]; then
      wt=$(basename "$top"); cur=$(basename "$dir")
      [ "$wt" != "$cur" ] && g="$g$(printf ' \033[2m⌂ %s\033[0m' "$wt")"
    fi
    add2 "$g"
  fi
fi

# b) Fase/azione GSD attiva: stopped_at dal frontmatter di .planning/STATE.md
if [ -n "$dir" ]; then
  d="$dir"; state=""
  for _ in $(seq 1 10); do
    [ -f "$d/.planning/STATE.md" ] && { state="$d/.planning/STATE.md"; break; }
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
  done
  if [ -n "$state" ]; then
    sa=$(grep -m1 '^stopped_at:' "$state" | sed -E 's/^stopped_at:[[:space:]]*//; s/^"//; s/"[[:space:]]*$//')
    if [ -n "$sa" ]; then
      [ "${#sa}" -gt 60 ] && sa="${sa:0:60}…"
      add2 "$(printf '\033[35m▶ %s\033[0m' "$sa")"
    fi
  fi
fi

# c) Costo, righe modificate e durata sessione.
costgrp=""
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
[ -n "$cost" ] && costgrp=$(printf '\033[33m$%.2f\033[0m' "$cost")
added=$(printf '%s' "$input" | jq -r '.cost.total_lines_added // empty' 2>/dev/null)
removed=$(printf '%s' "$input" | jq -r '.cost.total_lines_removed // empty' 2>/dev/null)
if [ -n "$added" ] || [ -n "$removed" ]; then
  seg=$(printf '\033[32m+%s\033[0m/\033[31m-%s\033[0m' "${added:-0}" "${removed:-0}")
  costgrp="${costgrp:+$costgrp }$seg"
fi
dur=$(printf '%s' "$input" | jq -r '.cost.total_duration_ms // empty' 2>/dev/null)
if [ -n "$dur" ] && [ "$dur" -gt 0 ] 2>/dev/null; then
  seg=$(printf '\033[2m⏱ %dm%02ds\033[0m' "$(( dur / 60000 ))" "$(( (dur % 60000) / 1000 ))")
  costgrp="${costgrp:+$costgrp }$seg"
fi

# d) Quota rate limit: 5h su valore assoluto, 7g sul RITMO di consumo.
now=$(date +%s)

# Codice colore ANSI su valore assoluto: verde <50, giallo 50-79, rosso >=80.
code_abs() {  # $1=used%
  awk -v u="$1" 'BEGIN{c=32; if(u>=50)c=33; if(u>=80)c=31; print c}'
}

# Codice colore ANSI sul ritmo: proietta l'uso a fine finestra (consumo lineare).
#   $1=used%  $2=resets_at(epoch)  $3=now(epoch)  $4=durata finestra(s)
# Verde se la proiezione resta <=100%; giallo se sfora fino al 130%; rosso oltre
# (probabile esaurirla prima del rinnovo). Guardie: quasi-piena (>=95%) => rosso;
# molto margine a inizio finestra (<15%) => verde, per evitare rumore iniziale.
code_pace() {
  awk -v u="$1" -v r="$2" -v n="$3" -v win="$4" 'BEGIN{
    f = (win - (r - n)) / win;     # frazione di finestra trascorsa
    if (f > 1) f = 1;
    c = 32;
    if (f <= 0)      { if (u >= 50) c = 33; if (u >= 80) c = 31 }  # rinnovo incoerente
    else if (u >= 95) c = 31;
    else if (u < 15)  c = 32;
    else { p = u / f; if (p > 100) c = 33; if (p > 130) c = 31 }
    print c
  }'
}

fmt_pct() { printf '\033[%dm%.0f%%\033[0m' "$1" "$2"; }  # $1=code $2=used%

five=$(printf '%s' "$input"  | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
seven=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
seven_reset=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)
dot=$(printf ' \033[2m·\033[0m ')
quota=""
[ -n "$five" ] && quota="$(printf '\033[2m◷ 5h\033[0m ')$(fmt_pct "$(code_abs "$five")" "$five")"
if [ -n "$seven" ]; then
  if [ -n "$seven_reset" ]; then
    code7=$(code_pace "$seven" "$seven_reset" "$now" 604800)
  else
    code7=$(code_abs "$seven")
  fi
  quota="${quota:+$quota$dot}$(printf '\033[2m7g\033[0m ')$(fmt_pct "$code7" "$seven")"
fi

stats="$costgrp"
[ -n "$quota" ] && stats="${stats:+$stats }$quota"
[ -n "$stats" ] && add2 "$stats"

# --- Output ------------------------------------------------------------------
if [ -n "$line2" ]; then
  printf '\n%s\n' "$line2"
else
  printf '\n'
fi
