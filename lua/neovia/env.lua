-- lua/neovia/env.lua
-- Set environment variables before plugins spawn subprocesses.
--
-- Usage (in init.lua, before lazy.setup):
--   require("neovia.env").setup({
--     { name = "HAIP_API_KEY", exec = { "op", "read", "op://Employee/HAIP/..." } },
--     { name = "FOO", value = "bar" },
--   })
--
-- Each entry sets an environment variable. Provide `value` for a plain
-- string, or `exec` to run a command and use its stdout. A string `exec`
-- runs via shell; a table `exec` runs directly. File-based caching for
-- `exec` entries is opt-in via `cache` (path) + `ttl` (seconds).
--
-- Profiles: setup() also accepts a profiles config to support multiple
-- swappable sets of API keys / base URLs:
--   require("neovia.env").setup({
--     shared   = { { name = "FOO", value = "bar" } },  -- loaded for all profiles
--     default  = "staging",
--     profiles = {
--       staging = { { name = "API_KEY", exec = {...} }, { name = "BASE_URL", value = "..." } },
--       prod    = { { name = "API_KEY", exec = {...} }, { name = "BASE_URL", value = "..." } },
--     },
--   })
-- The active profile persists across restarts (stdpath("state")). Switching
-- profiles updates vim.env; the opencode server must be restarted (<leader>oE)
-- to inherit the new environment.

local M = {}

--- Whether setup() has been called.
local initialised = false

--- @type table?  The profiles config passed to setup() (nil in legacy mode).
local profiles_config = nil

--- @type string?  The name of the active profile (nil in legacy mode).
local active = nil

--- @class neovia.env.Var
--- @field name string        Environment variable name.
--- @field value? string      Plain value (set directly).
--- @field exec? string|string[]  Command to run. String: via shell. Table: direct.
--- @field cache? string      Cache file path (opt-in, requires exec).
--- @field ttl? integer       Cache lifetime in seconds (requires cache).

--- Return true when `path` exists and was modified less than `ttl` seconds ago.
--- @param path string
--- @param ttl integer
--- @return boolean
local function cache_fresh(path, ttl)
  local stat = vim.uv.fs_stat(path)
  if not stat then return false end
  local age = os.time() - stat.mtime.sec
  return age < ttl
end

local ok_fs, fs = pcall(require, "neovia.fs")
local read_file = ok_fs and fs.read_file or function() return nil end
local write_file = ok_fs and fs.write_file or function() end

--- Run a command and return trimmed stdout, or nil + error.
--- @param cmd string|string[]
--- @return string? value
--- @return string? err
local function exec(cmd)
  local opts = { text = true }
  if type(cmd) == "string" then
    cmd = { "sh", "-c", cmd }
  end
  local result = vim.system(cmd, opts):wait()
  if result.code ~= 0 then
    return nil, ("exit %d: %s"):format(result.code, result.stderr or "")
  end
  return vim.trim(result.stdout or "")
end

--- Load a single variable into vim.env.
--- @param spec neovia.env.Var
--- @return boolean ok
--- @return string? err
local function load_var(spec)
  -- Plain value
  if spec.value ~= nil then
    vim.env[spec.name] = spec.value
    return true
  end

  -- Try cache when both cache and ttl are set
  if spec.cache and spec.ttl and cache_fresh(spec.cache, spec.ttl) then
    local cached = read_file(spec.cache)
    if cached and #cached > 0 then
      vim.env[spec.name] = cached
      return true
    end
  end

  -- Run command
  local value, err = exec(spec.exec)
  if not value then
    return false, ("env: failed to load %s: %s"):format(spec.name, err or "unknown error")
  end

  if spec.cache then
    write_file(spec.cache, value)
  end

  vim.env[spec.name] = value
  return true
end

------------------------------------------------------------------------
-- Profiles
------------------------------------------------------------------------

--- Path to the file that persists the active profile name.
--- @return string
local function profile_state_file()
  return vim.fn.stdpath("state") .. "/neovia/env-profile"
end

--- Persist the active profile name to disk.
--- @param name string
local function save_profile(name)
  local path = profile_state_file()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  write_file(path, name)
end

--- Load the persisted active profile name, or nil.
--- @return string?
local function load_profile()
  local name = read_file(profile_state_file())
  if not name or name == "" then return nil end
  return vim.trim(name)
end

--- Detect whether a config is a profiles config (vs a flat spec list).
--- @param config table
--- @return boolean
local function is_profiles_config(config)
  return type(config) == "table" and type(config.profiles) == "table"
end

--- Sorted list of profile names from the active config.
--- @return string[]
function M.profiles()
  if not profiles_config then return {} end
  local names = {}
  for name in pairs(profiles_config.profiles) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Name of the active profile, or nil in legacy mode.
--- @return string?
function M.active_profile()
  return active
end

--- Load a list of env specs, notifying on each failure.
--- @param specs neovia.env.Var[]
local function load_specs(specs)
  for _, spec in ipairs(specs or {}) do
    local ok, err = load_var(spec)
    if not ok then
      vim.notify(err, vim.log.levels.WARN)
    end
  end
end

--- Select and load a profile, persisting the choice. The opencode server
--- must be restarted to inherit the new environment.
--- @param name string
--- @return boolean ok
--- @return string? err
function M.select_profile(name)
  if not profiles_config then
    return false, "env: no profiles configured"
  end
  local specs = profiles_config.profiles[name]
  if not specs then
    return false, ("env: unknown profile %q"):format(name)
  end

  load_specs(specs)
  active = name
  save_profile(name)
  return true
end

--- Resolve which profile should be active at startup: a valid persisted
--- selection wins, else the configured default, else the first sorted name.
--- @param config table
--- @return string?
local function resolve_active(config)
  local persisted = load_profile()
  if persisted and config.profiles[persisted] then
    return persisted
  end
  if config.default and config.profiles[config.default] then
    return config.default
  end
  local names = {}
  for name in pairs(config.profiles) do
    table.insert(names, name)
  end
  table.sort(names)
  return names[1]
end

--- Re-read the persisted selection and re-apply `shared` + the active
--- profile's specs to `vim.env`. Lets an instance adopt a profile chosen
--- by another instance (the selection is global) before restarting its
--- opencode server. No-op outside profiles mode.
--- @return boolean ok  True when a profile was applied.
function M.apply_active()
  if not profiles_config then return false end
  load_specs(profiles_config.shared)
  active = resolve_active(profiles_config)
  if active then
    load_specs(profiles_config.profiles[active])
    return true
  end
  return false
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- Configure and load environment variables.
--- Accepts either a flat list of specs (legacy) or a profiles config.
--- @param config neovia.env.Var[]|table
function M.setup(config)
  if initialised then return end
  initialised = true

  if is_profiles_config(config) then
    profiles_config = config
    load_specs(config.shared)
    active = resolve_active(config)
    if active then
      load_specs(config.profiles[active])
    end
    return
  end

  -- Legacy: flat list of specs.
  load_specs(config)
end

M._internal = {
  cache_fresh = cache_fresh,
  load_var = load_var,
  is_profiles_config = is_profiles_config,
  profile_state_file = profile_state_file,
  save_profile = save_profile,
  load_profile = load_profile,
  resolve_active = resolve_active,

  --- Reset module state (for test isolation / reload contract).
  reset = function()
    initialised = false
    profiles_config = nil
    active = nil
  end,
}

return M
