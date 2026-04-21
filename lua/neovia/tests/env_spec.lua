-- tests/neovia/env_spec.lua
-- Unit tests for lua/neovia/env.lua

local env = require("neovia.env")
local I = env._internal

------------------------------------------------------------------------
-- setup (direct tests)
------------------------------------------------------------------------

describe("setup", function()
  before_each(function()
    I.reset()
    vim.env.TEST_SETUP_A = nil
    vim.env.TEST_SETUP_B = nil
  end)

  after_each(function()
    I.reset()
    vim.env.TEST_SETUP_A = nil
    vim.env.TEST_SETUP_B = nil
  end)

  it("sets multiple env vars from specs", function()
    env.setup({
      { name = "TEST_SETUP_A", value = "alpha" },
      { name = "TEST_SETUP_B", value = "beta" },
    })

    assert.equals("alpha", vim.env.TEST_SETUP_A)
    assert.equals("beta", vim.env.TEST_SETUP_B)
  end)

  it("calls vim.notify on failure", function()
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end

    env.setup({
      { name = "TEST_SETUP_A", exec = { "false" } },
    })

    vim.notify = orig_notify

    assert.equals(1, #notified)
    assert.equals(vim.log.levels.WARN, notified[1].level)
    assert.is_true(notified[1].msg:find("TEST_SETUP_A") ~= nil)
  end)

  it("is idempotent (skips second call)", function()
    env.setup({
      { name = "TEST_SETUP_A", value = "first" },
    })

    -- Second call with different value should be skipped
    env.setup({
      { name = "TEST_SETUP_A", value = "second" },
    })

    assert.equals("first", vim.env.TEST_SETUP_A)
  end)

  it("runs again after reset()", function()
    env.setup({
      { name = "TEST_SETUP_A", value = "first" },
    })
    I.reset()

    env.setup({
      { name = "TEST_SETUP_A", value = "second" },
    })

    assert.equals("second", vim.env.TEST_SETUP_A)
  end)
end)

------------------------------------------------------------------------
-- reset
------------------------------------------------------------------------

describe("reset", function()
  it("clears the initialised flag", function()
    env.setup({ { name = "TEST_SETUP_A", value = "x" } })
    I.reset()

    -- Should be able to run setup again
    env.setup({ { name = "TEST_SETUP_A", value = "y" } })
    assert.equals("y", vim.env.TEST_SETUP_A)

    -- Cleanup
    I.reset()
    vim.env.TEST_SETUP_A = nil
  end)
end)

------------------------------------------------------------------------
-- cache_fresh
------------------------------------------------------------------------

describe("cache_fresh", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
  end)

  after_each(function()
    os.remove(tmp)
  end)

  it("returns false for a non-existent file", function()
    assert.is_false(I.cache_fresh("/no/such/file", 3600))
  end)

  it("returns true for a freshly written file", function()
    local fd = vim.uv.fs_open(tmp, "w", 384)
    vim.uv.fs_write(fd, "test", 0)
    vim.uv.fs_close(fd)

    assert.is_true(I.cache_fresh(tmp, 3600))
  end)

  it("returns false when ttl is zero", function()
    local fd = vim.uv.fs_open(tmp, "w", 384)
    vim.uv.fs_write(fd, "test", 0)
    vim.uv.fs_close(fd)

    assert.is_false(I.cache_fresh(tmp, 0))
  end)
end)

------------------------------------------------------------------------
-- load_var with plain value
------------------------------------------------------------------------

describe("load_var with value", function()
  after_each(function()
    vim.env.TEST_ENV_VAR = nil
  end)

  it("sets the env var directly", function()
    local ok, err = I.load_var({ name = "TEST_ENV_VAR", value = "hello" })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("hello", vim.env.TEST_ENV_VAR)
  end)

  it("sets an empty string value (vim.env treats as unset)", function()
    local ok = I.load_var({ name = "TEST_ENV_VAR", value = "" })

    assert.is_true(ok)
    -- Neovim's vim.env unsets variables assigned empty string
    assert.is_nil(vim.env.TEST_ENV_VAR)
  end)
end)

