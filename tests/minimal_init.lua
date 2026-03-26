-- tests/minimal_init.lua
-- Minimal Neovim init for running tests headlessly via plenary.

-- Strip user config
vim.opt.runtimepath:remove(vim.fn.expand("~/.config/nvim"))
vim.opt.packpath:remove(vim.fn.expand("~/.local/share/nvim/site"))

-- Add project root so `require("neovia.worktree")` resolves
local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)

-- Add plenary from the lazy.nvim store (already installed as a dependency)
local plenary_path = vim.fn.expand("~/.local/share/neovia/lazy/plenary.nvim")
vim.opt.runtimepath:append(plenary_path)
