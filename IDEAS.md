# Ideas

Future ideas and spikes that haven't been scheduled yet.

## Per-worktree scratch buffer

Replace netrw on startup with a persistent scratch buffer for free-form notes.

- **Scope:** per-worktree. Notes accumulate across sessions for a given project.
- **Storage:** `~/.local/state/neovia/<hashed-worktree-root>/scratch.md`, outside the repo.
- **Format:** markdown -- get syntax highlighting, headings, checklists for free.
- **Buffer name:** virtual name like `[scratch]` so lualine stays clean.
- **Auto-save:** on BufLeave + periodic timer (~30s if modified). No manual save needed.
- **Not read-only:** this is a writing surface, exempt from the default read-only mode.
- **File navigation:** with scratch taking the left slot, file browsing moves to
  neo-tree (toggled on demand) or telescope. Aligns with the orchestration model.

## Spikes