------------------------------------------------------------------------
-- load_var with exec (table form)
------------------------------------------------------------------------

describe("load_var with exec table", function()
  after_each(function()
    vim.env.TEST_ENV_VAR = nil
  end)

  it("sets env var from command stdout", function()
    local ok, err = I.load_var({
      name = "TEST_ENV_VAR",
      exec = { "printf", "secret-value" },
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("secret-value", vim.env.TEST_ENV_VAR)
  end)

  it("trims trailing whitespace from stdout", function()
    local ok = I.load_var({
      name = "TEST_ENV_VAR",
      exec = { "printf", "value\n\n" },
    })

    assert.is_true(ok)
    assert.equals("value", vim.env.TEST_ENV_VAR)
  end)

  it("reports an error when command fails", function()
    local ok, err = I.load_var({
      name = "TEST_ENV_VAR",
      exec = { "false" },
    })

    assert.is_false(ok)
    assert.is_not_nil(err)
    assert.is_nil(vim.env.TEST_ENV_VAR)
  end)
end)

------------------------------------------------------------------------
-- load_var with exec (string form, run via shell)
------------------------------------------------------------------------

describe("load_var with exec string", function()
  after_each(function()
    vim.env.TEST_ENV_VAR = nil
  end)

  it("runs command through the shell", function()
    local ok, err = I.load_var({
      name = "TEST_ENV_VAR",
      exec = "printf '%s' shell-value",
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("shell-value", vim.env.TEST_ENV_VAR)
  end)

  it("reports an error when shell command fails", function()
    local ok, err = I.load_var({
      name = "TEST_ENV_VAR",
      exec = "exit 1",
    })

    assert.is_false(ok)
    assert.is_not_nil(err)
    assert.is_nil(vim.env.TEST_ENV_VAR)
  end)
end)

------------------------------------------------------------------------
-- load_var with exec + cache (opt-in)
------------------------------------------------------------------------

describe("load_var with exec + cache", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.env.TEST_ENV_VAR = nil
  end)

  after_each(function()
    os.remove(tmp)
    vim.env.TEST_ENV_VAR = nil
  end)

  it("loads from a fresh cache file instead of running exec", function()
    -- Write a cache file
    local fd = vim.uv.fs_open(tmp, "w", 384)
    vim.uv.fs_write(fd, "cached-value", 0)
    vim.uv.fs_close(fd)

    -- exec would fail, but cache should be used instead
    local ok, err = I.load_var({
      name = "TEST_ENV_VAR",
      exec = { "false" },
      cache = tmp,
      ttl = 3600,
    })

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("cached-value", vim.env.TEST_ENV_VAR)
  end)

  it("ignores cache when ttl is not set", function()
    -- Write a cache file but omit ttl
    local fd = vim.uv.fs_open(tmp, "w", 384)
    vim.uv.fs_write(fd, "cached-value", 0)
    vim.uv.fs_close(fd)

    local ok, err = I.load_var({
      name = "TEST_ENV_VAR",
      exec = { "false" },
      cache = tmp,
    })

    -- Falls through to exec which fails
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)

  it("falls back to exec when cache file is missing", function()
    local ok = I.load_var({
      name = "TEST_ENV_VAR",
      exec = { "printf", "fresh-value" },
      cache = tmp,
      ttl = 3600,
    })

    assert.is_true(ok)
    assert.equals("fresh-value", vim.env.TEST_ENV_VAR)

    -- Verify it wrote the cache file
    local fd = vim.uv.fs_open(tmp, "r", 438)
    assert.is_not_nil(fd)
    local stat = vim.uv.fs_fstat(fd)
    local data = vim.uv.fs_read(fd, stat.size, 0)
    vim.uv.fs_close(fd)
    assert.equals("fresh-value", data)
  end)
end)
