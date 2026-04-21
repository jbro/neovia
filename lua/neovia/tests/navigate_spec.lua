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
-- open_dir (public API)
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

    navigate.open_dir(dir)

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

    navigate.open_dir(dir)

    local win_count_after = #vim.api.nvim_tabpage_list_wins(0)
    assert.is_true(win_count_after > win_count_before)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- open_in_code_win (public API)
------------------------------------------------------------------------

describe("open_in_code_win", function()
  it("opens a file in the code window", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- Use a real file
    local file = vim.fn.stdpath("config") .. "/init.lua"
    navigate.open_in_code_win(file)

    -- Should be in the code window with the file open
    assert.equals(code_win, vim.api.nvim_get_current_win())
    local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win))
    assert.is_true(bufname:match("init%.lua$") ~= nil)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("jumps to a specific line when provided", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    local file = vim.fn.stdpath("config") .. "/init.lua"
    navigate.open_in_code_win(file, 5)

    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(5, cursor[1])

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
  end)

  it("creates a code window if none exists", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local file = vim.fn.stdpath("config") .. "/init.lua"
    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    navigate.open_in_code_win(file)

    local win_count_after = #vim.api.nvim_tabpage_list_wins(0)
    assert.is_true(win_count_after > win_count_before)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("returns false for a non-existent file", function()
    local result = navigate.open_in_code_win("/nonexistent/file.lua")
    assert.is_false(result)
  end)
end)

------------------------------------------------------------------------
-- find_code_win (public API)
------------------------------------------------------------------------

describe("find_code_win (public)", function()
  it("is accessible as navigate.find_code_win", function()
    assert.is_function(navigate.find_code_win)
  end)
end)

------------------------------------------------------------------------
-- cfile
------------------------------------------------------------------------

describe("cfile", function()
  it("returns the file path under the cursor", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "look at src/foo.lua for details" })
    -- Position cursor on "src/foo.lua" (col 8, 0-indexed)
    vim.api.nvim_win_set_cursor(0, { 1, 8 })

    local result = I.cfile()
    assert.equals("src/foo.lua", result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns nil when no file path is under cursor", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local result = I.cfile()
    assert.is_nil(result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- resolve
------------------------------------------------------------------------

describe("resolve", function()
  it("returns absolute path unchanged", function()
    local result = I.resolve("/absolute/path.lua")
    assert.equals("/absolute/path.lua", result)
  end)

  it("resolves relative path to absolute", function()
    local result = I.resolve("relative/path.lua")
    -- Should start with / (absolute)
    assert.is_true(vim.startswith(result, "/"))
    assert.is_true(vim.endswith(result, "relative/path.lua"))
  end)
end)

------------------------------------------------------------------------
-- open (gf handler)
------------------------------------------------------------------------

describe("open", function()
  it("opens an existing file under cursor in the code window", function()
    -- Set up: opencode window + a code window
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- Put a real file path in the buffer and position cursor on it
    local file = vim.fn.stdpath("config") .. "/init.lua"
    vim.api.nvim_buf_set_lines(oc_buf, 0, -1, false, { file })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    navigate.open()

    -- Should have switched to the code window with init.lua open
    assert.equals(code_win, vim.api.nvim_get_current_win())
    local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win))
    assert.is_true(bufname:match("init%.lua$") ~= nil)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("opens a directory under cursor via netrw", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local dir = vim.fn.stdpath("config")
    vim.api.nvim_buf_set_lines(oc_buf, 0, -1, false, { dir })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    navigate.open()

    -- Should have switched to code window
    assert.equals(code_win, vim.api.nvim_get_current_win())

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("notifies when file is not found", function()
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end

    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)
    vim.api.nvim_buf_set_lines(oc_buf, 0, -1, false, { "/nonexistent/path/file.lua" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    navigate.open()

    vim.notify = orig_notify

    assert.is_true(#notified > 0)
    local found_not_found = false
    for _, n in ipairs(notified) do
      if n.msg:find("not found") then found_not_found = true end
    end
    assert.is_true(found_not_found)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("notifies when no path is under cursor", function()
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end

    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)
    vim.api.nvim_buf_set_lines(oc_buf, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    navigate.open()

    vim.notify = orig_notify

    local found_no_path = false
    for _, n in ipairs(notified) do
      if n.msg:find("no file path") then found_no_path = true end
    end
    assert.is_true(found_no_path)

    -- Cleanup
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- reset (reload contract)
------------------------------------------------------------------------

describe("reset", function()
  it("exists and is callable", function()
    assert.is_function(I.reset)
    -- Should not error
    I.reset()
  end)
end)
