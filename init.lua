-- neovia init.lua
-- Bootstrap lazy.nvim, set options, load plugins.

------------------------------------------------------------------------
-- Leader (must be set before lazy.nvim loads plugins)
------------------------------------------------------------------------
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Disable netrw (neo-tree replaces it; netrw's lcd and mouse handling
-- conflict with tcd-based worktree switching and the tabline).
vim.g.loaded_netrwPlugin = 1
vim.g.loaded_netrw = 1

------------------------------------------------------------------------
-- Bootstrap lazy.nvim
------------------------------------------------------------------------
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

------------------------------------------------------------------------
-- Core options
------------------------------------------------------------------------

-- Clear shell fzf colors so fzf-lua can derive them from the colorscheme.
vim.env.FZF_DEFAULT_OPTS = nil

-- Indentation (fallback; vim-sleuth auto-detects per buffer)
vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2

-- Search
vim.o.ignorecase = true
vim.o.smartcase = true

-- Display
vim.o.number = true
vim.o.relativenumber = true
vim.o.signcolumn = "yes"
vim.o.list = true
vim.opt.listchars = { tab = "→ ", trail = "·", nbsp = "␣" }
vim.o.wrap = false
vim.o.belloff = ""
vim.o.visualbell = true

-- Undo
vim.o.undofile = true

-- Folds (treesitter-based, not auto-collapsed)
vim.o.foldmethod = "expr"
vim.o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.o.foldenable = false

-- Diff
vim.opt.diffopt:append("vertical")

-- Completion
vim.o.completeopt = "menuone,noselect"
vim.o.wildmode = "longest,full"

-- Spell (treesitter-aware: only checks strings/comments, not code)
vim.o.spell = true
vim.o.spelllang = "en_gb,da"
vim.o.spelloptions = "camel"

------------------------------------------------------------------------
-- Core keymaps
------------------------------------------------------------------------

-- F1 fat finger protection
vim.keymap.set({ "n", "i" }, "<F1>", "<Nop>")

-- Clear search highlights on Esc
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

------------------------------------------------------------------------
-- Environment (must run before plugins so subprocesses inherit the env)
-- Machine-specific config lives in .env.lua (gitignored).
-- Guarded: env vars persist in the process, skip on re-source.
------------------------------------------------------------------------
if not vim.g.neovia_env_loaded then
  vim.g.neovia_env_loaded = true
  local env_specs = loadfile(vim.fn.stdpath("config") .. "/.env.lua")
  if env_specs then
    require("neovia.env").setup(env_specs())
  end
end

------------------------------------------------------------------------
-- Server (start opencode serve before plugins so the port is available)
-- Guarded: the server survives Neovim restarts, skip on re-source.
------------------------------------------------------------------------
if not vim.g.neovia_server_started then
  vim.g.neovia_server_started = true
  require("neovia.server").setup()
  local port, err = require("neovia.server").ensure_running()
  if port then
    vim.g.neovia_server_port = port
  elseif err then
    vim.notify("neovia: server start failed: " .. err, vim.log.levels.WARN)
  end
end

------------------------------------------------------------------------
-- Load plugins (skip on re-source; use :Lazy sync to update plugins)
------------------------------------------------------------------------
if not vim.g.neovia_lazy_loaded then
  vim.g.neovia_lazy_loaded = true
  require("lazy").setup("plugins", {
    change_detection = { notify = false },
  })
end

------------------------------------------------------------------------
-- Version tracking (server vs system binary, statusline display)
------------------------------------------------------------------------
require("neovia.version").setup()

------------------------------------------------------------------------
-- Layout (enforce code + opencode panels, open opencode on launch)
------------------------------------------------------------------------
require("neovia.layout").setup()

------------------------------------------------------------------------
-- Worktree (SSE subscriptions, tabline status tracking)
------------------------------------------------------------------------
require("neovia.worktree").setup()

------------------------------------------------------------------------
-- Diffview (per-worktree diffview tab management)
------------------------------------------------------------------------
require("neovia.diffview").setup()

------------------------------------------------------------------------
-- PR status (GitHub PR polling for tabline/statusline)
------------------------------------------------------------------------
require("neovia.pr").setup()

