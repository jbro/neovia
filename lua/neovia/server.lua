-- lua/neovia/server.lua
-- Manage an external opencode server process (start, stop, status).
--
-- The server runs independently of Neovim so restarts are non-disruptive.
-- State (port, PID) is persisted to stdpath("state")/server/<hash>/
-- so multiple Neovim instances and shell restarts can discover the
-- running server.

local M = {}

--- Whether setup() has been called.
local initialised = false

------------------------------------------------------------------------
-- File I/O (delegated to neovia.fs)
------------------------------------------------------------------------

local ok_fs, fs = pcall(require, "neovia.fs")
local read_file = ok_fs and fs.read_file or function() return nil end
local write_file = ok_fs and fs.write_file or function() end

------------------------------------------------------------------------
-- Path helpers
------------------------------------------------------------------------

--- Return a deterministic state directory for a given git common dir.
--- @param git_common_dir string
--- @return string
local function state_dir(git_common_dir)
  -- Simple hash: use vim.fn.sha256 for a filesystem-safe deterministic key
  local hash = vim.fn.sha256(git_common_dir):sub(1, 16)
  return vim.fn.stdpath("state") .. "/server/" .. hash
end

--- Return the port file path for a given git common dir.
--- @param git_common_dir string
--- @return string
local function port_file(git_common_dir)
  return state_dir(git_common_dir) .. "/port"
end

--- Return the PID file path for a given git common dir.
--- @param git_common_dir string
--- @return string
local function pid_file(git_common_dir)
  return state_dir(git_common_dir) .. "/pid"
end

------------------------------------------------------------------------
-- Process helpers
------------------------------------------------------------------------

--- Check whether a PID is alive (signal 0 test).
--- @param pid number
--- @return boolean
local function pid_alive(pid)
  if pid <= 0 then return false end
  local ok, ret = pcall(vim.uv.kill, pid, 0)
  -- vim.uv.kill returns 0 when the process exists, nil when it doesn't.
  -- pcall catches any Lua error. We need both: no error AND return == 0.
  return ok and ret == 0
end

------------------------------------------------------------------------
-- Server info persistence
------------------------------------------------------------------------

--- @class neovia.server.Info
--- @field port number
--- @field pid number

--- Save port and PID to the state directory.
--- @param dir string  The state directory (not git common dir).
--- @param port number
--- @param pid number
local function save_server_info(dir, port, pid)
  vim.fn.mkdir(dir, "p")
  write_file(dir .. "/port", tostring(port))
  write_file(dir .. "/pid", tostring(pid))
end

--- Load port and PID from the state directory.
--- @param dir string  The state directory.
--- @return neovia.server.Info?
local function load_server_info(dir)
  local port_str = read_file(dir .. "/port")
  local pid_str = read_file(dir .. "/pid")
  if not port_str or port_str == "" then return nil end
  local port = tonumber(port_str)
  local pid = tonumber(pid_str)
  if not port then return nil end
  return { port = port, pid = pid or 0 }
end

--- Remove port and PID files from the state directory.
--- @param dir string  The state directory.
local function clear_server_info(dir)
  os.remove(dir .. "/port")
  os.remove(dir .. "/pid")
end

------------------------------------------------------------------------
-- Status
------------------------------------------------------------------------

--- @class neovia.server.Status
--- @field state "running"|"stopped"
--- @field port number?
--- @field pid number?

--- Return the current server status for a given state directory.
--- @param dir string  The state directory.
--- @return neovia.server.Status
local function status(dir)
  local info = load_server_info(dir)
  if not info then
    return { state = "stopped" }
  end
  if info.pid and info.pid > 0 and pid_alive(info.pid) then
    return { state = "running", port = info.port, pid = info.pid }
  end
  return { state = "stopped" }
end

------------------------------------------------------------------------
-- Port reading (for plugin config)
------------------------------------------------------------------------

--- Read the server port if the server is alive.
--- @param dir string  The state directory.
--- @return number?
local function read_port(dir)
  local s = status(dir)
  if s.state == "running" then
    return s.port
  end
  return nil
end

------------------------------------------------------------------------
-- URL parsing
------------------------------------------------------------------------

--- Extract the port from an opencode server URL.
--- @param url string?
--- @return number?
local function parse_server_url(url)
  if not url then return nil end
  local port_str = url:match(":(%d+)%s*$")
  if not port_str then return nil end
  return tonumber(port_str)
end

------------------------------------------------------------------------
-- Server lifecycle
------------------------------------------------------------------------

