-- tests/neovia/reload_spec.lua
-- Unit tests for lua/neovia/reload.lua

local reload = require("neovia.reload")
local I = reload._internal

------------------------------------------------------------------------
-- find_module_keys
------------------------------------------------------------------------

describe("find_module_keys", function()
  it("finds neovia.* keys in a package.loaded table", function()
    local loaded = {
      ["neovia.mode"] = {},
      ["neovia.env"] = {},
      ["neovia.worktree"] = {},
      ["neovia.navigate"] = {},
      ["neovia.reload"] = {},
      ["lazy.core"] = {},
      ["opencode.api"] = {},
    }
    local keys = I.find_module_keys(loaded)
    table.sort(keys)
    assert.same({
      "neovia.env",
      "neovia.mode",
      "neovia.navigate",
      "neovia.reload",
      "neovia.worktree",
    }, keys)
  end)

  it("returns empty table when no neovia modules are loaded", function()
    local loaded = {
      ["lazy.core"] = {},
      ["opencode.api"] = {},
    }
    local keys = I.find_module_keys(loaded)
    assert.same({}, keys)
  end)

  it("excludes neovia.tests.* keys", function()
    local loaded = {
      ["neovia.mode"] = {},
      ["neovia.tests.mode_spec"] = {},
      ["neovia.tests.run"] = {},
    }
    local keys = I.find_module_keys(loaded)
    assert.same({ "neovia.mode" }, keys)
  end)
end)

------------------------------------------------------------------------
-- reset_modules
------------------------------------------------------------------------

describe("reset_modules", function()
  it("calls _internal.reset() on modules that have it", function()
    local reset_called = false
    local fake_module = {
      _internal = {
        reset = function() reset_called = true end,
      },
    }
    I.reset_module(fake_module)
    assert.is_true(reset_called)
  end)

  it("is a no-op for modules without _internal.reset", function()
    local fake_module = { setup = function() end }
    -- Should not error
    I.reset_module(fake_module)
  end)

  it("is a no-op for modules without _internal at all", function()
    local fake_module = {}
    -- Should not error
    I.reset_module(fake_module)
  end)
end)

------------------------------------------------------------------------
-- reload (integration)
------------------------------------------------------------------------

describe("reload", function()
  it("resets modules, clears package.loaded, and re-sources init.lua", function()
    -- Inject a fake module into package.loaded
    local reset_called = false
    package.loaded["neovia._test_fake"] = {
      _internal = {
        reset = function() reset_called = true end,
      },
    }

    -- Stub dofile and vim.notify to avoid side effects
    local orig_dofile = dofile
    local dofile_called = false
    local dofile_path = nil
    -- Replace global dofile temporarily
    rawset(_G, "dofile", function(path)
      dofile_called = true
      dofile_path = path
    end)

    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end

    reload.reload()

    -- Restore
    rawset(_G, "dofile", orig_dofile)
    vim.notify = orig_notify

    -- Assert: reset was called on the fake module
    assert.is_true(reset_called)

    -- Assert: fake module was cleared from package.loaded
    assert.is_nil(package.loaded["neovia._test_fake"])

    -- Assert: dofile was called with init.lua path
    assert.is_true(dofile_called)
    assert.is_true(dofile_path:match("init%.lua$") ~= nil)

    -- Assert: notification was sent
    assert.is_true(#notified > 0)
    assert.equals(vim.log.levels.INFO, notified[1].level)
  end)

  it("notifies on dofile failure", function()
    -- Stub dofile to fail
    local orig_dofile = dofile
    rawset(_G, "dofile", function()
      error("intentional test error")
    end)

    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end

    reload.reload()

    rawset(_G, "dofile", orig_dofile)
    vim.notify = orig_notify

    -- Should have notified with ERROR level
    assert.is_true(#notified > 0)
    assert.equals(vim.log.levels.ERROR, notified[1].level)
    assert.is_true(notified[1].msg:find("reload failed") ~= nil)
  end)
end)

------------------------------------------------------------------------
-- reset (reload contract)
------------------------------------------------------------------------

describe("reset", function()
  it("exists and is callable", function()
    assert.is_function(I.reset)
    I.reset()
  end)
end)
