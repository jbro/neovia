# AGENTS

neovia is a Neovim configuration for an AI-driven coding environment.

## How to Work on This Project

- Target Neovim >= 0.11
- Use native APIs over plugins where Neovim has built-in support (e.g. `vim.lsp.config`/`vim.lsp.enable`)
- Use Neovim default keybindings. Only override on conflict (log the resolution). Only add new bindings where no default exists.
- Prefer fewer, thinner plugins. Prefer native Neovim or OpenCode over adding a plugin.
- Vimscript plugins are fine when battle-tested with no better Lua equivalent.
- Keep config (`lua/plugins/`) declarative. Non-reusable glue code can stay inline; reusable logic and feature implementations belong in the module (`lua/neovia/`).
- Use red-green-refactor TDD for the module (`lua/neovia/`). Write a failing test first, then write the minimal code to make it pass, then refactor. Run tests before considering a task done.
- Guard `require()` calls for plugins in module code with `pcall` -- modules may run before plugins are loaded (e.g. VimEnter, user commands).
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
- After implementation, review code against the spec (this file + decision log). Verify every stated behaviour has a corresponding test and every code path honours the spec. Check all public API functions have test coverage.

### Maintaining this file

- Keep rules brief -- every token costs reasoning.
- Phrase positively ("use X" over "never use Y"). Exception: hard safety boundaries.
- Remove redundancy and superseded decisions.
- After every edit, re-read and review against these rules before finishing.

## neovia Design

These rules define what neovia is. They guide design and implementation decisions.

- Optimized for an AI-driven coding workflow: OpenCode writes project code, the user reviews, navigates, and orchestrates. Plugin choices follow from this.
- One OpenCode process per git worktree. Worktree switching uses `tcd` to scope all plugins to that directory.
- Single-panel model: one opencode UI always visible, `tcd` switches worktrees in place. opencode.nvim detects the directory change and swaps sessions automatically. Background sessions keep running server-side.
- Worktree lifecycle is managed via `<leader>wc` (create), `<leader>ww` (switch), `<leader>wd` (delete), `<leader>wq` (close). Session forking bridges context across worktrees.
- Switching unlists current file buffers (saves paths in-memory), `tcd`s to the target, and relists saved buffers (or opens netrw on first visit). Closing wipes buffers and tears down SSE but keeps the git worktree on disk. Deleting creates a tombstone session (so reused paths start clean), then removes the worktree and branch.
- Tabline (`%!v:lua.neovia_tabline()`) shows all worktree branches with status indicators. Current branch highlighted, closed worktrees dimmed.

## Decision Log

Record non-obvious decisions, trade-offs, or reversals here.
Entries that lead to changes should also update the relevant section above.
Superseded entries should be removed to keep context lean.

<!-- Format: ### NNNN - Title (YYYY-MM-DD) -->

### 0001 - Target modern Neovim (2026-03-26)

Neovim 0.11+ has native LSP config and diagnostics built in.
Use these instead of the plugin equivalents (lspconfig, etc.).
Exception: blink.cmp is kept for completion (richer UX than native).
This reduces the plugin surface and keeps the config closer to upstream.

### 0002 - OpenCode writes code, user orchestrates (2026-03-26)

The user does not edit files directly -- OpenCode does. The user's role is
reviewing diffs, navigating code, and directing OpenCode. Plugins serve
reading and navigation, not authoring.

### 0003 - Worktree module uses per-directory SSE subscriptions (2026-03-26)

Each SSE connection to `opencode serve` is scoped to one directory.
The worktree module opens a separate subscription per worktree for
real-time status tracking. Status states: idle, responding, needs_attention.

### 0004 - Tests colocated with module, not at repo root (2026-03-26)

Tests live at `lua/neovia/tests/` next to the code they test, run via
`nvim -l` (Neovim 0.11+ script mode).

### 0005 - Read-only mode and curated leader keymap (2026-03-27)

Buffers open read-only (modifiable=false, readonly=true) by default.
`<leader>u` toggles edit mode; BufLeave auto-relocks (configurable).
Special buffers (terminal, help, quickfix, gitcommit, fugitive, neo-tree,
etc.) are excluded. Which-key only triggers on `<leader>` with curated
groups: Find (f), Search (s), Git (g), OpenCode (o), Worktree (w),
Plugins (p).

### 0006 - Env module sets variables before plugin load (2026-04-21)

`neovia.env` sets environment variables before `lazy.setup()` so subprocesses
(like `opencode serve`) inherit them. Two modes: `value` for plain strings,
`exec` for running any command (table = direct, string = via shell).
File-based caching is opt-in per entry via explicit `cache` path + `ttl`.
No password-manager-specific assumptions.

### 0007 - Config reload from leader menu (2026-04-21)

`<leader>pr` reloads all `neovia.*` modules and re-sources `init.lua`.
Each module must provide `_internal.reset()` to tear down state, use named
augroups for autocmds, and guard `setup()` with an `initialised` flag.
`init.lua` guards one-time side effects (`lazy.setup`, `env.setup`) with
`vim.g` flags. Plugin specs are not reloaded (use `:Lazy sync`).
See the reload contract in the rules section above.

### 0008 - Worktree lifecycle via tcd (2026-04-21)

`tcd` switches worktrees in place; opencode.nvim detects `DirChanged` and
swaps sessions automatically. Sessions are never deleted -- on worktree
delete a tombstone session is created so reused paths start clean.
