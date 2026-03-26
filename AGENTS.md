# AGENTS

neovia is a Neovim configuration for an AI-driven coding environment.

## How to Work on This Project

- Target Neovim >= 0.11
- Use native APIs over plugins where Neovim has built-in support (e.g. `vim.lsp.config`/`vim.lsp.enable`, `vim.lsp.completion.enable()`)
- Use Neovim default keybindings. Only override on conflict (log the resolution). Only add new bindings where no default exists.
- Prefer fewer, thinner plugins. Prefer native Neovim or OpenCode over adding a plugin.
- Vimscript plugins are fine when battle-tested with no better Lua equivalent.
- Use TDD for the module (`lua/neovia/`). Write tests first or alongside code, run them before considering a task done.

### Repo structure: config vs module

This repo has two distinct parts:

- **Config** (`lua/plugins/`, `init.lua`) -- lazy.nvim plugin specs, keybindings, options. No tests needed.
- **Module** (`lua/neovia/`) -- custom Lua code that behaves like a plugin.

### Testing

- Tests live in `lua/neovia/tests/*_spec.lua`, run via `nvim -l lua/neovia/tests/run.lua`.
- Extract pure/testable logic from side-effectful code. Expose internals via `M._internal` for test access without polluting the public API.

### Maintaining this file

- Keep rules brief -- every token costs reasoning.
- Phrase positively ("use X" over "never use Y"). Exception: hard safety boundaries.
- Remove redundancy and superseded decisions.
- After every edit, re-read and review against these rules before finishing.

## neovia Design

These rules define what neovia is. They guide design and implementation decisions.

- Optimized for an AI-driven coding workflow: OpenCode writes project code, the user reviews, navigates, and orchestrates. Plugin choices follow from this.
- One OpenCode process per git worktree. Worktree switching uses `tcd` to scope all plugins to that directory.

## Decision Log

Record non-obvious decisions, trade-offs, or reversals here.
Entries that lead to changes should also update the relevant section above.
Superseded entries should be removed to keep context lean.

<!-- Format: ### NNNN - Title (YYYY-MM-DD) -->

### 0001 - Target modern Neovim (2026-03-26)

Neovim 0.11+ has native LSP config, completion, and diagnostics built in.
Use these instead of the plugin equivalents (lspconfig, blink.cmp, etc.).
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
