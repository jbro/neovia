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

------------------------------------------------------------------------
-- hl_bg / hl_fg
------------------------------------------------------------------------

describe("hl_bg", function()
  it("returns bg color from a highlight group", function()
    vim.api.nvim_set_hl(0, "NeoviaTest_hl_bg", { bg = "#ff0000" })
    local result = I.hl_bg("NeoviaTest_hl_bg")
    assert.is_not_nil(result)
  end)

  it("returns nil for a non-existent highlight group", function()
    assert.is_nil(I.hl_bg("NeoviaTest_nonexistent_hl_bg"))
  end)
end)

describe("hl_fg", function()
  it("returns fg color from a highlight group", function()
    vim.api.nvim_set_hl(0, "NeoviaTest_hl_fg", { fg = "#00ff00" })
    local result = I.hl_fg("NeoviaTest_hl_fg")
    assert.is_not_nil(result)
  end)

  it("returns nil for a non-existent highlight group", function()
    assert.is_nil(I.hl_fg("NeoviaTest_nonexistent_hl_fg"))
  end)
end)

------------------------------------------------------------------------
-- define_worktree_highlights
------------------------------------------------------------------------

describe("define_worktree_highlights", function()
  before_each(function()
    -- Set up fake lualine highlight groups for the function to read.
    vim.api.nvim_set_hl(0, "lualine_a_normal", { bg = "#aaaaaa", fg = "#111111" })
    vim.api.nvim_set_hl(0, "lualine_b_normal", { bg = "#555555", fg = "#eeeeee" })
    vim.api.nvim_set_hl(0, "TabLineFill", { bg = "#222222" })
  end)

  after_each(function()
    -- Clean up test highlights.
    vim.api.nvim_set_hl(0, "lualine_a_normal", {})
    vim.api.nvim_set_hl(0, "lualine_b_normal", {})
    vim.api.nvim_set_hl(0, "TabLineFill", {})
  end)

  it("creates NeoviaWtSel from lualine_a_normal", function()
    I.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWtSel", link = false })
    assert.is_not_nil(hl.bg)
    assert.is_true(hl.bold or false)
  end)

  it("creates NeoviaWt from lualine_b_normal", function()
    I.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWt", link = false })
    assert.is_not_nil(hl.bg)
  end)

  it("creates transitional highlight NeoviaWtSel_to_wt", function()
    I.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWtSel_to_wt", link = false })
    assert.is_not_nil(hl.fg, "expected fg from lualine_a bg")
    assert.is_not_nil(hl.bg, "expected bg from lualine_b bg")
  end)

  it("creates transitional highlight NeoviaWtSel_to_fill", function()
    I.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWtSel_to_fill", link = false })
    assert.is_not_nil(hl.fg)
    assert.is_not_nil(hl.bg)
  end)

  it("creates transitional highlight NeoviaWt_to_fill", function()
    I.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWt_to_fill", link = false })
    assert.is_not_nil(hl.fg)
    assert.is_not_nil(hl.bg)
  end)

  it("creates status indicator highlights", function()
    I.define_worktree_highlights()
    local idle = vim.api.nvim_get_hl(0, { name = "NeoviaWt_idle", link = false })
    local responding = vim.api.nvim_get_hl(0, { name = "NeoviaWt_responding", link = false })
    local attn = vim.api.nvim_get_hl(0, { name = "NeoviaWt_needs_attention", link = false })
    local unknown = vim.api.nvim_get_hl(0, { name = "NeoviaWt_unknown", link = false })
    assert.is_not_nil(idle.fg)
    assert.is_not_nil(responding.fg)
    assert.is_not_nil(attn.fg)
    assert.is_not_nil(unknown.fg)
  end)
end)
