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
-- save / load
------------------------------------------------------------------------

describe("save", function()
  after_each(cleanup)

  it("writes the current background to the state file", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "light"
    I.save()
    local content = vim.fn.readfile(p)
    assert.is_true(#content > 0)
  end)

  it("saved file is valid Lua that returns a table with background key", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "light"
    I.save()
    local tbl = dofile(p)
    assert.are.equal("light", tbl.background)
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

  it("returns the saved background value", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "dark"
    I.save()
    local result = I.load()
    assert.are.equal("dark", result.background)
  end)

  it("returns nil for a corrupt state file", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.fn.writefile({ "not valid lua {{{{" }, p)
    assert.is_nil(I.load())
  end)
end)

------------------------------------------------------------------------
-- toggle
------------------------------------------------------------------------

describe("toggle", function()
  after_each(cleanup)

  it("switches from dark to light", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "dark"
    theme.toggle()
    assert.are.equal("light", vim.o.background)
  end)

  it("switches from light to dark", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "light"
    theme.toggle()
    assert.are.equal("dark", vim.o.background)
  end)

  it("persists the new value to disk", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "dark"
    theme.toggle()
    local result = I.load()
    assert.are.equal("light", result.background)
  end)
end)

------------------------------------------------------------------------
-- apply
------------------------------------------------------------------------

describe("apply", function()
  after_each(cleanup)

  it("sets background from saved state", function()
    local p = fresh_tmp()
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "light"
    I.save()
    vim.o.background = "dark" -- change it
    theme.apply()
    assert.are.equal("light", vim.o.background)
  end)

  it("is a no-op when no state file exists", function()
    local p = fresh_tmp()
    os.remove(p)
    I.reset()
    theme.setup({ state_path = p })
    vim.o.background = "dark"
    theme.apply()
    assert.are.equal("dark", vim.o.background)
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
end)

-- NOTE: define_worktree_highlights, status_colors, hl_bg, hl_fg tests
-- moved to tabline_spec.lua (these are now in neovia.tabline).
