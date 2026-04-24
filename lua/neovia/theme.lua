-- neovia theme module
-- Persists background (light/dark) to stdpath("state") so it survives restarts.

local M = {}

--- @class neovia.ThemeOpts
--- @field state_path? string  Override the state file path (mainly for tests).

--- @type neovia.ThemeOpts
local opts = {}

--- Whether setup() has been called.
local initialised = false

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

local ok_fs, fs = pcall(require, "neovia.fs")
local write_file = ok_fs and fs.write_file or function() end
local read_file = ok_fs and fs.read_file or function() return nil end

--- Return the path to the state file.
--- @return string
local function state_path()
  return opts.state_path or (vim.fn.stdpath("state") .. "/theme.lua")
end

--- Save current background to the state file.
local function save()
  local path = state_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local content = string.format("return { background = %q }\n", vim.o.background)
  write_file(path, content)
end

--- Load saved state from disk.
--- @return { background: string }|nil
local function load()
  local path = state_path()
  local raw = read_file(path)
  if not raw then return nil end
  -- Evaluate the Lua content to get the table
  local chunk, err = loadstring(raw)
  if not chunk then return nil end
  local ok, result = pcall(chunk)
  if ok and type(result) == "table" then return result end
  return nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Setup the theme module. Idempotent.
--- @param user_opts? neovia.ThemeOpts
function M.setup(user_opts)
  if initialised then return end
  initialised = true
  opts = user_opts or {}
end

--- Toggle between light and dark, persisting the choice.
function M.toggle()
  vim.o.background = vim.o.background == "dark" and "light" or "dark"
  save()
end

--- Apply the persisted background. No-op if no state file exists.
function M.apply()
  local state = load()
  if state and state.background then
    vim.o.background = state.background
  end
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  state_path = state_path,
  save = save,
  load = load,

  --- Reset module state (for test isolation).
  reset = function()
    initialised = false
    opts = {}
  end,
}

return M
