-- tests/neovia/navigate_spec.lua
-- Unit tests for lua/neovia/navigate.lua

local navigate = require("neovia.navigate")
local I = navigate._internal

------------------------------------------------------------------------
-- parse_path
------------------------------------------------------------------------

describe("parse_path", function()
  it("returns path and nil for a plain path", function()
    local path, line = I.parse_path("src/foo.lua")
    assert.equals("src/foo.lua", path)
    assert.is_nil(line)
  end)

  it("extracts line number from path:line", function()
    local path, line = I.parse_path("src/foo.lua:42")
    assert.equals("src/foo.lua", path)
    assert.equals(42, line)
  end)

  it("extracts line number from path:line:col", function()
    local path, line = I.parse_path("src/foo.lua:42:10")
    assert.equals("src/foo.lua", path)
    assert.equals(42, line)
  end)

  it("strips trailing backtick", function()
    local path, line = I.parse_path("`src/foo.lua`")
    assert.equals("src/foo.lua", path)
    assert.is_nil(line)
  end)

  it("strips surrounding quotes", function()
    local path, line = I.parse_path('"src/foo.lua"')
    assert.equals("src/foo.lua", path)
    assert.is_nil(line)
  end)

  it("strips trailing comma", function()
    local path, line = I.parse_path("src/foo.lua,")
    assert.equals("src/foo.lua", path)
    assert.is_nil(line)
  end)

  it("strips trailing parenthesis", function()
    local path, line = I.parse_path("(src/foo.lua)")
    assert.equals("src/foo.lua", path)
    assert.is_nil(line)
  end)

  it("handles backtick-wrapped path:line", function()
    local path, line = I.parse_path("`src/foo.lua:7`")
    assert.equals("src/foo.lua", path)
    assert.equals(7, line)
  end)

  it("handles path with spaces in surrounding punctuation", function()
    local path, line = I.parse_path("'some/path.lua:100'")
    assert.equals("some/path.lua", path)
    assert.equals(100, line)
  end)
end)

------------------------------------------------------------------------
-- is_opencode_win
------------------------------------------------------------------------

describe("is_opencode_win", function()
  it("returns true for a window with opencode_output filetype", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "opencode_output"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_true(I.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns true for a window with opencode_input filetype", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "opencode_input"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_true(I.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for a normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_false(I.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for an invalid window", function()
    assert.is_false(I.is_opencode_win(99999))
  end)
end)

------------------------------------------------------------------------
-- is_sidebar_win
------------------------------------------------------------------------

describe("is_sidebar_win", function()
  it("returns true for neo-tree filetype", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "neo-tree"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_true(I.is_sidebar_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns true for help buftype", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "help"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_true(I.is_sidebar_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for a normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_false(I.is_sidebar_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- find_code_win
------------------------------------------------------------------------

describe("find_code_win", function()
  it("returns nil when only window has opencode filetype", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, buf)

    assert.is_nil(I.find_code_win())

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("finds a code window when one exists alongside opencode", function()
    -- Current window: code buffer
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    -- Create a second window with opencode
    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local found = I.find_code_win()
    assert.equals(code_win, found)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("skips sidebar windows", function()
    -- Current window: neo-tree
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    -- No code window available
    assert.is_nil(I.find_code_win())

    vim.api.nvim_buf_delete(tree_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- open_dir
------------------------------------------------------------------------

describe("open_dir", function()
  it("opens the directory in the code window", function()
    -- Set up: code window with a normal buffer, plus an opencode window
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- Use a real directory
    local dir = vim.fn.stdpath("config")

    I.open_dir(dir)

    -- Should have switched to the code window
    assert.equals(code_win, vim.api.nvim_get_current_win())

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("creates a code window if none exists", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local dir = vim.fn.stdpath("config")
    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    I.open_dir(dir)

    local win_count_after = #vim.api.nvim_tabpage_list_wins(0)
    assert.is_true(win_count_after > win_count_before)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)