--- Start the opencode server in the background.
--- @param git_common_dir string
--- @param callback fun(err: string?, port: number?)
local function start(git_common_dir, callback)
  local dir = state_dir(git_common_dir)
  local s = status(dir)
  if s.state == "running" then
    callback(nil, s.port)
    return
  end

  -- Clear stale info
  clear_server_info(dir)
  vim.fn.mkdir(dir, "p")

  local log_path = dir .. "/server.log"
  local log_fd = vim.uv.fs_open(log_path, "w", 384)

  local cmd = { "opencode", "serve", "--port", "0" }
  local ready = false

  local job = vim.system(cmd, {
    detach = true,
    stdout = function(err, data)
      if err then
        if not ready then
          ready = true
          vim.schedule(function() callback("server stdout error: " .. tostring(err)) end)
        end
        return
      end
      if data then
        -- Log stdout
        if log_fd then pcall(vim.uv.fs_write, log_fd, data, -1) end

        local url = data:match("opencode server listening on ([^%s]+)")
        if url and not ready then
          ready = true
          local port = parse_server_url(url)
          if port and job and job.pid then
            save_server_info(dir, port, job.pid)
            vim.schedule(function() callback(nil, port) end)
          else
            vim.schedule(function() callback("failed to parse server URL: " .. tostring(url)) end)
          end
        end
      end
    end,
    stderr = function(_, data)
      if data and log_fd then pcall(vim.uv.fs_write, log_fd, data, -1) end
    end,
  }, function()
    -- On exit: close log fd
    if log_fd then pcall(vim.uv.fs_close, log_fd) end
  end)

  if not job or not job.pid then
    if log_fd then pcall(vim.uv.fs_close, log_fd) end
    callback("failed to spawn opencode serve")
  end
end

--- Stop the opencode server.
--- @param git_common_dir string
--- @return boolean stopped  True if a process was killed.
local function stop(git_common_dir)
  local dir = state_dir(git_common_dir)
  local info = load_server_info(dir)
  if not info or not info.pid or info.pid <= 0 then
    clear_server_info(dir)
    return false
  end

  if pid_alive(info.pid) then
    pcall(vim.uv.kill, info.pid, 15) -- SIGTERM
    -- Give it a moment, then force kill
    vim.defer_fn(function()
      if pid_alive(info.pid) then
        pcall(vim.uv.kill, info.pid, 9) -- SIGKILL
      end
    end, 1000)
  end

  clear_server_info(dir)
  return true
end

--- Restart the opencode server.
--- @param git_common_dir string
--- @param callback fun(err: string?, port: number?)
local function restart(git_common_dir, callback)
  stop(git_common_dir)
  -- Allow process to exit before restarting
  vim.defer_fn(function()
    start(git_common_dir, callback)
  end, 1500)
end

------------------------------------------------------------------------
-- Git common dir resolution
------------------------------------------------------------------------

--- Resolve the git common dir for the current working directory.
--- @return string?
local function resolve_git_common_dir()
  local result = vim.system({ "git", "rev-parse", "--git-common-dir" }, { text = true }):wait()
  if result.code ~= 0 then return nil end
  local dir = vim.trim(result.stdout or "")
  if dir == "" then return nil end
  -- Resolve to absolute path
  if not dir:match("^/") then
    dir = vim.fn.getcwd() .. "/" .. dir
  end
  return vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Initialise the module. Idempotent.
function M.setup()
  if initialised then return end
  initialised = true
end

--- Get the server status for the current repo.
--- @return neovia.server.Status
function M.status()
  local gcd = resolve_git_common_dir()
  if not gcd then return { state = "stopped" } end
  return status(state_dir(gcd))
end

--- Read the server port for the current repo (for plugin config).
--- @return number?
function M.read_port()
  local gcd = resolve_git_common_dir()
  if not gcd then return nil end
  return read_port(state_dir(gcd))
end

--- Start the server for the current repo.
--- @param callback fun(err: string?, port: number?)
function M.start(callback)
  local gcd = resolve_git_common_dir()
  if not gcd then
    callback("not in a git repository")
    return
  end
  start(gcd, callback)
end

--- Stop the server for the current repo.
--- @return boolean
function M.stop()
  local gcd = resolve_git_common_dir()
  if not gcd then return false end
  return stop(gcd)
end

--- Restart the server for the current repo.
--- @param callback fun(err: string?, port: number?)
function M.restart(callback)
  local gcd = resolve_git_common_dir()
  if not gcd then
    callback("not in a git repository")
    return
  end
  restart(gcd, callback)
end

M._internal = {
  state_dir = state_dir,
  port_file = port_file,
  pid_file = pid_file,
  pid_alive = pid_alive,
  save_server_info = save_server_info,
  load_server_info = load_server_info,
  clear_server_info = clear_server_info,
  status = status,
  read_port = read_port,
  parse_server_url = parse_server_url,
  stop = stop,
  resolve_git_common_dir = resolve_git_common_dir,

  --- Reset module state (for test isolation / reload contract).
  reset = function()
    initialised = false
  end,
}

return M
