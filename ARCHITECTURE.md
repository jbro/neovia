# Architecture

## Pattern Overview

**Overall:** Plugin-driven, modular Neovim configuration with a small core module providing worktree, session, and opencode integration.

**Key Characteristics:**
- Modules live under `lua/neovia/` and implement core behaviours (worktree lifecycle, server lifecycle, notes, layout, etc.).
- Plugin specs live under `lua/plugins/` and remain declarative; `init.lua` loads them via `lazy.nvim`.
- Modules guard optional dependencies with `pcall` and degrade gracefully when plugins or external binaries are unavailable.

## Layers

**Configuration (plugin) layer:**
- Purpose: declare and configure third-party plugins and UI wiring.
- Location: `init.lua` and `lua/plugins/`
- Contains: `lazy.nvim` plugin specs, plugin-specific wiring (neo-tree, fzf-lua, diffview, treesitter, format, editor, opencode integration).
- Depends on: core modules in `lua/neovia/`, Neovim APIs, external binaries for some plugins.
- Used by: users via Neovim startup and the module layer.

**Module (core) layer:**
- Purpose: implement project-specific behaviour and integration glue for worktrees, sessions, server management, layout, notes, status and tabline.
  - Location: `lua/neovia/` (e.g. `lua/neovia/worktree.lua`, `lua/neovia/server.lua`, `lua/neovia/notes.lua`, `lua/neovia/layout.lua`, `lua/neovia/diffview.lua`, `lua/neovia/magic_context.lua`).
 - Contains: core modules, utilities (`fs.lua`, `env.lua`, `reload.lua`, `sse.lua`, `session.lua`, `navigate.lua`, `pr.lua`, `mode.lua`, `theme.lua`, `version.lua`, `magic_context.lua`).
- Depends on: Neovim Lua API, optional plugins (`neo-tree`, `fzf-lua`, `diffview`), and external commands (`git`, `opencode`, `curl`, `lsof`, `pgrep`).
- Used by: `init.lua` at startup, and plugin specs for runtime wiring.

**Tests:**
- Purpose: unit tests and integration-style specs for modules.
- Location: `lua/neovia/tests/` (many `*_spec.lua` files) and test runner `lua/neovia/tests/run.lua`.

## Data Flow

**Worktree switch flow:**

1. User triggers a worktree change (picker or tabline) — `lua/neovia/worktree.lua::M.switch_to`.
2. Current buffers are snapshot via session helpers — `lua/neovia/session.lua` (collect/unlist/relist) and `lua/neovia/worktree.lua` saves model/session state.
3. Directory change executes `vim.cmd.tcd(dir)` and opencode-related DirChanged hooks run (opencode.nvim integration).
 4. Deferred UI updates run: neo-tree root set via `:Neotree dir=` (configured in `lua/plugins/neo-tree.lua`), layout repair via `lua/neovia/layout.lua`, and notes buffer swap via `lua/neovia/notes.lua`.
 5. A single global SSE connection to `/global/event` (`lua/neovia/sse.lua`) delivers multiplexed envelopes; events include a `directory` field and are routed to per-worktree runtime state in `lua/neovia/worktree.lua`. Tabline/status components (`lua/neovia/tabline.lua`) consume the updated per-worktree state.

**Opencode session selection:**

- Opencode is configured with `lock_session_to_directory = true` in `lua/plugins/opencode.lua` so directory-driven automatic session selection is disabled.
- Neovia deterministically selects or creates the opencode session for a worktree after `tcd` via `lua/neovia/worktree.lua::select_or_create_session`. Selection uses a saved `session_id` when present, otherwise it lists sessions scoped to the directory and switches to the newest non-child or creates a new session when none exist.
- When creating a forked session, neovia records the forked session ID into the target worktree's state before switching so the subsequent deterministic selection activates the intended session without races.
 - Neovia clears opencode's active session synchronously whenever it differs from the target worktree before any asynchronous session switch/create. This prevents typed input from routing to a stale session while the selection resolves (`lua/neovia/worktree.lua::select_or_create_session`).

