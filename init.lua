-- neovia init.lua
-- Bootstrap lazy.nvim, set options, load plugins.

------------------------------------------------------------------------
-- Leader (must be set before lazy.nvim loads plugins)
------------------------------------------------------------------------
vim.g.mapleader = " "
vim.g.maplocalleader = " "

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
-- Load plugins (skip on re-source; use :Lazy sync to update plugins)
------------------------------------------------------------------------
if not vim.g.neovia_lazy_loaded then
  vim.g.neovia_lazy_loaded = true
  require("lazy").setup("plugins", {
    change_detection = { notify = false },
  })
end

------------------------------------------------------------------------
-- Layout (enforce code + opencode panels, open opencode on launch)
------------------------------------------------------------------------
require("neovia.layout").setup()

------------------------------------------------------------------------
-- Theme (persist light/dark across restarts)
------------------------------------------------------------------------
require("neovia.theme").setup()
require("neovia.theme").apply()

------------------------------------------------------------------------
-- Read-only mode
------------------------------------------------------------------------
require("neovia.mode").setup({ auto_relock = true })
vim.keymap.set("n", "<leader>bu", function() require("neovia.mode").toggle() end, { desc = "Unlock/lock buffer" })
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
vim.keymap.set("n", "<leader>t", function() require("neovia.theme").toggle() end, { desc = "Toggle light/dark" })
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

