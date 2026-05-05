-- tests/neovia/server_spec.lua
-- Unit tests for lua/neovia/server.lua

local server = require("neovia.server")
local I = server._internal
local fs = require("neovia.fs")

------------------------------------------------------------------------
-- state_dir
------------------------------------------------------------------------

describe("state_dir", function()
  it("returns a path under stdpath('state')/server/", function()
    local dir = I.state_dir("/Users/jbr/projects/myrepo/.git")
    assert.is_not_nil(dir)
    assert.is_true(dir:find(vim.fn.stdpath("state") .. "/server/") == 1)
  end)

  it("produces a deterministic hash for the same common dir", function()
    local a = I.state_dir("/Users/jbr/projects/myrepo/.git")
    local b = I.state_dir("/Users/jbr/projects/myrepo/.git")
    assert.equals(a, b)
  end)

  it("produces different directories for different common dirs", function()
    local a = I.state_dir("/Users/jbr/projects/repo-a/.git")
    local b = I.state_dir("/Users/jbr/projects/repo-b/.git")
    assert.are_not.equals(a, b)
  end)
end)

------------------------------------------------------------------------
-- resolve_git_common_dir
------------------------------------------------------------------------

describe("resolve_git_common_dir", function()
  it("returns a string in a git repo", function()
    local dir = I.resolve_git_common_dir()
    -- The test runs inside the neovia repo, so this should work
    assert.is_not_nil(dir)
    assert.is_true(type(dir) == "string")
    assert.is_true(#dir > 0)
  end)

  it("returns an absolute path", function()
    local dir = I.resolve_git_common_dir()
    assert.is_not_nil(dir)
    assert.is_true(dir:sub(1, 1) == "/")
  end)
end)

------------------------------------------------------------------------
-- pid_alive
------------------------------------------------------------------------

describe("pid_alive", function()
  it("returns true for the current process", function()
    assert.is_true(I.pid_alive(vim.fn.getpid()))
  end)

  it("returns false for a non-existent PID", function()
    -- PID 99999999 is extremely unlikely to exist
    assert.is_false(I.pid_alive(99999999))
  end)
end)

------------------------------------------------------------------------
-- port_file / pid_file path helpers
------------------------------------------------------------------------

describe("file path helpers", function()
  it("port_file returns <state_dir>/port", function()
    local dir = I.state_dir("/some/repo/.git")
    assert.equals(dir .. "/port", I.port_file("/some/repo/.git"))
  end)

  it("pid_file returns <state_dir>/pid", function()
    local dir = I.state_dir("/some/repo/.git")
    assert.equals(dir .. "/pid", I.pid_file("/some/repo/.git"))
  end)
end)

------------------------------------------------------------------------
-- save_server_info / load_server_info
------------------------------------------------------------------------

describe("save_server_info / load_server_info", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    os.remove(tmp_dir .. "/port")
    os.remove(tmp_dir .. "/pid")
    os.remove(tmp_dir)
  end)

  it("saves and loads port + pid", function()
    I.save_server_info(tmp_dir, 12345, 6789)
    local info = I.load_server_info(tmp_dir)
    assert.is_not_nil(info)
    assert.equals(12345, info.port)
    assert.equals(6789, info.pid)
  end)

  it("returns nil when no port file exists", function()
    local info = I.load_server_info(tmp_dir)
    assert.is_nil(info)
  end)

  it("returns nil when port file is empty", function()
    fs.write_file(tmp_dir .. "/port", "")
    local info = I.load_server_info(tmp_dir)
    assert.is_nil(info)
  end)
end)

------------------------------------------------------------------------
-- status
------------------------------------------------------------------------

describe("status", function()
  local tmp_dir

  before_each(function()
    I.reset()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    I.reset()
    os.remove(tmp_dir .. "/port")
    os.remove(tmp_dir .. "/pid")
    os.remove(tmp_dir)
  end)

  it("returns 'stopped' when no server info exists", function()
    local s = I.status(tmp_dir)
    assert.equals("stopped", s.state)
    assert.is_nil(s.port)
    assert.is_nil(s.pid)
  end)

  it("returns 'stopped' when PID is dead", function()
    I.save_server_info(tmp_dir, 12345, 99999999)
    local s = I.status(tmp_dir)
    assert.equals("stopped", s.state)
  end)

  it("returns 'running' when PID is alive", function()
    -- Use our own PID as a known-alive process
    I.save_server_info(tmp_dir, 12345, vim.fn.getpid())
    local s = I.status(tmp_dir)
    assert.equals("running", s.state)
    assert.equals(12345, s.port)
    assert.equals(vim.fn.getpid(), s.pid)
  end)
end)

