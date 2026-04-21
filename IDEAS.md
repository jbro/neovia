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

## Detach opencode server from Neovim

Run the opencode server as an independent process so restarting Neovim doesn't
kill it. The plugin already supports connecting to an external instance via
`config.server.url`.

- **Approach:** start `opencode serve` from `neovia.zsh` (the shell wrapper)
  before launching Neovim, or use a long-lived process manager (launchd, etc.).
  Pass the URL to the plugin config so it connects instead of spawning.
- **Benefit:** Neovim restarts become instant and non-disruptive -- in-flight
  responses survive, and reconnection is seamless.
- **Port mapping:** the plugin already has reference-counted port mapping; an
  externally managed server just skips the spawn/kill lifecycle entirely.
- **Spike:** verify that `config.server.url` with a pre-running server works
  end-to-end, including SSE subscriptions and session resumption.

## Streamline worktree branching flow

Current flow is clunky: prompt opencode on the main session to create a
worktree, wait for it to finish (blocking the main thread), then `/new` to
start a fresh session, `<leader>ww` to switch to the new worktree, and
continue prompting there. The main session is unnecessarily occupied.

- **Problem:** creating a worktree is a mechanical step that shouldn't require
  an opencode prompt or block the main session.
- **Possible approaches:**
  - A neovia command/keymap (e.g. `<leader>wn`) that creates the worktree
    directly (git worktree add + branch), switches to it via `tcd`, and
    connects a fresh opencode session -- all without prompting opencode.
  - A picker that lets you name the branch, pick the base ref, and handles
    the rest.
  - If opencode needs initial context for the new worktree, seed it with a
    system message or initial prompt automatically.
- **Goal:** one keypress from "I want to work on something new" to being in a
  fresh worktree with opencode ready, without touching the main session.
- **Spike:** map out the exact git + opencode API calls needed and whether
  opencode.nvim supports per-directory session isolation already.

## Spikes
