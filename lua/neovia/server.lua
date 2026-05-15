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

--- Kill a process and all its children. SIGTERM first, then SIGKILL.
--- Safe to call with nil or non-existent PIDs.
--- @param pid number?
local function kill_process_tree(pid)
  if not pid or pid <= 0 then return end

  -- Discover children before killing the parent
  local children = {}
  local ok, result = pcall(vim.system, { "pgrep", "-P", tostring(pid) }, { text = true })
  if ok and result then
    local out = result:wait()
    if out.code == 0 and out.stdout then
      for line in out.stdout:gmatch("[^\n]+") do
        local cpid = tonumber(line)
        if cpid then table.insert(children, cpid) end
      end
    end
  end

  -- Kill children first, then parent
  for _, cpid in ipairs(children) do
    pcall(vim.uv.kill, cpid, 15)
  end
  pcall(vim.uv.kill, pid, 15)

  -- Brief wait, then SIGKILL stragglers
  vim.wait(500, function()
    if pid_alive(pid) then return false end
    for _, cpid in ipairs(children) do
      if pid_alive(cpid) then return false end
    end
    return true
  end)

  for _, cpid in ipairs(children) do
    if pid_alive(cpid) then pcall(vim.uv.kill, cpid, 9) end
  end
  if pid_alive(pid) then pcall(vim.uv.kill, pid, 9) end
end

--- Check whether a process CWD belongs to a given repo root.
--- Matches the root itself and any subdirectory (e.g. worktrees).
--- @param cwd string  Resolved process CWD.
--- @param repo_root string  Resolved repo working tree root.
--- @return boolean
local function cwd_belongs_to_repo(cwd, repo_root)
  if cwd == repo_root then return true end
  -- Subdirectory check: cwd must start with repo_root followed by "/"
  -- to avoid matching "/foo/bar-baz" against "/foo/bar".
  return cwd:sub(1, #repo_root + 1) == repo_root .. "/"
end

--- Find and kill orphaned `opencode serve` processes for a given repo.
--- Scans the process table for `opencode serve` processes whose cwd
--- matches the git working tree or any of its worktree subdirectories.
--- Returns the number of processes killed.
--- @param git_common_dir string
--- @return number killed
local function cleanup_orphans(git_common_dir)
  -- Resolve the working tree directory from the git common dir.
  -- For a normal repo, git_common_dir is <worktree>/.git, so the
  -- working tree is its parent. For bare repos / worktrees it may differ.
  local work_dir = git_common_dir:gsub("/%.git$", "")
  local real_work_dir = vim.uv.fs_realpath(work_dir) or work_dir

  -- Find all opencode serve PIDs
  local ok, result = pcall(vim.system, { "pgrep", "-f", "opencode serve" }, { text = true })
  if not ok or not result then return 0 end
  local out = result:wait()
  if out.code ~= 0 or not out.stdout then return 0 end

  local killed = 0
  for line in out.stdout:gmatch("[^\n]+") do
    local pid = tonumber(line)
    if pid then
      -- Check if this process's cwd belongs to our repo
      local lsof_ok, lsof_result = pcall(vim.system,
        { "lsof", "-p", tostring(pid), "-Fn" }, { text = true })
      if lsof_ok and lsof_result then
        local lsof_out = lsof_result:wait()
        if lsof_out.code == 0 and lsof_out.stdout then
          -- lsof -Fn output has lines like "ncwd" followed by "n/path/to/dir"
          local cwd = lsof_out.stdout:match("n(/[^\n]*)")
          if cwd then
            local real_cwd = vim.uv.fs_realpath(cwd) or cwd
            if cwd_belongs_to_repo(real_cwd, real_work_dir) then
              kill_process_tree(pid)
              killed = killed + 1
            end
          end
        end
      end
    end
  end
  return killed
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
      -- Kill the orphan process tree so children don't run untracked
      if job and job.pid then
        kill_process_tree(job.pid)
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
--- Kills the tracked PID's process tree and clears state.
--- @param git_common_dir string
--- @return boolean stopped  True if a process was killed.
local function stop(git_common_dir)
  local dir = state_dir(git_common_dir)
  local info = load_server_info(dir)
  if not info or not info.pid or info.pid <= 0 then
    clear_server_info(dir)
    return false
  end

  kill_process_tree(info.pid)
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

  -- Clean up any orphaned opencode serve processes from previous runs
  -- before spawning a new one. This prevents unbounded accumulation.
  cleanup_orphans(git_common_dir)

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

--- Reconnect the opencode.nvim plugin to a (new) server port.
--- Creates a new OpencodeServer instance via from_custom() and sets it
--- in the plugin's reactive state store. This triggers the API client
--- and EventManager to re-subscribe to the new server automatically.
--- No-op when opencode.nvim is not loaded.
--- @param port number  The new server port.
function M.reconnect_plugin(port)
  local ok_srv, OpencodeServer = pcall(require, "opencode.opencode_server")
  if not ok_srv then return end
  local ok_state, state = pcall(require, "opencode.state")
  if not ok_state then return end

  -- Shut down the old server instance (cleans up SSE, port mapping).
  if state.opencode_server then
    local ok_sj, server_job = pcall(require, "opencode.server_job")
    if ok_sj and state.opencode_server.port then
      pcall(server_job.unregister_port_usage, state.opencode_server.port)
    end
    pcall(state.opencode_server.shutdown, state.opencode_server)
  end

  -- Create a new server instance pointing at the new port.
  local url = string.format("http://127.0.0.1:%d", port)
  local new_server = OpencodeServer.from_custom(url, port, "attach")
  state.jobs.set_server(new_server)

  -- Update config so future ensure_server() calls use the right port.
  local ok_cfg, cfg = pcall(require, "opencode.config")
  if ok_cfg then
    cfg.server = { url = "http://127.0.0.1", port = port, auto_kill = false }
  end
end

--- Disconnect the opencode.nvim plugin from the server.
--- Shuts down the current server instance and clears state.
--- No-op when opencode.nvim is not loaded.
function M.disconnect_plugin()
  local ok_state, state = pcall(require, "opencode.state")
  if not ok_state then return end

  if state.opencode_server then
    local ok_sj, server_job = pcall(require, "opencode.server_job")
    if ok_sj and state.opencode_server.port then
      pcall(server_job.unregister_port_usage, state.opencode_server.port)
    end
    pcall(state.opencode_server.shutdown, state.opencode_server)
  end

  state.jobs.clear_server()
end

M._internal = {
  state_dir = state_dir,
  port_file = port_file,
  pid_file = pid_file,
  pid_alive = pid_alive,
  kill_process_tree = kill_process_tree,
  cwd_belongs_to_repo = cwd_belongs_to_repo,
  cleanup_orphans = cleanup_orphans,
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