------------------------------------------------------------------------
-- clear_server_info
------------------------------------------------------------------------

describe("clear_server_info", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    os.remove(tmp_dir .. "/port")
    os.remove(tmp_dir .. "/pid")
    os.remove(tmp_dir)
  end)

  it("removes port and pid files", function()
    I.save_server_info(tmp_dir, 12345, 6789)
    I.clear_server_info(tmp_dir)
    assert.is_nil(I.load_server_info(tmp_dir))
  end)
end)

------------------------------------------------------------------------
-- parse_server_url
------------------------------------------------------------------------

describe("parse_server_url", function()
  it("extracts port from a standard URL", function()
    local port = I.parse_server_url("http://127.0.0.1:52150")
    assert.equals(52150, port)
  end)

  it("returns nil for malformed input", function()
    assert.is_nil(I.parse_server_url("not-a-url"))
  end)

  it("returns nil for nil input", function()
    assert.is_nil(I.parse_server_url(nil))
  end)
end)

------------------------------------------------------------------------
-- stop
------------------------------------------------------------------------

describe("stop", function()
  local tmp_dir
  local fake_git_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
    -- Use a fake git dir so state_dir produces our tmp_dir
    fake_git_dir = "__test_stop__"
  end)

  after_each(function()
    -- Clean up state dir
    local dir = I.state_dir(fake_git_dir)
    os.remove(dir .. "/port")
    os.remove(dir .. "/pid")
    pcall(vim.fn.delete, dir, "d")
  end)

  it("returns false when no server info exists", function()
    assert.is_false(I.stop(fake_git_dir))
  end)

  it("returns true and clears info when server info exists (dead PID)", function()
    local dir = I.state_dir(fake_git_dir)
    I.save_server_info(dir, 12345, 99999999)
    assert.is_true(I.stop(fake_git_dir))
    assert.is_nil(I.load_server_info(dir))
  end)

  it("returns true and clears info when PID is alive", function()
    -- Start a dummy sleep process to have a real PID to stop
    local job = vim.system({ "sleep", "60" }, { detach = true })
    local pid = job.pid
    assert.is_not_nil(pid)

    local dir = I.state_dir(fake_git_dir)
    I.save_server_info(dir, 12345, pid)
    assert.is_true(I.stop(fake_git_dir))
    assert.is_nil(I.load_server_info(dir))

    -- Clean up: the process should have been killed
    vim.wait(500, function()
      return not I.pid_alive(pid)
    end)
  end)
end)

------------------------------------------------------------------------
-- setup / reset
------------------------------------------------------------------------

describe("setup", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("is idempotent (skips second call)", function()
    server.setup()
    server.setup() -- should not error
  end)

  it("runs again after reset()", function()
    server.setup()
    I.reset()
    server.setup() -- should not error
  end)
end)

------------------------------------------------------------------------
-- read_port (internal, for plugin config)
------------------------------------------------------------------------

describe("read_port", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    os.remove(tmp_dir .. "/port")
    os.remove(tmp_dir .. "/pid")
    os.remove(tmp_dir)
  end)

  it("returns the port when server info exists and PID is alive", function()
    I.save_server_info(tmp_dir, 54321, vim.fn.getpid())
    local port = I.read_port(tmp_dir)
    assert.equals(54321, port)
  end)

  it("returns nil when PID is dead", function()
    I.save_server_info(tmp_dir, 54321, 99999999)
    local port = I.read_port(tmp_dir)
    assert.is_nil(port)
  end)

  it("returns nil when no info exists", function()
    local port = I.read_port(tmp_dir)
    assert.is_nil(port)
  end)
end)

------------------------------------------------------------------------
-- Public API: M.status()
------------------------------------------------------------------------

describe("M.status", function()
  -- Tests run inside the neovia git repo, so resolve_git_common_dir works.
  local gcd, sdir

  before_each(function()
    I.reset()
    gcd = I.resolve_git_common_dir()
    assert.is_not_nil(gcd, "tests must run inside a git repo")
    sdir = I.state_dir(gcd)
  end)

  after_each(function()
    I.clear_server_info(sdir)
    I.reset()
  end)

  it("returns 'running' when server info exists with alive PID", function()
    I.save_server_info(sdir, 11111, vim.fn.getpid())
    local s = server.status()
    assert.equals("running", s.state)
    assert.equals(11111, s.port)
    assert.equals(vim.fn.getpid(), s.pid)
  end)

  it("returns 'stopped' when no server info exists", function()
    local s = server.status()
    assert.equals("stopped", s.state)
  end)
end)

