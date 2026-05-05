-- lua/neovia/version.lua
-- Track opencode server and system binary versions.
--
-- The server version is queried from the running server's health
-- endpoint (GET /global/health -> {"healthy":true,"version":"x.y.z"}).
-- The system binary version comes from `opencode --version`.
-- When the system binary is newer than the running server, the
-- statusline component turns yellow to prompt a server restart.

local M = {}

local initialised = false

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

--- @class neovia.version.State
--- @field server_version string?  Version reported by the running server.
--- @field system_version string?  Version of the locally installed binary.
--- @field system_checked_at number  os.time() of last system version check.
--- @field server_checked_at number  os.time() of last server version check.

--- @type neovia.version.State
local state = {
  server_version = nil,
  system_version = nil,
  system_checked_at = 0,
  server_checked_at = 0,
}

--- How often (seconds) to re-check the system binary version.
local SYSTEM_CHECK_TTL = 300  -- 5 minutes

--- How often (seconds) to re-check the server version.
local SERVER_CHECK_TTL = 300  -- 5 minutes

------------------------------------------------------------------------
-- Version comparison
------------------------------------------------------------------------

--- Parse a semver string into {major, minor, patch}.
--- Returns nil for malformed input.
--- @param ver string?
--- @return {major: number, minor: number, patch: number}?
local function parse_semver(ver)
  if not ver then return nil end
  local major, minor, patch = ver:match("^v?(%d+)%.(%d+)%.(%d+)")
  if not major then return nil end
  return { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch) }
end

--- Compare two semver tables. Returns:
---   -1 if a < b, 0 if a == b, 1 if a > b.
--- @param a {major: number, minor: number, patch: number}
--- @param b {major: number, minor: number, patch: number}
--- @return integer
local function compare_semver(a, b)
  if a.major ~= b.major then return a.major < b.major and -1 or 1 end
  if a.minor ~= b.minor then return a.minor < b.minor and -1 or 1 end
  if a.patch ~= b.patch then return a.patch < b.patch and -1 or 1 end
  return 0
end

--- Check whether system version is newer than server version.
--- @param server string?
--- @param system string?
--- @return boolean
local function update_available(server, system)
  local sv = parse_semver(server)
  local sy = parse_semver(system)
  if not sv or not sy then return false end
  return compare_semver(sv, sy) < 0
end

------------------------------------------------------------------------
-- Server version (via health endpoint)
------------------------------------------------------------------------

--- Parse the version from a health endpoint JSON response.
--- @param body string?
--- @return string?
local function parse_health_version(body)
  if not body then return nil end
  local ver = body:match('"version"%s*:%s*"([^"]+)"')
  return ver
end

--- Query the server's health endpoint for its version.
--- @param port number
--- @return string?
local function query_server_version(port)
  local url = string.format("http://127.0.0.1:%d/global/health", port)
  local ok, result = pcall(vim.system,
    { "curl", "-sf", "--max-time", "2", url },
    { text = true })
  if not ok or not result then return nil end
  local out = result:wait()
  if out.code ~= 0 or not out.stdout then return nil end
  return parse_health_version(out.stdout)
end

--- Return the server version, using a TTL cache.
--- @param now number?  Current time (injectable for tests).
--- @return string?
local function get_server_version(now)
  now = now or os.time()
  if state.server_version and (now - state.server_checked_at) < SERVER_CHECK_TTL then
    return state.server_version
  end
  local ok_srv, srv = pcall(require, "neovia.server")
  if not ok_srv then return state.server_version end
  local status = srv.status()
  if status.state ~= "running" or not status.port then return state.server_version end
  local ver = query_server_version(status.port)
  if ver then
    state.server_version = ver
    state.server_checked_at = now
  end
  return state.server_version
end

------------------------------------------------------------------------
-- System binary version
------------------------------------------------------------------------

--- Run `opencode --version` and return the trimmed output.
--- Synchronous, blocks briefly.
--- @return string?
local function query_system_version()
  local ok, result = pcall(vim.system, { "opencode", "--version" }, { text = true })
  if not ok or not result then return nil end
  local out = result:wait()
  if out.code ~= 0 or not out.stdout then return nil end
  return vim.trim(out.stdout)
end

--- Return the system binary version, using a TTL cache.
--- @param now number?  Current time (injectable for tests).
--- @return string?
local function get_system_version(now)
  now = now or os.time()
  if state.system_version and (now - state.system_checked_at) < SYSTEM_CHECK_TTL then
    return state.system_version
  end
  local ver = query_system_version()
  if ver then
    state.system_version = ver
    state.system_checked_at = now
  end
  return state.system_version
end

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

--- Resolve status colours from the authoritative source (tabline module).
--- Falls back to hardcoded values if tabline is not loaded.
--- @return string green, string yellow
local function resolve_colors()
  local ok_tl, tl = pcall(require, "neovia.tabline")
  if ok_tl and tl.status_colors then
    return tl.status_colors.idle or "#a6e3a1",
           tl.status_colors.responding or "#f9e2af"
  end
  return "#a6e3a1", "#f9e2af"
end

--- Build display info for the statusline.
--- @return { text: string, hl: table }
local function version_display()
  local server = state.server_version
  if not server then
    return { text = "", hl = {} }
  end

  local system = state.system_version
  local outdated = update_available(server, system)
  local green, yellow = resolve_colors()

  local text = "v" .. server
  local hl
  if outdated then
    hl = { fg = yellow }
  else
    hl = { fg = green }
  end

  return { text = text, hl = hl }
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Initialise the module. Idempotent.
--- Call after server.ensure_running() so the port is known.
function M.setup()
  if initialised then return end
  initialised = true

  -- Prime both caches asynchronously to avoid blocking startup.
  vim.schedule(function()
    get_server_version()
    get_system_version()
  end)
end

--- Get the version display info for the statusline.
--- @return { text: string, hl: table }
function M.display()
  return version_display()
end

--- Get the current server version (may trigger a refresh).
--- @return string?
function M.get_server_version()
  return state.server_version
end

--- Get the current system version (may trigger a refresh).
--- @return string?
function M.get_system_version()
  return state.system_version
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  parse_semver = parse_semver,
  compare_semver = compare_semver,
  update_available = update_available,
  parse_health_version = parse_health_version,
  query_server_version = query_server_version,
  get_server_version = get_server_version,
  query_system_version = query_system_version,
  get_system_version = get_system_version,
  version_display = version_display,

  --- Direct access to state for tests.
  get_state = function() return state end,

  --- Set state directly for tests.
  set_state = function(s)
    state.server_version = s.server_version
    state.system_version = s.system_version
    state.system_checked_at = s.system_checked_at or 0
    state.server_checked_at = s.server_checked_at or 0
  end,

  --- Reset module state (reload contract).
  reset = function()
    initialised = false
    state = {
      server_version = nil,
      system_version = nil,
      system_checked_at = 0,
      server_checked_at = 0,
    }
  end,
}

return M
