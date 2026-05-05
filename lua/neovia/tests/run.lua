#!/usr/bin/env -S nvim -l
-- lua/neovia/tests/run.lua
-- Run neovia tests: nvim -l lua/neovia/tests/run.lua [spec_pattern]

-- Ensure stdpath() resolves to neovia-specific directories
vim.env.NVIM_APPNAME = "neovia"

-- Resolve paths relative to this script
local script = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fn.fnamemodify(script, ":h")
local root = vim.fn.fnamemodify(script, ":h:h:h:h")

-- Clean environment
vim.opt.runtimepath:remove(vim.fn.expand("~/.config/nvim"))
vim.opt.packpath:remove(vim.fn.expand("~/.local/share/nvim/site"))

-- Add project root so require("neovia.*") resolves
vim.opt.runtimepath:prepend(root)

-- Add plenary and nui from the lazy.nvim store
local plenary_path = vim.fn.expand("~/.local/share/neovia/lazy/plenary.nvim")
vim.opt.runtimepath:append(plenary_path)
local nui_path = vim.fn.expand("~/.local/share/neovia/lazy/nui.nvim")
vim.opt.runtimepath:append(nui_path)

-- Run specs
local target = arg[1] or test_dir

print("Running tests in " .. target .. " ...")

require("plenary.test_harness").test_directory(target, {
  minimal_init = test_dir .. "/init.lua",
  sequential = true,
})