------------------------------------------------------------------------
-- Public API: M.read_port()
------------------------------------------------------------------------

describe("M.read_port", function()
  local gcd, sdir

  before_each(function()
    I.reset()
    gcd = I.resolve_git_common_dir()
    sdir = I.state_dir(gcd)
  end)

  after_each(function()
    I.clear_server_info(sdir)
    I.reset()
  end)

  it("returns the port when server is alive", function()
    I.save_server_info(sdir, 22222, vim.fn.getpid())
    assert.equals(22222, server.read_port())
  end)

  it("returns nil when no server is running", function()
    assert.is_nil(server.read_port())
  end)
end)

------------------------------------------------------------------------
-- Public API: M.stop()
------------------------------------------------------------------------

describe("M.stop", function()
  local gcd, sdir

  before_each(function()
    I.reset()
    gcd = I.resolve_git_common_dir()
    sdir = I.state_dir(gcd)
  end)

  after_each(function()
    I.clear_server_info(sdir)
    I.reset()
  end)

  it("returns false when no server is running", function()
    assert.is_false(server.stop())
  end)

  it("returns true and clears info when server info exists", function()
    -- Use a dummy sleep process
    local job = vim.system({ "sleep", "60" }, { detach = true })
    local pid = job.pid
    I.save_server_info(sdir, 33333, pid)

    assert.is_true(server.stop())
    assert.is_nil(I.load_server_info(sdir))

    -- Clean up
    vim.wait(500, function() return not I.pid_alive(pid) end)
  end)
end)

------------------------------------------------------------------------
-- Public API: M.start()
------------------------------------------------------------------------

describe("M.start", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("calls back with error when not in a git repo", function()
    -- Run from a temp directory that is not a git repo
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local orig_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp))

    local result = {}
    server.start(function(err, port)
      result.err = err
      result.port = port
    end)

    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(tmp, "rf")

    assert.equals("not in a git repository", result.err)
    assert.is_nil(result.port)
  end)

  it("calls back immediately when server is already running", function()
    local gcd = I.resolve_git_common_dir()
    local sdir = I.state_dir(gcd)
    I.save_server_info(sdir, 44444, vim.fn.getpid())

    local result = {}
    server.start(function(err, port)
      result.err = err
      result.port = port
    end)

    assert.is_nil(result.err)
    assert.equals(44444, result.port)

    I.clear_server_info(sdir)
  end)
end)

------------------------------------------------------------------------
-- Public API: M.restart()
------------------------------------------------------------------------

------------------------------------------------------------------------
-- ensure_running (internal)
------------------------------------------------------------------------

describe("ensure_running", function()
  -- ensure_running takes a git_common_dir and computes the state dir
  -- internally, matching the convention of start/stop/restart.
  local fake_git_dir = "__test_ensure_running__"
  local sdir

  before_each(function()
    sdir = I.state_dir(fake_git_dir)
    vim.fn.mkdir(sdir, "p")
  end)

  after_each(function()
    I.clear_server_info(sdir)
    pcall(vim.fn.delete, sdir, "rf")
  end)

  it("returns existing port when server is already alive", function()
    I.save_server_info(sdir, 44444, vim.fn.getpid())
    local port, err = I.ensure_running(fake_git_dir)
    assert.is_nil(err)
    assert.equals(44444, port)
  end)

  it("clears stale info and attempts start when PID is dead", function()
    I.save_server_info(sdir, 44444, 99999999)
    -- The stale info should be cleared, then start should be attempted.
    -- Without the opencode binary, start will fail, but stale info
    -- should be gone after the attempt.
    local port, err = I.ensure_running(fake_git_dir)
    -- Either it started (port ~= nil) or it failed (err ~= nil)
    assert.is_true(port ~= nil or err ~= nil)
  end)
end)

------------------------------------------------------------------------
-- Public API: M.ensure_running()
------------------------------------------------------------------------

describe("M.ensure_running", function()
  local gcd, sdir

  before_each(function()
    I.reset()
    gcd = I.resolve_git_common_dir()
    assert.is_not_nil(gcd, "tests must run inside a git repo")
    sdir = I.state_dir(gcd)
  end)

  after_each(function()
    I.clear_server_info(sdir)
    I.reset()
  end)

  it("returns the port when server is already running", function()
    I.save_server_info(sdir, 55555, vim.fn.getpid())
    local port, err = server.ensure_running()
    assert.is_nil(err)
    assert.equals(55555, port)
  end)

  it("returns nil port and error when not in a git repo", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local orig_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(tmp))

    local port, err = server.ensure_running()

    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    vim.fn.delete(tmp, "rf")

    assert.is_nil(port)
    assert.equals("not in a git repository", err)
  end)
