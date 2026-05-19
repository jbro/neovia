# Codebase Structure

## Directory Layout

```
[project-root]/
├── lua/            # Plugin specs and core Lua modules
│   ├── plugins/    # Plugin specification files (lazy.nvim)
│   └── neovia/     # Core module code (worktree, server, notes, layout, etc.)
├── init.lua        # Entry point that bootstraps lazy.nvim and core modules
├── AGENTS.md       # Agent guidelines and rules for the repo
└── README.md       # Project readme
```

## Directory Purposes

**lua/**:
- Purpose: host all Lua code for the configuration and module implementation.
- Contains: `plugins/` plugin specs and `neovia/` modules.
- Key files: `init.lua` (repo root) loads modules and plugin specs.

**lua/plugins/**:
- Purpose: declare and configure third-party plugins via `lazy.nvim`.
- Contains: plugin spec files such as `neo-tree.lua`, `opencode.lua`, `git.lua`, `fzf.lua`, `treesitter.lua`, `format.lua`, `editor.lua`, `ui.lua`.

**lua/neovia/**:
- Purpose: core behaviour and integration logic for worktrees, server lifecycle, notes, sessions, layout, diffview integration, SSE handling and tests.
  - Contains: `worktree.lua`, `server.lua`, `notes.lua`, `layout.lua`, `session.lua`, `sse.lua`, `diffview.lua`, `tabline.lua`, `pr.lua`, `env.lua`, `fs.lua`, `reload.lua`, `mode.lua`, `theme.lua`, `version.lua`, `magic_context.lua`, and a `tests/` subdirectory.
  - Key files: `lua/neovia/worktree.lua` (worktree lifecycle), `lua/neovia/server.lua` (opencode server management), `lua/neovia/notes.lua` (session notes buffer management), `lua/neovia/sse.lua` (global SSE connection to `/global/event`), `lua/neovia/magic_context.lua` (magic-context RPC client and status popup).

## Key File Locations

**Entry Points:** `init.lua`: bootstrap and initialise the configuration and modules on Neovim start.
**Configuration:** `lua/plugins/`: plugin specs and UI wiring.
**Core Logic:** `lua/neovia/`: worktree, server, notes, session, layout and helpers.
**Tests:** `lua/neovia/tests/`: unit and integration specs for the modules.

## Naming Conventions

**Files:** Use descriptive kebab/camel names for modules. Example: `worktree.lua`, `server.lua`, `notes.lua`.
**Directories:** Use lower-case single-word directories. Example: `plugins/`, `neovia/`, `tests/`.

## Where to Add New Code

**New plugin spec:** `lua/plugins/` — add a new file and register via `lazy.nvim` in `init.lua`.
**New core module:** `lua/neovia/<feature>.lua` — implement module API with `setup()` and expose `_internal` for tests; add tests to `lua/neovia/tests/<feature>_spec.lua`.
**Shared utilities:** `lua/neovia/fs.lua`, `lua/neovia/env.lua` — add helpers here and guard requires with `pcall` in callers.
**Tests:** co-locate tests in `lua/neovia/tests/` named `*_spec.lua` and run via `lua/neovia/tests/run.lua`.
