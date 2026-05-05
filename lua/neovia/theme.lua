-- neovia theme module
-- Persists catppuccin flavour to stdpath("state") so it survives restarts.
-- Flavours: latte (light), frappe, macchiato, mocha (dark).

local M = {}

--- @class neovia.ThemeOpts
--- @field state_path? string  Override the state file path (mainly for tests).

--- @type neovia.ThemeOpts
local opts = {}

--- Whether setup() has been called.
local initialised = false

--- Ordered list of catppuccin flavours.
--- @type string[]
M.flavours = { "latte", "frappe", "macchiato", "mocha" }

--- Current active flavour. Default is mocha (dark).
--- @type string
local current_flavour = "mocha"

--- Valid flavour lookup for O(1) validation.
local valid_flavours = {}
for _, f in ipairs(M.flavours) do valid_flavours[f] = true end

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

local ok_fs, fs = pcall(require, "neovia.fs")
local write_file = ok_fs and fs.write_file or function() end
local read_file = ok_fs and fs.read_file or function() return nil end

--- Map a flavour to its vim background value.
--- @param flavour string
--- @return string  "light" or "dark"
local function flavour_background(flavour)
  if flavour == "latte" then return "light" end
  return "dark"
end

--- Return the path to the state file.
--- @return string
local function state_path()
  return opts.state_path or (vim.fn.stdpath("state") .. "/theme.lua")
end

--- Save current flavour to the state file.
local function save()
  local path = state_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local content = string.format("return { flavour = %q }\n", current_flavour)
  write_file(path, content)
end

--- Load saved state from disk.
--- Handles migration from legacy format (background key -> flavour).
--- @return { flavour: string }|nil
local function load_state()
  local path = state_path()
  local raw = read_file(path)
  if not raw then return nil end
  local chunk, _ = load(raw)
  if not chunk then return nil end
  local ok, result = pcall(chunk)
  if not ok or type(result) ~= "table" then return nil end

  -- New format: { flavour = "mocha" }
  if result.flavour and valid_flavours[result.flavour] then
    return result
  end

  -- Legacy format: { background = "dark"|"light" } -> migrate
  if result.background then
    local flavour = result.background == "light" and "latte" or "mocha"
    return { flavour = flavour }
  end

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

--- Apply the colorscheme, silently ignoring E185 when the scheme
--- is not yet loaded (e.g. during tests or early init).
--- @param name string
local function try_colorscheme(name)
  local ok, err = pcall(vim.cmd.colorscheme, name)
  if not ok and err and not err:find("E185") then error(err) end
end

--- Set the active catppuccin flavour. Applies background, sets the
--- colorscheme, and persists the choice.
--- @param flavour string  One of: latte, frappe, macchiato, mocha.
function M.set_flavour(flavour)
  if not valid_flavours[flavour] then return end
  current_flavour = flavour
  vim.o.background = flavour_background(flavour)
  try_colorscheme("catppuccin-" .. flavour)
  save()
end

--- Return the currently active flavour.
--- @return string
function M.current_flavour()
  return current_flavour
end

--- Cycle to the next flavour (wraps around).
function M.toggle()
  local idx = 1
  for i, f in ipairs(M.flavours) do
    if f == current_flavour then idx = i; break end
  end
  local next_idx = (idx % #M.flavours) + 1
  M.set_flavour(M.flavours[next_idx])
end

--- Apply the persisted flavour. No-op if no state file exists.
function M.apply()
  local state = load_state()
  if state and state.flavour then
    current_flavour = state.flavour
    vim.o.background = flavour_background(state.flavour)
    try_colorscheme("catppuccin-" .. state.flavour)
  end
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  state_path = state_path,
  save = save,
  load = load_state,
  flavour_background = flavour_background,

  --- Set current flavour without applying colorscheme (for test setup).
  --- @param flavour string
  set_current_flavour = function(flavour)
    if valid_flavours[flavour] then current_flavour = flavour end
  end,

  --- Reset module state (for test isolation).
  reset = function()
    initialised = false
    opts = {}
    current_flavour = "mocha"
  end,
}

return M
