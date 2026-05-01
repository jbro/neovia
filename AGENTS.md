# AGENTS

neovia is a Neovim configuration for an AI-driven coding environment.

## How to Work on This Project

- Target Neovim >= 0.11
- Exhaust existing plugins before adding new ones. Check `lazy-lock.json` and `lua/plugins/` to understand what is already available -- do not assume. A well-established plugin is preferred over homebrew code when the problem is already solved.
- Use native Neovim APIs where they are sufficient (e.g. `vim.lsp.config`/`vim.lsp.enable`). Plugins that enhance native APIs (e.g. better UX for completion, pickers, `vim.ui.*`) are fine.
- Use Neovim default keybindings. Only override on conflict (log the resolution). Only add new bindings where no default exists.
- Vimscript plugins are fine when battle-tested with no better Lua equivalent.
- Keep config (`lua/plugins/`) declarative. Non-reusable glue code can stay inline; reusable logic and feature implementations belong in the module (`lua/neovia/`).
- Use red-green-refactor TDD for the module (`lua/neovia/`). A failing test must exist before any production code is written or changed -- no exceptions. Write the minimal code to make it pass, then refactor. Run tests before considering a task done.
- Guard `require()` calls in module code with `pcall` -- both plugin and cross-module requires. Modules may load in any order (e.g. VimEnter, user commands, reload).
- All code must be safe to reload via `<leader>pr` (re-source `init.lua` after resetting modules). Follow the reload contract below.

### Reload contract

`<leader>pr` clears `package.loaded` for all `neovia.*` modules, calls
`_internal.reset()` on each, then re-sources `init.lua`. For this to work:

- **Modules (`lua/neovia/`):** use an `initialised` guard in `setup()`. Provide `_internal.reset()` that tears down all state (tables, flags, timers). All autocmds must use a **named augroup** (with `clear = true` on create) so they are replaced, not duplicated, on reload.
- **`init.lua`:** one-time side effects (like `lazy.setup()` and `env.setup()`) must be guarded with a `vim.g` flag so they are skipped on re-source. Autocmds must use named augroups.
- **Plugin specs (`lua/plugins/`):** not reloaded -- use `:Lazy sync` for that. Keep keymaps set via plugin specs idempotent (lazy.nvim handles this).

### Repo structure: config vs module

This repo has two distinct parts:

- **Config** (`lua/plugins/`, `init.lua`) -- lazy.nvim plugin specs, keybindings, options.
- **Module** (`lua/neovia/`) -- all custom Lua code lives here.

### Testing

- Tests live in `lua/neovia/tests/*_spec.lua`, run via `nvim -l lua/neovia/tests/run.lua`.
- Extract pure/testable logic from side-effectful code. Expose internals via `M._internal` for test access without polluting the public API.

### Review gate

Run this checklist after every implementation, before considering work done.

1. **Spec compliance** -- re-read the design section and relevant decisions. Verify every stated behaviour has a corresponding test. Check that code paths honour the spec.
2. **Test coverage** -- every public API function (`M.*`) has tests. Every `_internal` function exposed for testing has tests. When code moves between files, migrate or rewrite the corresponding tests. Edge cases from removed tests are preserved in new ones.
3. **Dead code** -- scan for unused locals, unreferenced forward declarations, variables that are set but never read, orphaned `_internal` exports with no test consumers. Remove them.
4. **Duplication** -- check for values defined in multiple files (e.g. colour tables, config constants). Each value has one authoritative source.
5. **Boundary discipline** -- `_internal` is only accessed from test files. Config (`lua/plugins/`) does not reach into `_internal`. Reusable logic (including statusline/tabline string building) belongs in the module; config wires it into plugin specs.
6. **Reload contract** -- `reset()` tears down all state created by `setup()`: tables, flags, timers, augroups. Tests verify re-initialisation works after `reset()`.
7. **Guard hygiene** -- `require()` calls for plugins in module code use `pcall`. `setup()` is guarded by `initialised`. One-time side effects in `init.lua` are guarded by `vim.g` flags.

