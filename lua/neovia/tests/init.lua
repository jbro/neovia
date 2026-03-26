-- lua/neovia/tests/init.lua
-- Minimal init used by plenary when it spawns nvim per spec file.

-- Clean environment
vim.opt.runtimepath:remove(vim.fn.expand("~/.config/nvim"))
vim.opt.packpath:remove(vim.fn.expand("~/.local/share/nvim/site"))

-- Add project root so require("neovia.*") resolves
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h")
vim.opt.runtimepath:prepend(root)

-- Add plenary from the lazy.nvim store
local plenary_path = vim.fn.expand("~/.local/share/neovia/lazy/plenary.nvim")
vim.opt.runtimepath:append(plenary_path)
