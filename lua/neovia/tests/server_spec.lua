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
-- read_port (the function plugin config will call)
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
