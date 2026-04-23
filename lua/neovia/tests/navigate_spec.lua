-- tests/neovia/navigate_spec.lua
-- Unit tests for lua/neovia/navigate.lua

local navigate = require("neovia.navigate")
local I = navigate._internal

-- Resolve project root from this spec file (lua/neovia/tests/ -> repo root)
local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local project_root = vim.fn.fnamemodify(spec_dir, ":h:h:h")
-- A file guaranteed to exist when running tests from this project
local test_file = project_root .. "/init.lua"

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

    assert.is_true(navigate.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns true for a window with opencode filetype (input buffer)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "opencode"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_true(navigate.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns true for a window with opencode_footer filetype", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "opencode_footer"
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_true(navigate.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for a normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    assert.is_false(navigate.is_opencode_win(win))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for an invalid window", function()
    assert.is_false(navigate.is_opencode_win(99999))
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
-- open_scratch_in_code_win (public API)
------------------------------------------------------------------------

describe("open_scratch_in_code_win", function()
  local scratch = require("neovia.scratch")
  local test_state_dir = vim.fn.tempname() .. "_nav_scratch_test"

  before_each(function()
    scratch._internal.reset()
    scratch.setup({ state_dir = test_state_dir })
  end)

  after_each(function()
    scratch._internal.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("shows the scratch buffer in the code window", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local dir = project_root
    navigate.open_scratch_in_code_win(dir)

    -- Should be in the code window
    assert.equals(code_win, vim.api.nvim_get_current_win())
    -- Buffer should be a scratch buffer
    local buf = vim.api.nvim_win_get_buf(code_win)
    assert.is_true(scratch.is_scratch(buf))

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("creates a code window if none exists", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    navigate.open_scratch_in_code_win(project_root)

    local win_count_after = #vim.api.nvim_tabpage_list_wins(0)
    assert.is_true(win_count_after > win_count_before)

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("creates a full-height code window with stacked opencode windows", function()
    local oc_out_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_out_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_out_buf)
    local oc_out_win = vim.api.nvim_get_current_win()

    vim.cmd("split")
    local oc_in_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_in_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_in_buf)
    local oc_in_win = vim.api.nvim_get_current_win()

    navigate.open_scratch_in_code_win(project_root)

    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win, "code window should be created")

    local code_height = vim.api.nvim_win_get_height(code_win)
    local oc_out_height = vim.api.nvim_win_get_height(oc_out_win)
    local oc_in_height = vim.api.nvim_win_get_height(oc_in_win)
    local total_oc_height = oc_out_height + oc_in_height

    assert.is_true(
      math.abs(code_height - total_oc_height) <= 2,
      string.format(
        "code window should span full height: code=%d oc_out=%d oc_in=%d total_oc=%d",
        code_height, oc_out_height, oc_in_height, total_oc_height
      )
    )

    -- Cleanup
    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_out_buf, { force = true })
    vim.api.nvim_buf_delete(oc_in_buf, { force = true })
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
    local file = test_file
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

    local file = test_file
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

    local file = test_file
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
    local file = test_file
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

  it("reveals a directory under cursor in neo-tree", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local dir = project_root
    vim.api.nvim_buf_set_lines(oc_buf, 0, -1, false, { dir })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    -- Capture Neotree commands issued
    local neotree_cmd = nil
    local orig_cmd = vim.cmd
    vim.cmd = function(c)
      if type(c) == "string" and c:find("Neotree") then
        neotree_cmd = c
      else
        orig_cmd(c)
      end
    end

    navigate.open()

    vim.cmd = orig_cmd

    assert.is_truthy(neotree_cmd, "should have issued a Neotree command")
    assert.is_truthy(neotree_cmd:find("reveal"), "should reveal in neo-tree")

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
-- buffer_list
------------------------------------------------------------------------

describe("buffer_list", function()
  it("returns listed buffers with relative paths", function()
    -- Create two listed buffers with names
    local buf1 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf1, project_root .. "/src/foo.lua")
    local buf2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf2, project_root .. "/src/bar.lua")

    local list = I.buffer_list()

    -- Should contain both buffers
    local names = {}
    for _, entry in ipairs(list) do
      names[entry.name] = entry.bufnr
    end
    assert.is_not_nil(names["src/foo.lua"])
    assert.is_not_nil(names["src/bar.lua"])
    assert.equals(buf1, names["src/foo.lua"])
    assert.equals(buf2, names["src/bar.lua"])

    -- Cleanup
    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)

  it("excludes unlisted buffers", function()
    local listed = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(listed, project_root .. "/listed.lua")
    local unlisted = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(unlisted, project_root .. "/unlisted.lua")

    local list = I.buffer_list()
    local names = {}
    for _, entry in ipairs(list) do
      names[entry.name] = true
    end
    assert.is_not_nil(names["listed.lua"])
    assert.is_nil(names["unlisted.lua"])

    vim.api.nvim_buf_delete(listed, { force = true })
    vim.api.nvim_buf_delete(unlisted, { force = true })
  end)

  it("excludes special buftype buffers", function()
    local normal = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(normal, project_root .. "/normal.lua")
    -- Use nofile as a stand-in for special buftypes (terminal can't be set directly)
    local special = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(special, project_root .. "/special")
    vim.bo[special].buftype = "nofile"

    local list = I.buffer_list()
    local names = {}
    for _, entry in ipairs(list) do
      names[entry.name] = true
    end
    assert.is_not_nil(names["normal.lua"])
    assert.is_nil(names["special"])

    vim.api.nvim_buf_delete(normal, { force = true })
    vim.api.nvim_buf_delete(special, { force = true })
  end)

  it("excludes unnamed buffers", function()
    local named = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(named, project_root .. "/named.lua")
    local unnamed = vim.api.nvim_create_buf(true, false)
    -- No name set

    local list = I.buffer_list()
    local names = {}
    for _, entry in ipairs(list) do
      names[entry.name] = true
    end
    assert.is_not_nil(names["named.lua"])

    vim.api.nvim_buf_delete(named, { force = true })
    vim.api.nvim_buf_delete(unnamed, { force = true })
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