### Maintaining this file

- Keep rules brief -- every token costs reasoning.
- Phrase positively ("use X" over "never use Y"). Exception: hard safety boundaries.
- Remove redundancy and superseded decisions.
- Describe current state, not history. Decisions record what and why, not what changed from before.
- After every edit, re-read and review against these rules before finishing.

## neovia Design

These rules define what neovia is. They guide design and implementation decisions.

- Optimized for an AI-driven coding workflow: OpenCode writes project code, the user reviews, navigates, and orchestrates. Plugin choices follow from this.
- One opencode server per git repo, running as an independent process that survives Neovim restarts. `neovia.server.ensure_running()` starts the server synchronously in `init.lua` before plugin load; state (port, PID) persists in `stdpath("state")/server/<hash>/`. The plugin connects via `config.server.url` + `port` instead of spawning. Server management keymaps live under `<leader>oE` (status, restart, shutdown, redraw).
- Worktree switching uses `tcd` to scope all plugins to that directory.
- Single-panel model: one opencode UI always visible, `tcd` switches worktrees in place. opencode.nvim detects the directory change and swaps sessions automatically. Background sessions keep running server-side.
- Worktree lifecycle: `<leader>wc` (create from main), `<leader>wC` (create from current HEAD), `<leader>wf` (fork: branch from current HEAD + fork opencode session), `<leader>ww` (switch picker), `<leader>wn` (next), `<leader>wp` (previous), `<leader>wa` (next needing attention), `<leader>wd` (delete picker), `<leader>wD` (delete current). Pickers use fzf-lua; current-worktree shortcuts act directly. Session forking bridges context across worktrees.
- netrw is disabled. Neo-tree is the sole file navigator (always visible, far left). Layout: neo-tree (left) | code (centre top) + session notes (centre bottom, 15 lines) | opencode (right). The code window starts with a noname buffer that goes away when the first real file is opened.
- Session notes (`neovia.notes`): per-worktree persistent markdown notes in a dedicated bottom split. Storage: `stdpath("cache")/notes/<sha256(dir)>.md`. Listed, exempt from read-only mode, saved on BufLeave. Notes buffers are excluded from `buffer_paths` (managed separately from file buffers). Notes are keyed by worktree directory, not opencode session -- they survive session changes.
- Switching unlists current file buffers (saves paths in-memory), `tcd`s to the target, tells neo-tree the new root, relists saved buffers, and swaps the notes buffer in the notes window. Deleting wipes buffers, tears down SSE, removes notes storage from disk, and removes the git worktree. Tombstone sessions ensure reused paths start clean.
- Lualine tabline shows worktree branches with status indicators. Current branch highlighted. Lualine statusline includes an opencode status component for the current worktree. The worktree module exposes data; lualine components in `lua/plugins/ui.lua` handle rendering.
- Diffview (`neovia.diffview`): each worktree can have a lazy diffview tab page. `<leader>dd` toggles working-tree diff, `<leader>dh` toggles file history. `ensure_layout()` skips diffview tabs. Worktree navigation (`wn`/`wp`/`ww`) lands on the last-active tab (code or diff) per worktree. Tabline shows `[diff]` when on a diffview tab. Worktree deletion closes associated diffview tabs.

## Decision Log

Record non-obvious decisions, trade-offs, or reversals here.
Entries that lead to changes should also update the relevant section above.
Superseded entries should be removed to keep context lean.

<!-- Format: ### NNNN - Title (YYYY-MM-DD) -->

### 0001 - Target modern Neovim (2026-03-26)

Neovim 0.11+ has native LSP config and diagnostics built in.
Use these instead of the plugin equivalents (lspconfig, etc.).

### 0002 - OpenCode writes code, user orchestrates (2026-03-26)