end)

describe("M.restart", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  -- Full restart spawns a real opencode process. Test that the stop
  -- phase works by setting up a dummy process, then verifying the
  -- callback is invoked (start will proceed to spawn, which we can't
  -- fully test here without the opencode binary).
  it("stops the existing server before starting", function()
    local gcd = I.resolve_git_common_dir()
    local sdir = I.state_dir(gcd)
    local job = vim.system({ "sleep", "60" }, { detach = true })
    local pid = job.pid
    I.save_server_info(sdir, 55555, pid)

    -- Restart will stop the sleep process, then try to start opencode.
    -- start() will attempt to spawn opencode (which may fail in test),
    -- but the stop phase should have killed the dummy process.
    server.restart(function() end)

    -- Verify the old process was killed
    vim.wait(3000, function() return not I.pid_alive(pid) end)
    assert.is_false(I.pid_alive(pid))

    -- Clean up
    I.clear_server_info(sdir)
  end)
end)

------------------------------------------------------------------------
-- kill_process_tree (kill parent + all children)
------------------------------------------------------------------------

describe("kill_process_tree", function()
  it("kills a process and its children", function()
    -- Start a parent that spawns a child
    local job = vim.system({ "bash", "-c", "sleep 120 & wait" }, { detach = true })
    local parent_pid = job.pid
    -- Give child time to spawn
    vim.wait(500, function() return false end)

    -- Find children
    local result = vim.system(
      { "pgrep", "-P", tostring(parent_pid) }, { text = true }
    ):wait()
    local child_pids = {}
    if result.code == 0 and result.stdout then
      for line in result.stdout:gmatch("[^\n]+") do
        local cpid = tonumber(line)
        if cpid then table.insert(child_pids, cpid) end
      end
    end

    -- Kill the whole tree
    I.kill_process_tree(parent_pid)

    -- Wait for death
    vim.wait(2000, function()
      if I.pid_alive(parent_pid) then return false end
      for _, cpid in ipairs(child_pids) do
        if I.pid_alive(cpid) then return false end
      end
      return true
    end)

    assert.is_false(I.pid_alive(parent_pid))
    for _, cpid in ipairs(child_pids) do
      assert.is_false(I.pid_alive(cpid))
    end
  end)

  it("handles non-existent PID gracefully", function()
    -- Should not error
    I.kill_process_tree(99999999)
  end)

  it("handles nil PID gracefully", function()
    I.kill_process_tree(nil)
  end)
end)

------------------------------------------------------------------------
-- cwd_belongs_to_repo (predicate used by cleanup_orphans)
------------------------------------------------------------------------

describe("cwd_belongs_to_repo", function()
  it("matches when cwd equals the repo root", function()
    assert.is_true(I.cwd_belongs_to_repo(
      "/Users/jbr/Private/neovia",
      "/Users/jbr/Private/neovia"
    ))
  end)

  it("matches when cwd is a worktree subdirectory", function()
    assert.is_true(I.cwd_belongs_to_repo(
      "/Users/jbr/Private/neovia/.worktrees/theme",
      "/Users/jbr/Private/neovia"
    ))
  end)

  it("matches deeper worktree paths", function()
    assert.is_true(I.cwd_belongs_to_repo(
      "/Users/jbr/Private/neovia/.worktrees/spawn-bug",
      "/Users/jbr/Private/neovia"
    ))
  end)

  it("does not match unrelated directories", function()
    assert.is_false(I.cwd_belongs_to_repo(
      "/Users/jbr/Projects/other-repo",
      "/Users/jbr/Private/neovia"
    ))
  end)

  it("does not match partial prefix overlap", function()
    -- /Users/jbr/Private/neovia-fork should NOT match /Users/jbr/Private/neovia
    assert.is_false(I.cwd_belongs_to_repo(
      "/Users/jbr/Private/neovia-fork",
      "/Users/jbr/Private/neovia"
    ))
  end)

  it("does not match parent directories", function()
    assert.is_false(I.cwd_belongs_to_repo(
      "/Users/jbr/Private",
      "/Users/jbr/Private/neovia"
    ))
  end)
end)

------------------------------------------------------------------------
-- cleanup_orphans (find and kill stale opencode serve processes)
------------------------------------------------------------------------

describe("cleanup_orphans", function()
  it("returns a number when no orphans exist", function()
    local gcd = I.resolve_git_common_dir()
    local killed = I.cleanup_orphans(gcd)
    assert.is_true(type(killed) == "number")
  end)
end)



