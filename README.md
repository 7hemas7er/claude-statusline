# claude-statusline

Statusline a due righe per [Claude Code](https://claude.com/claude-code).

```
user@host:dir │ Opus ctx ▰▰▰▰▱▱▱▱▱▱ 43% /200k
⚙ high │ ⎇ main ↑1 ✱3 │ ▶ fase GSD │ $1.23 +10/-2 ⏱ 2m05s ◷ 5h 12% · 7g 33%
```

- **Riga 1:** identità, modello, barra del contesto.
- **Riga 2:** effort, git (branch, ahead/behind, modifiche, worktree), azione GSD se
  c'è `.planning/STATE.md`, costo, righe, durata, quota 5h e 7g.

La quota 7g è colorata sul ritmo di consumo, non sul valore assoluto: diventa gialla
o rossa se a questo ritmo si esaurisce prima del rinnovo.

## Installazione

Richiede `git` e `jq`.

```sh
curl -fsSL https://raw.githubusercontent.com/7hemas7er/claude-statusline/main/install.sh | bash
```

Lo script clona il repo in `~/.local/share/claude-statusline` (cambialo con
`CLAUDE_STATUSLINE_DIR`), crea i symlink in `~/.claude` e imposta `statusLine` in
`settings.json`. I file che sostituisce restano accanto con suffisso `.bak.<data>`.

## Aggiornamento

Rilancia lo stesso comando.

## Modifiche

I file in `~/.claude` sono symlink al clone: modificali lì, poi fai commit e push.
