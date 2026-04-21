-- lua/neovia/reload.lua
-- Reload neovia modules and re-source init.lua.
--
-- Usage: require("neovia.reload").reload()
-- Bound to <leader>pr in init.lua.
--
-- Steps:
--   1. Collect all package.loaded keys matching "neovia.*" (excluding tests).
--   2. Call _internal.reset() on each loaded module (tears down state, augroups).
--   3. Clear them from package.loaded so require() loads fresh code.
--   4. Re-source init.lua (options, keymaps, module setup all re-run).
--   5. Notify the user.

local M = {}

--- Find all package.loaded keys that belong to neovia (excluding tests).
--- @param loaded table  The package.loaded table (or a test double).
--- @return string[]
local function find_module_keys(loaded)
  local keys = {}
  for key in pairs(loaded) do
    if key:match("^neovia%.") and not key:match("^neovia%.tests%.") then
      table.insert(keys, key)
    end
  end
  return keys
end

--- Call _internal.reset() on a module if it exists.
--- @param mod table  The loaded module table.
local function reset_module(mod)
  if type(mod) ~= "table" then return end
  local internal = mod._internal
  if type(internal) ~= "table" then return end
  if type(internal.reset) ~= "function" then return end
  internal.reset()
end

--- Reload all neovia modules and re-source init.lua.
function M.reload()
  local keys = find_module_keys(package.loaded)

  -- Reset each module before clearing (reset needs the old module reference)
  for _, key in ipairs(keys) do
    local mod = package.loaded[key]
    reset_module(mod)
  end

  -- Clear from package.loaded so require() picks up fresh code
  for _, key in ipairs(keys) do
    package.loaded[key] = nil
  end

  -- Re-source init.lua (guarded lazy.setup/env.setup will be skipped)
  local config_path = vim.fn.stdpath("config") .. "/init.lua"
  local ok, err = pcall(dofile, config_path)

  if ok then
    vim.notify(("neovia: reloaded %d modules"):format(#keys), vim.log.levels.INFO)
  else
    vim.notify("neovia: reload failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  find_module_keys = find_module_keys,
  reset_module = reset_module,
}

return M
