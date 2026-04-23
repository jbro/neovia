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

--- Ensure a directory exists, creating parents as needed.
--- Safe to call from fast event contexts (uses libuv, not Vimscript).
--- @param path string
local function mkdir_p(path)
  -- Split path into segments and build progressively
  local current = ""
  for segment in path:gmatch("[^/]+") do
    current = current .. "/" .. segment
    vim.uv.fs_mkdir(current, 493) -- 0755; ignores EEXIST
  end
end

--- Save port and PID to the state directory.
--- Safe to call from fast event contexts (stdout callbacks).
--- @param dir string  The state directory (not git common dir).
--- @param port number
--- @param pid number
local function save_server_info(dir, port, pid)
  mkdir_p(dir)
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

--- Timeout in milliseconds for the server to report its listening URL.
local START_TIMEOUT_MS = 15000

--- Synchronous timeout in milliseconds for ensure_running.
local SYNC_TIMEOUT_MS = 10000

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
  mkdir_p(dir)

  local log_path = dir .. "/server.log"
  local log_fd = vim.uv.fs_open(log_path, "w", 384)

  local cmd = { "opencode", "serve", "--port", "0" }
  local settled = false -- true once callback has been invoked
  local job -- forward-declare so the timeout closure can reference it

  -- Timeout: if the server doesn't report ready within START_TIMEOUT_MS,
  -- call back with an error so the caller doesn't hang forever.
  local timeout_timer = vim.uv.new_timer()
  timeout_timer:start(START_TIMEOUT_MS, 0, vim.schedule_wrap(function()
    if not timeout_timer:is_closing() then timeout_timer:close() end
    if not settled then
      settled = true
      -- Kill the orphan process so it doesn't run untracked
      if job and job.pid then
        pcall(vim.uv.kill, job.pid, 15)
        vim.defer_fn(function()
          if pid_alive(job.pid) then pcall(vim.uv.kill, job.pid, 9) end
        end, 1000)
      end
      clear_server_info(dir)
      callback("opencode server did not start within " .. (START_TIMEOUT_MS / 1000) .. "s")
    end
  end))

  job = vim.system(cmd, {
    detach = true,
    stdout = function(err, data)
      if err then
        if not settled then
          settled = true
          if not timeout_timer:is_closing() then timeout_timer:close() end
          vim.schedule(function() callback("server stdout error: " .. tostring(err)) end)
        end
        return
      end
      if data then
        -- Log stdout
        if log_fd then pcall(vim.uv.fs_write, log_fd, data, -1) end

        local url = data:match("opencode server listening on ([^%s]+)")
        if url and not settled then
          settled = true
          if not timeout_timer:is_closing() then timeout_timer:close() end
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
    -- On exit: close log fd, cancel timeout
    if log_fd then pcall(vim.uv.fs_close, log_fd) end
    if not timeout_timer:is_closing() then
      pcall(timeout_timer.close, timeout_timer)
    end
  end)

  if not job or not job.pid then
    settled = true
    if not timeout_timer:is_closing() then timeout_timer:close() end
    if log_fd then pcall(vim.uv.fs_close, log_fd) end
    callback("failed to spawn opencode serve")
  end
end

--- Stop the opencode server synchronously.
--- Sends SIGTERM, waits up to 2s for exit, then SIGKILL if needed.
--- @param git_common_dir string
--- @return boolean stopped  True if a process was killed.
local function stop(git_common_dir)
  local dir = state_dir(git_common_dir)
  local info = load_server_info(dir)
  if not info or not info.pid or info.pid <= 0 then
    clear_server_info(dir)
    return false
  end

  local pid = info.pid
  if pid_alive(pid) then
    pcall(vim.uv.kill, pid, 15) -- SIGTERM

    -- Poll for process death (up to 2s, checking every 100ms)
    local waited = 0
    while pid_alive(pid) and waited < 2000 do
      vim.wait(100, function() return false end) -- sleep 100ms
      waited = waited + 100
    end

    -- Force kill if still alive
    if pid_alive(pid) then
      pcall(vim.uv.kill, pid, 9) -- SIGKILL
      -- Brief wait for SIGKILL to take effect
      vim.wait(200, function() return not pid_alive(pid) end)
    end
  end

  clear_server_info(dir)
  return true
end

--- Restart the opencode server.
--- Stops the current server (waits for exit), then starts a new one.
--- @param git_common_dir string
--- @param callback fun(err: string?, port: number?)
local function restart(git_common_dir, callback)
  stop(git_common_dir) -- synchronous: blocks until process is dead
  start(git_common_dir, callback)
end

------------------------------------------------------------------------
-- Synchronous start (for use before plugin load)
------------------------------------------------------------------------

--- Ensure the server is running, starting it synchronously if needed.
--- Delegates to the async start() function and blocks with vim.wait()
--- until the callback fires. Intended for use during init.lua before
--- lazy.setup() so the port is available for plugin config.
--- @param git_common_dir string
--- @return number? port, string? err
local function ensure_running(git_common_dir)
  local dir = state_dir(git_common_dir)
  local s = status(dir)
  if s.state == "running" then
    return s.port, nil
  end

  local done = false
  local result_port, result_err

  start(git_common_dir, function(err, port)
    result_err = err
    result_port = port
    done = true
  end)

  -- Block until the async callback fires or we time out.
  vim.wait(SYNC_TIMEOUT_MS, function() return done end, 50)

  if not done then
    return nil, "opencode server did not start within " .. (SYNC_TIMEOUT_MS / 1000) .. "s"
  end

  return result_port, result_err
end

------------------------------------------------------------------------
-- Git common dir resolution
------------------------------------------------------------------------

--- Resolve the git common dir for the current working directory.
--- Uses vim.uv.fs_realpath to resolve symlinks, matching the shell
--- wrapper's realpath-based canonicalisation.
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
  -- Resolve symlinks so the hash matches the shell wrapper
  local real = vim.uv.fs_realpath(dir)
  if real then
    return real:gsub("/$", "")
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

--- Ensure the server is running for the current repo, starting it
--- synchronously if needed. Returns port on success, nil + error on
--- failure. Blocks the event loop -- intended for use during startup
--- before lazy.setup().
--- @return number? port, string? err
function M.ensure_running()
  local gcd = resolve_git_common_dir()
  if not gcd then
    return nil, "not in a git repository"
  end
  return ensure_running(gcd)
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
  ensure_running = ensure_running,
  resolve_git_common_dir = resolve_git_common_dir,

  --- Reset module state (for test isolation / reload contract).
  reset = function()
    initialised = false
  end,
}

return M
