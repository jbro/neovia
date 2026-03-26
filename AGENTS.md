# AGENTS

neovia is a Neovim configuration for an AI-driven coding environment.

## How to Work on This Project

- Target Neovim >= 0.11
- Use native APIs over plugins where Neovim has built-in support (e.g. `vim.lsp.config`/`vim.lsp.enable`, `vim.lsp.completion.enable()`)
- Use Neovim default keybindings. Only override on conflict (log the resolution). Only add new bindings where no default exists.
- Prefer fewer, thinner plugins. Prefer native Neovim or OpenCode over adding a plugin.
- Vimscript plugins are fine when battle-tested with no better Lua equivalent.

### Maintaining this file

- Keep rules brief -- every token costs reasoning.
- Phrase positively ("use X" over "never use Y"). Exception: hard safety boundaries.
- Remove redundancy and superseded decisions.

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
reviewing diffs, navigating code, and directing OpenCode. This means:
no autopairs, no fancy completion engine, read-only tree view over
file-editing tree view, format-on-save as a safety net not a workflow.
