-- tests/neovia/theme_spec.lua
-- Unit tests for lua/neovia/theme.lua

local theme = require("neovia.theme")
local I = theme._internal

-- Use a temp file for each test to avoid cross-contamination.
local tmp_path

local function fresh_tmp()
  tmp_path = vim.fn.tempname()
  return tmp_path
end

local function cleanup()
  if tmp_path then pcall(os.remove, tmp_path) end
  I.reset()
end

------------------------------------------------------------------------
-- state_path
------------------------------------------------------------------------

describe("state_path", function()
  after_each(cleanup)

  it("returns the default path under stdpath('state')", function()
    I.reset()
    theme.setup()
    local p = I.state_path()
    local expected = vim.fn.stdpath("state") .. "/theme.lua"
    assert.are.equal(expected, p)
  end)

  it("uses a custom path when configured", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    assert.are.equal(p, I.state_path())
  end)
end)

------------------------------------------------------------------------
-- flavours list
------------------------------------------------------------------------

describe("flavours", function()
  it("exposes all four catppuccin flavours", function()
    assert.are.same({ "latte", "frappe", "macchiato", "mocha" }, theme.flavours)
  end)

  it("latte is the only light flavour", function()
    -- latte maps to background=light, the rest to dark
    assert.are.equal("light", I.flavour_background("latte"))
    assert.are.equal("dark", I.flavour_background("frappe"))
    assert.are.equal("dark", I.flavour_background("macchiato"))
    assert.are.equal("dark", I.flavour_background("mocha"))
  end)
end)

------------------------------------------------------------------------
-- save / load (now persists flavour)
------------------------------------------------------------------------

describe("save", function()
  after_each(cleanup)

  it("writes the current flavour to the state file", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("frappe")
    I.save()
    local content = vim.fn.readfile(p)
    assert.is_true(#content > 0)
  end)

  it("saved file is valid Lua that returns a table with flavour key", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("macchiato")
    I.save()
    local tbl = dofile(p)
    assert.are.equal("macchiato", tbl.flavour)
  end)
end)

describe("load", function()
  after_each(cleanup)

  it("returns nil when state file does not exist", function()
    local p = fresh_tmp()
    os.remove(p) -- ensure it doesn't exist
    I.reset()
    theme.setup({ state_path = p })
    assert.is_nil(I.load())
  end)

  it("returns the saved flavour value", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("mocha")
    I.save()
    local result = I.load()
    assert.are.equal("mocha", result.flavour)
  end)

  it("returns nil for a corrupt state file", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.fn.writefile({ "not valid lua {{{{" }, p)
    assert.is_nil(I.load())
  end)

  it("migrates legacy state files with background key", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.fn.writefile({ 'return { background = "light" }' }, p)
    local result = I.load()
    assert.are.equal("latte", result.flavour)
  end)

  it("migrates legacy dark background to mocha", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.fn.writefile({ 'return { background = "dark" }' }, p)
    local result = I.load()
    assert.are.equal("mocha", result.flavour)
  end)
end)

------------------------------------------------------------------------
-- set_flavour
------------------------------------------------------------------------

describe("set_flavour", function()
  after_each(cleanup)

  it("sets background to light for latte", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("latte")
    assert.are.equal("light", vim.o.background)
  end)

  it("sets background to dark for mocha", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("mocha")
    assert.are.equal("dark", vim.o.background)
  end)

  it("sets background to dark for frappe", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("frappe")
    assert.are.equal("dark", vim.o.background)
  end)

  it("sets background to dark for macchiato", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("macchiato")
    assert.are.equal("dark", vim.o.background)
  end)

  it("persists the chosen flavour to disk", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("frappe")
    local result = I.load()
    assert.are.equal("frappe", result.flavour)
  end)

  it("updates current_flavour()", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("macchiato")
    assert.are.equal("macchiato", theme.current_flavour())
  end)

  it("ignores unknown flavour names", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("mocha")
    theme.set_flavour("nonexistent")
    -- Should remain mocha
    assert.are.equal("mocha", theme.current_flavour())
  end)
end)

------------------------------------------------------------------------
-- current_flavour
------------------------------------------------------------------------

describe("current_flavour", function()
  after_each(cleanup)

  it("defaults to mocha before any set_flavour call", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    assert.are.equal("mocha", theme.current_flavour())
  end)

  it("reflects the last set_flavour call", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("latte")
    assert.are.equal("latte", theme.current_flavour())
    theme.set_flavour("frappe")
    assert.are.equal("frappe", theme.current_flavour())
  end)
end)

------------------------------------------------------------------------
-- apply
------------------------------------------------------------------------

describe("apply", function()
  after_each(cleanup)

  it("sets background from saved flavour", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("latte")
    I.save()
    vim.o.background = "dark" -- change it
    theme.apply()
    assert.are.equal("light", vim.o.background)
  end)

  it("restores flavour from disk", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("frappe")
    I.save()
    I.set_current_flavour("mocha") -- change it
    theme.apply()
    assert.are.equal("frappe", theme.current_flavour())
  end)

  it("is a no-op when no state file exists", function()
    local p = fresh_tmp()
    os.remove(p)
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "dark"
    theme.apply()
    assert.are.equal("dark", vim.o.background)
    assert.are.equal("mocha", theme.current_flavour())
  end)
end)

------------------------------------------------------------------------
-- toggle (cycles through flavours)
------------------------------------------------------------------------

describe("toggle", function()
  after_each(cleanup)

  it("cycles from mocha to latte", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("mocha")
    theme.toggle()
    assert.are.equal("latte", theme.current_flavour())
  end)

  it("cycles from latte to frappe", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("latte")
    theme.toggle()
    assert.are.equal("frappe", theme.current_flavour())
  end)

  it("cycles through all four flavours", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("latte")
    theme.toggle() -- -> frappe
    theme.toggle() -- -> macchiato
    theme.toggle() -- -> mocha
    theme.toggle() -- -> latte (wraps)
    assert.are.equal("latte", theme.current_flavour())
  end)

  it("persists after toggle", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    I.set_current_flavour("mocha")
    theme.toggle()
    local result = I.load()
    assert.are.equal("latte", result.flavour)
  end)
end)

------------------------------------------------------------------------
-- setup / reset
------------------------------------------------------------------------

describe("setup", function()
  after_each(cleanup)

  it("is idempotent (second call is a no-op)", function()
    local p1 = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p1 })
    local p2 = vim.fn.tempname()
    theme.setup({ state_path = p2 })
    -- Should still use p1 since second call was skipped
    assert.are.equal(p1, I.state_path())
    pcall(os.remove, p2)
  end)
end)

describe("reset", function()
  after_each(cleanup)

  it("allows setup to run again after reset", function()
    local p1 = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p1 })
    assert.are.equal(p1, I.state_path())
    I.reset()
    local p2 = vim.fn.tempname()
    theme.setup({ state_path = p2 })
    assert.are.equal(p2, I.state_path())
    pcall(os.remove, p2)
  end)

  it("resets current flavour to default", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    theme.set_flavour("latte")
    I.reset()
    theme.setup({ state_path = p })
    assert.are.equal("mocha", theme.current_flavour())
  end)
end)
