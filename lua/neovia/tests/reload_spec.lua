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
