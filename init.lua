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
-- Load plugins
------------------------------------------------------------------------
require("lazy").setup("plugins", {
  change_detection = { notify = false },
})

------------------------------------------------------------------------
-- Read-only mode
------------------------------------------------------------------------
require("neovia.mode").setup({ auto_relock = true })
vim.keymap.set("n", "<leader>u", function() require("neovia.mode").toggle() end, { desc = "Unlock/lock buffer" })
vim.keymap.set("n", "<leader>pp", function()
  local view = require("lazy.view")
  if view.visible() then
    view.view:close()
  else
    view.show()
  end
end, { desc = "Lazy" })
vim.keymap.set("n", "<leader>q", "<cmd>qa<cr>", { desc = "Quit all" })

------------------------------------------------------------------------
-- Open OpenCode on launch (input focused, insert mode)
------------------------------------------------------------------------
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    -- Defer so the UI is fully drawn before splitting
    vim.schedule(function()
      require("opencode.api").open_input()
    end)
  end,
})

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