The user does not edit files directly -- OpenCode does. The user's role is
reviewing diffs, navigating code, and directing OpenCode. Plugins serve
reading and navigation, not authoring.

### 0003 - Worktree module uses per-directory SSE subscriptions (2026-03-26)

Each SSE connection to `opencode serve` is scoped to one directory.
The worktree module opens a separate subscription per worktree for
real-time status tracking. Status states: idle, responding, needs_attention.

### 0005 - Read-only mode and curated leader keymap (2026-03-27)

Buffers open read-only (modifiable=false, readonly=true) by default.
`<leader>bu` toggles edit mode; BufLeave auto-relocks (configurable).
Special buffers (terminal, help, quickfix, gitcommit, fugitive, neo-tree,
etc.) are excluded. Which-key only triggers on `<leader>` with curated
groups: Buffer (b), Find (f), Search (s), Git (g), OpenCode (o),
Worktree (w), Plugins (p).

### 0006 - Env module sets variables before plugin load (2026-04-21)

`neovia.env` sets environment variables before `lazy.setup()` so subprocesses
(like `opencode serve`) inherit them. Two modes: `value` for plain strings,
`exec` for running any command (table = direct, string = via shell).
File-based caching is opt-in per entry via explicit `cache` path + `ttl`.
No password-manager-specific assumptions.

### 0007 - Config reload from leader menu (2026-04-21)

`<leader>pr` reloads all `neovia.*` modules and re-sources `init.lua`.
See the reload contract in the rules section above.

### 0008 - Worktree lifecycle via tcd (2026-04-21)

`tcd` switches worktrees in place; opencode.nvim detects `DirChanged` and
swaps sessions automatically. Sessions are never deleted -- on worktree
delete a tombstone session is created so reused paths start clean.

### 0009 - Lualine for worktree display (2026-04-22)

Lualine tabline shows all worktree branches (like tabs); statusline shows
opencode status for the current worktree. The worktree module builds the
tabline string (including click-to-switch handlers); `lua/plugins/ui.lua`
wires it into lualine config and defines highlight groups.

### 0010 - Detach opencode server from Neovim (2026-04-23)

`neovia.server.ensure_running()` starts `opencode serve` synchronously
in `init.lua` before plugin load. The server runs detached so Neovim
restarts are instant and non-disruptive. State (port, PID) persists on
disk; the plugin connects via `server.url` + `port` in attach mode
(`auto_kill = false`). `<leader>oE` provides server management
(status `s`, restart `r`, shutdown `q`, redraw `d`). The worktree
module's `OpencodeEvent:server.connected` autocmd is repeating (not
`once`) so server restarts trigger SSE re-subscription.

### 0011 - Neo-tree replaces netrw, session notes in bottom split (2026-04-23)

netrw disabled (`vim.g.loaded_netrwPlugin = 1`). Neo-tree is always visible
(left sidebar, `lazy = false`). `bind_to_cwd = false` prevents neo-tree from
calling `tcd`/`lcd` when navigating directories; worktree module explicitly
sets neo-tree root via `Neotree dir=` after `tcd`. Per-worktree session
notes (`neovia.notes`) live in a dedicated bottom split (15 lines) below the
code window. Notes are exempt from read-only mode via `vim.b.neovia_notes`
check in `mode.should_lock()`. The code window starts with a noname buffer
that disappears when a real file is opened.

### 0012 - Diffview in per-worktree tab pages (2026-05-01)

Diffview gets its own tab page per worktree (lazy, created on first use).
`<leader>dd` toggles working-tree diff (staged + unstaged), `<leader>dh`
toggles file history. Both reuse the same tab slot per worktree. The
tabline shows `[diff]` indicator when the diffview tab is active.
`ensure_layout()` is skipped on diffview tabs. Worktree navigation
(`wn`/`wp`/`ww`) lands on whichever tab (code or diff) was last active
for the target worktree, tracked via `last_view` in worktree state.
Worktree deletion closes associated diffview tabs.
