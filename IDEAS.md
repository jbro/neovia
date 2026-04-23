# Ideas

Future ideas and spikes that haven't been scheduled yet.

## Replace netrw with neo-tree + scratch buffer

Remove netrw entirely. Neo-tree becomes the sole file navigator, always
visible on the far left. The code window shows a per-worktree scratch
buffer on startup instead of netrw.

- **Drop netrw:** disable via `vim.g.loaded_netrwPlugin = 1`. Fixes
  tabline click-through bug (netrw captures mouse events that should go
  to the tabline).
- **Neo-tree always visible:** open on startup at the far left, before
  the code window. Replaces netrw's role as the default "no file open"
  view.
- **Scratch buffer:** persistent per-worktree notes in the code window.
  - **Scope:** per-worktree. Notes accumulate across sessions.
  - **Storage:** `~/.local/state/neovia/<hashed-worktree-root>/scratch.md`.
  - **Format:** markdown -- syntax highlighting, headings, checklists.
  - **Buffer name:** virtual name like `[scratch]` so lualine stays clean.
  - **Auto-save:** on BufLeave + periodic timer (~30s if modified).
  - **Not read-only:** exempt from the default read-only mode.
- **Layout:** neo-tree (left) | code/scratch (centre) | opencode (right).

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
- **Config reload:** reloading `.opencode`, agents, etc. becomes free --
  restart the external process and the plugin reconnects. No plugin-side
  reload API needed. (Currently no reload mechanism exists in the plugin
  or CLI.)
- **Spike:** verify that `config.server.url` with a pre-running server works
  end-to-end, including SSE subscriptions and session resumption.

## GitHub PR status in worktree tabline

Show PR status per worktree in the tabline. If a worktree's branch has an
open PR, display the CI/review status alongside the opencode status indicator.

- **Data source:** `gh pr status` or GitHub API via `gh api`. Map branch
  name to PR, fetch check suite state and review decision.
- **States:** draft, review requested, approved, changes requested,
  checks passing/failing/pending, merged. Each gets its own icon/colour.
- **Polling:** periodic background fetch (e.g. every 60s) to avoid
  hammering the API. Cache per branch; invalidate on worktree switch.
- **Integration:** extend `TablineEntry` with a `pr` field. `build_tabline`
  renders it after the opencode status indicator.
- **Spike:** measure latency of `gh api` calls; decide whether to shell
  out per-worktree or batch all branches in one call.

## Spikes
