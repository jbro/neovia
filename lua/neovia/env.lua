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

local M = {}

--- Whether setup() has been called.
local initialised = false

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

--- Configure and load environment variables.
--- @param specs neovia.env.Var[]
function M.setup(specs)
  if initialised then return end
  initialised = true

  for _, spec in ipairs(specs) do
    local ok, err = load_var(spec)
    if not ok then
      vim.notify(err, vim.log.levels.WARN)
    end
  end
end

M._internal = {
  cache_fresh = cache_fresh,
  load_var = load_var,

  --- Reset module state (for test isolation / reload contract).
  reset = function()
    initialised = false
  end,
}

return M