**Server lifecycle flow (opencode):**

1. Startup code calls `lua/neovia/server.lua::ensure_running()` from `init.lua` to make `opencode serve` available to plugins.
2. Server writes state into `stdpath('state')/server/<hash>/` (port and pid files) — `lua/neovia/server.lua`.
3. Clients discover/health-check the server via HTTP and fall back to process table probes (curl, lsof) when needed.

## Key Abstractions

**WorktreeState**
- Purpose: represent per-directory runtime state (status, pending permissions, saved buffers, session_id, saved model state, neo-tree expanded nodes).
- Location: `lua/neovia/worktree.lua` (`state` table and `M._internal.make_entry`).
- Pattern: table keyed by absolute worktree path.

**Global SSE connection**
- Purpose: open a single SSE stream to `/global/event`, parse envelopes into (directory, payload), and dispatch events to per-worktree processors.
- Location: `lua/neovia/sse.lua` (parsing, connection lifecycle, and per-event dispatch helpers).
- Used by: `lua/neovia/worktree.lua` to keep per-worktree `status` and `pending_permissions` up-to-date.

**Server info (persisted)**
- Purpose: persist opencode server `port` and `pid` so multiple Neovim instances/clients discover the running server.
- Location: `lua/neovia/server.lua` (state dir helpers `state_dir`, `save_server_info`, `load_server_info`).
- Pattern: small on-disk files under `stdpath('state')/server/<hash>/`.

**Notes buffer (session notes)**
- Purpose: per-worktree markdown notes displayed in a dedicated bottom split.
- Location: `lua/neovia/notes.lua` (storage path uses `vim.fn.sha256(dir)` and `stdpath('cache')/notes/<sha256>.md`).
- Pattern: unlisted `buftype=acwrite` buffers with explicit `BufWriteCmd` handlers and autocmds to auto-save on `BufLeave`.



## Entry Points

**Neovim startup:**
- Location: `init.lua`
- Triggers: Neovim process startup and `:lua require('neovia')` style loads.
- Responsibilities: set leader keys, guard env loading, start the opencode server (`lua/neovia/server.lua`), load plugin specs via `lazy.nvim`, and initialise core modules (`lua/neovia/*.lua`).

**Worktree switch API:**
- Location: `lua/neovia/worktree.lua::M.switch_to`
- Triggers: tabline clicks, picker selections, user commands and keymaps.
- Responsibilities: snapshot buffers and state, `tcd` to target, restore buffers and UI, coordinate opencode session swap.

## Error Handling

**Strategy:** Modules prefer graceful degradation: optional plugins and runtime integrations are guarded with `pcall`; failures surface to the user via `vim.notify` and modules fall back to no-ops when external dependencies or commands are unavailable.

## Cross-Cutting Concerns

**Logging:** Use `vim.notify(...)` for user-visible messages and warnings; test code stubs `vim.notify` when needed.

**Caching:** Persistent server info uses `stdpath('state')`; notes and transient per-worktree data use `stdpath('cache')`.

**Storage:** Notes persist to files under `stdpath('cache')/notes/` named by SHA256 of the worktree path; server persists `port` and `pid` under `stdpath('state')/server/<hash>/`.

**Renderer event scoping:**

- Opencode's renderer subscriptions are scoped to the active session; neovia registers renderer and session handlers directly (see `lua/plugins/opencode.lua`) and does not wrap handlers for additional session-guarding.
 - Neovia installs an additional unscoped subscription in `lua/plugins/opencode.lua` that detects child/subagent-session permission events dropped by the session-scoped gate and re-drives upstream's recovery flow. The subscription defers briefly then calls `opencode.ui.permission_window.restore_pending_permissions` for the active session to surface pending child-session permission dialogs.