------------------------------------------------------------------------
-- Theme (persist light/dark across restarts)
------------------------------------------------------------------------
require("neovia.theme").setup()
require("neovia.theme").apply()

------------------------------------------------------------------------
-- Server keymaps (lifecycle management)
------------------------------------------------------------------------
vim.keymap.set("n", "<leader>oEs", function()
  local s = require("neovia.server").status()
  if s.state == "running" then
    vim.notify(("opencode server: running (port %d, pid %d)"):format(s.port, s.pid), vim.log.levels.INFO)
  else
    vim.notify("opencode server: stopped", vim.log.levels.WARN)
  end
end, { desc = "Server status" })

vim.keymap.set("n", "<leader>oEr", function()
  vim.notify("opencode server: restarting...", vim.log.levels.INFO)
  require("neovia.server").restart(function(err, port)
    vim.schedule(function()
      if err then
        vim.notify("opencode server: restart failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify(("opencode server: restarted on port %d"):format(port), vim.log.levels.INFO)
        require("neovia.layout").restore_layout()
      end
    end)
  end)
end, { desc = "Restart server" })

vim.keymap.set("n", "<leader>oEq", function()
  local stopped = require("neovia.server").stop()
  if stopped then
    vim.notify("opencode server: stopped", vim.log.levels.INFO)
  else
    vim.notify("opencode server: was not running", vim.log.levels.WARN)
  end
end, { desc = "Shutdown server" })

vim.keymap.set("n", "<leader>oEd", function()
  vim.notify("opencode: reconnecting and restoring layout...", vim.log.levels.INFO)
  require("neovia.layout").restore_layout()
end, { desc = "Redraw UI" })

------------------------------------------------------------------------
-- Magic Context integration (context/memory status from RPC)
------------------------------------------------------------------------
require("neovia.magic_context").setup()
vim.keymap.set("n", "<leader>oc", function() require("neovia.magic_context").show_popup() end, { desc = "Context status" })

------------------------------------------------------------------------
-- Session notes (per-worktree persistent notes)
------------------------------------------------------------------------
require("neovia.notes").setup()

------------------------------------------------------------------------
-- Read-only mode
------------------------------------------------------------------------
require("neovia.mode").setup({ auto_relock = true })
vim.keymap.set("n", "<leader>bu", function() require("neovia.mode").toggle() end, { desc = "Unlock/lock buffer" })
vim.keymap.set("n", "<leader>bw", function() vim.wo.wrap = not vim.wo.wrap end, { desc = "Toggle wrap" })
vim.keymap.set("n", "<leader>pp", function()
  local view = require("lazy.view")
  if view.visible() then
    view.view:close()
  else
    view.show()
  end
end, { desc = "Lazy" })
vim.keymap.set("n", "<leader>pr", function() require("neovia.reload").reload() end, { desc = "Reload config" })
vim.keymap.set("n", "<leader>l", function() require("neovia.layout").restore_layout() end, { desc = "Restore layout" })
vim.keymap.set("n", "<leader>tl", function() require("neovia.theme").set_flavour("latte") end, { desc = "Latte (light)" })
vim.keymap.set("n", "<leader>tf", function() require("neovia.theme").set_flavour("frappe") end, { desc = "Frappe" })
vim.keymap.set("n", "<leader>tm", function() require("neovia.theme").set_flavour("macchiato") end, { desc = "Macchiato" })
vim.keymap.set("n", "<leader>td", function() require("neovia.theme").set_flavour("mocha") end, { desc = "Mocha (darkest)" })
vim.keymap.set("n", "<leader>tn", function() require("neovia.theme").toggle() end, { desc = "Next flavour" })
vim.keymap.set("n", "<leader>q", "<cmd>qa<cr>", { desc = "Quit all" })

------------------------------------------------------------------------
-- LSP configuration (native 0.11+)
------------------------------------------------------------------------
vim.lsp.config("ts_ls", {
  cmd = { "typescript-language-server", "--stdio" },
  filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
  root_markers = { "tsconfig.json", "jsconfig.json", "package.json", ".git" },
})

vim.lsp.config("gopls", {
  cmd = { "gopls" },
  filetypes = { "go", "gomod", "gowork", "gotmpl" },
  root_markers = { "go.mod", "go.work", ".git" },
})

vim.lsp.enable({ "ts_ls", "gopls" })

