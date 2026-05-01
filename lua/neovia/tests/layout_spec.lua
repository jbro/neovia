-- tests/neovia/layout_spec.lua
-- Unit tests for lua/neovia/layout.lua

local layout = require("neovia.layout")
local I = layout._internal
local navigate = require("neovia.navigate")

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------

describe("layout constants", function()
  it("exposes sidebar_width as a positive integer", function()
    assert.is_number(layout.sidebar_width)
    assert.is_true(layout.sidebar_width > 0)
    assert.equals(math.floor(layout.sidebar_width), layout.sidebar_width)
  end)

  it("exposes opencode_ratio as a fraction between 0 and 1", function()
    assert.is_number(layout.opencode_ratio)
    assert.is_true(layout.opencode_ratio > 0)
    assert.is_true(layout.opencode_ratio < 1)
  end)

  it("exposes notes_height as a positive integer", function()
    assert.is_number(layout.notes_height)
    assert.is_true(layout.notes_height > 0)
    assert.equals(math.floor(layout.notes_height), layout.notes_height)
  end)
end)

describe("opencode_width_ratio", function()
  it("returns a ratio that subtracts sidebar_width from the opencode share", function()
    -- For a 200-column editor with sidebar=35 and ratio=0.50:
    -- opencode gets 0.50 * (200 - 35) / 200 = 82.5/200 = 0.4125
    local ratio = layout.opencode_width_ratio(200)
    local expected = layout.opencode_ratio * (200 - layout.sidebar_width) / 200
    assert.near(expected, ratio, 0.0001)
  end)

  it("defaults to vim.o.columns when no argument given", function()
    local ratio = layout.opencode_width_ratio()
    local expected = layout.opencode_ratio * (vim.o.columns - layout.sidebar_width) / vim.o.columns
    assert.near(expected, ratio, 0.0001)
  end)

  it("returns a value less than opencode_ratio", function()
    local ratio = layout.opencode_width_ratio(200)
    assert.is_true(ratio < layout.opencode_ratio)
  end)

  it("returns a value greater than 0 for reasonable screen widths", function()
    local ratio = layout.opencode_width_ratio(120)
    assert.is_true(ratio > 0)
  end)
end)

------------------------------------------------------------------------
-- find_opencode_win
------------------------------------------------------------------------

describe("find_opencode_win", function()
  after_each(function()
    vim.cmd("only")
  end)

  it("returns an opencode window when one exists", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"

    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, oc_buf)
    local oc_win = vim.api.nvim_get_current_win()

    assert.equals(oc_win, I.find_opencode_win())

    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("returns nil when no opencode window exists", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)

    assert.is_nil(I.find_opencode_win())

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("finds opencode windows", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_not_nil(I.find_opencode_win())

    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("skips floating windows", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_open_win(oc_buf, false, {
      relative = "editor", width = 10, height = 10, row = 1, col = 1,
    })

    assert.is_nil(I.find_opencode_win())

    vim.cmd("only")
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- ensure_layout
------------------------------------------------------------------------

describe("ensure_layout", function()
  after_each(function()
    -- Close extra tabs
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tablast | tabclose")
    end
    vim.cmd("only")
    I.set_opencode_opener(nil)
    local ok_dv, dv = pcall(require, "neovia.diffview")
    if ok_dv and dv._internal then dv._internal.reset() end
  end)

  it("creates a code window with noname buffer when none exists", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_nil(navigate.find_code_win())

    I.ensure_layout()

    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win, "expected a code window to be created")
    -- Code window should have a noname buffer (empty name, normal buftype)
    local buf = vim.api.nvim_win_get_buf(code_win)
    assert.equals("", vim.api.nvim_buf_get_name(buf))

    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("creates a notes window when none exists", function()
    local notes = require("neovia.notes")
    notes._internal.reset()
    notes.setup({ cache_dir = vim.fn.tempname() .. "_layout_notes_test" })

    -- code window + opencode but no notes
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_nil(navigate.find_notes_win(), "no notes window should exist yet")

    I.ensure_layout()

    local notes_win = navigate.find_notes_win()
    assert.is_not_nil(notes_win, "expected a notes window to be created")
    local nbuf = vim.api.nvim_win_get_buf(notes_win)
    assert.is_true(notes.is_notes(nbuf), "notes window should show a notes buffer")

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
    notes._internal.reset()
  end)

  it("creates a code window even when the opencode window is a terminal", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    vim.cmd("vsplit | terminal")
    local oc_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_buf].filetype = "opencode"

    vim.cmd("only")

    assert.is_nil(navigate.find_code_win())

    I.ensure_layout()

    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win, "expected a code window next to terminal")

    local new_buf = vim.api.nvim_win_get_buf(code_win)
    assert.is_not_equal("terminal", vim.bo[new_buf].buftype)

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("calls opencode opener when no opencode window exists", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    assert.is_nil(I.find_opencode_win())

    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    I.ensure_layout()

    assert.is_true(opener_called, "expected opencode opener to be called")

    vim.api.nvim_buf_delete(code_buf, { force = true })
  end)

  it("does nothing when code, notes, and opencode windows all exist", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    -- Notes window below code
    vim.cmd("split")
    local notes_buf = vim.api.nvim_create_buf(true, false)
    vim.b[notes_buf].neovia_notes = true
    vim.api.nvim_win_set_buf(0, notes_buf)

    -- Opencode window to the right
    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    I.ensure_layout()

    assert.equals(win_count_before, #vim.api.nvim_tabpage_list_wins(0))

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(notes_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("skips layout enforcement on diffview tabs", function()
    local dv = require("neovia.diffview")
    -- Create a tab and register it as a diffview tab
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register("/proj/main", dv_tab)

    -- The tab has just a single scratch buffer -- normally ensure_layout
    -- would try to create code/opencode windows.
    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    I.ensure_layout()

    -- Should NOT have modified the window layout or called opener
    assert.equals(win_count_before, #vim.api.nvim_tabpage_list_wins(0),
      "ensure_layout should not create windows on diffview tabs")
    assert.is_false(opener_called,
      "ensure_layout should not call opencode opener on diffview tabs")
  end)
end)

------------------------------------------------------------------------
-- setup / reset (reload contract)
------------------------------------------------------------------------

describe("setup", function()
  after_each(function()
    vim.cmd("only")
    I.reset()
    I.set_opencode_opener(nil)
  end)

  it("creates the neovia_layout augroup", function()
    layout.setup()
    local ok, id = pcall(vim.api.nvim_create_augroup, "neovia_layout", { clear = false })
    assert.is_true(ok)
    assert.is_number(id)
  end)

  it("is idempotent", function()
    layout.setup()
    local cmds1 = vim.api.nvim_get_autocmds({ group = "neovia_layout" })

    layout.setup()
    local cmds2 = vim.api.nvim_get_autocmds({ group = "neovia_layout" })

    assert.equals(#cmds1, #cmds2)
  end)

  it("registers a VimEnter autocmd that calls the opencode opener", function()
    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    layout.setup()

    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_layout", event = "VimEnter" })
    assert.is_true(#cmds > 0, "expected a VimEnter autocmd")
  end)

  it("restores code window via WinClosed when last one closes", function()
    layout.setup()

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    vim.api.nvim_set_current_win(code_win)
    vim.cmd("close")

    vim.wait(50, function() return false end)

    assert.is_not_nil(navigate.find_code_win(), "code window should be restored")

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("restores code window when terminal opencode is the only window left", function()
    layout.setup()

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit | terminal")
    local oc_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_buf].filetype = "opencode"

    vim.api.nvim_set_current_win(code_win)
    vim.cmd("close")

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored next to terminal")

    local new_buf = vim.api.nvim_win_get_buf(new_code_win)
    assert.is_not_equal("terminal", vim.bo[new_buf].buftype)

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("calls opencode opener via WinClosed when opencode window closes", function()
    layout.setup()

    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)
    local oc_win = vim.api.nvim_get_current_win()

    vim.api.nvim_set_current_win(oc_win)
    vim.cmd("close")

    vim.wait(50, function() return false end)

    assert.is_true(opener_called, "expected opencode opener to be called")

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  -- Realistic scenarios: opencode has two terminal windows (output + input)
  -- stacked vertically on the right, code window on the left.

  it("restores code window when closed with two opencode terminal windows", function()
    layout.setup()

    -- Code window (left)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    -- Opencode output (right, top) -- terminal buffer
    vim.cmd("vsplit | terminal")
    local oc_out_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_out_buf].filetype = "opencode_output"

    -- Opencode input (right, bottom) -- terminal buffer
    vim.cmd("split | terminal")
    local oc_in_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_in_buf].filetype = "opencode"

    -- Close the code window
    vim.api.nvim_set_current_win(code_win)
    vim.cmd("close")

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored")

    local new_buf = vim.api.nvim_win_get_buf(new_code_win)
    assert.is_not_equal("terminal", vim.bo[new_buf].buftype,
      "restored window should not be a terminal")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_out_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_in_buf, { force = true })
  end)

  it("restores code window when closed with :q instead of :close", function()
    layout.setup()

    -- Code window (left)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    -- Opencode windows (right)
    vim.cmd("vsplit | terminal")
    local oc_out_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_out_buf].filetype = "opencode_output"

    vim.cmd("split | terminal")
    local oc_in_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_in_buf].filetype = "opencode"

    -- Close code window with :q (not :close)
    vim.api.nvim_set_current_win(code_win)
    vim.cmd("quit")

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored after :q")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_out_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_in_buf, { force = true })
  end)

  it("restores code window when closed via nvim_win_close", function()
    layout.setup()

    -- Code window (left)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    -- Opencode windows (right)
    vim.cmd("vsplit | terminal")
    local oc_out_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_out_buf].filetype = "opencode_output"

    vim.cmd("split | terminal")
    local oc_in_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_in_buf].filetype = "opencode"

    -- Close code window via API
    vim.api.nvim_win_close(code_win, true)

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored after nvim_win_close")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_out_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_in_buf, { force = true })
  end)

  it("restores code window when focus lands in terminal mode after close", function()
    layout.setup()

    -- Code window (left)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    -- Single opencode terminal window (right)
    vim.cmd("vsplit | terminal")
    local oc_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_buf].filetype = "opencode"
    local oc_win = vim.api.nvim_get_current_win()

    -- Enter terminal mode in the opencode window, then switch back to code
    vim.cmd("startinsert")
    vim.api.nvim_set_current_win(code_win)

    -- Close code window -- focus should land on the terminal in terminal mode
    vim.cmd("close")

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win,
      "code window should be restored even when focus lands in terminal mode")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("restores code window to the right of neo-tree after :bw", function()
    layout.setup()

    I.set_opencode_opener(function() end)

    -- Simulate the layout: neo-tree (left) | code (centre) | opencode (right)
    -- Neo-tree window
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    -- Code window to the right of neo-tree
    vim.cmd("vsplit")
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    -- Opencode window to the right of code
    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- Switch to code window and wipe its only buffer
    local code_win = navigate.find_code_win()
    vim.api.nvim_set_current_win(code_win)
    vim.cmd("bwipeout!")

    vim.wait(100, function() return false end)

    -- Code window should be restored
    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored after :bw")

    -- Code window must be to the RIGHT of neo-tree, not to its left.
    -- Check window positions: code_win col > neo-tree col
    if new_code_win then
      local tree_col = vim.api.nvim_win_get_position(
        vim.fn.win_getid(vim.fn.bufwinnr(tree_buf)))[2]
      local code_col = vim.api.nvim_win_get_position(new_code_win)[2]
      assert.is_true(code_col > tree_col,
        "code window should be to the right of neo-tree, not to the left")
    end

    pcall(vim.api.nvim_buf_delete, tree_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("does not create extra code windows when layout has code + opencode after close", function()
    layout.setup()

    local buf1 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf1)

    vim.cmd("vsplit")
    local buf2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf2)
    local win2 = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- Close one of the two code windows
    vim.api.nvim_set_current_win(win2)
    vim.cmd("close")

    vim.wait(50, function() return false end)

    -- Code window should still exist (buf1's window remains)
    assert.is_not_nil(navigate.find_code_win(), "code window should still exist")

    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- restore_layout
------------------------------------------------------------------------

describe("restore_layout", function()
  after_each(function()
    vim.cmd("only")
    I.reset()
    I.set_opencode_opener(nil)
  end)

  it("rebuilds layout, closing extra windows", function()
    layout.setup()

    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    -- Simulate a messy state: code + neo-tree + opencode
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.equals(3, #vim.api.nvim_tabpage_list_wins(0))

    layout.restore_layout()

    -- Should have called opener and created a code window
    assert.is_true(opener_called)
    assert.is_not_nil(navigate.find_code_win())

    -- The code buffer should still exist (not wiped)
    assert.is_true(vim.api.nvim_buf_is_valid(code_buf))

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, tree_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("restores the code buffer that was showing before", function()
    layout.setup()

    I.set_opencode_opener(function() end)

    -- Code window with a specific buffer
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(code_buf, "/tmp/test_restore.lua")
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    layout.restore_layout()

    local win = navigate.find_code_win()
    assert.is_not_nil(win)
    local buf_in_win = vim.api.nvim_win_get_buf(win)
    assert.equals(code_buf, buf_in_win)

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("uses noname buffer when no code buffer was showing", function()
    layout.setup()

    I.set_opencode_opener(function() end)

    -- Only opencode, no code window
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    layout.restore_layout()

    local win = navigate.find_code_win()
    assert.is_not_nil(win)
    local buf = vim.api.nvim_win_get_buf(win)
    -- Should be a noname buffer, not a notes buffer
    assert.equals("", vim.api.nvim_buf_get_name(buf))

    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("creates a notes split below the code window", function()
    local notes = require("neovia.notes")
    notes._internal.reset()
    notes.setup({ cache_dir = vim.fn.tempname() .. "_layout_restore_notes_test" })

    layout.setup()
    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    layout.restore_layout()

    local notes_win = navigate.find_notes_win()
    assert.is_not_nil(notes_win, "expected notes window after restore_layout")
    local nbuf = vim.api.nvim_win_get_buf(notes_win)
    assert.is_true(notes.is_notes(nbuf), "notes window should show a notes buffer")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    notes._internal.reset()
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

  it("allows setup to run again after reset", function()
    layout.setup()
    I.reset()
    layout.setup()
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_layout" })
    assert.is_true(#cmds > 0)
    I.reset()
  end)

  it("disables WinClosed enforcement after reset", function()
    -- Flush any stale vim.schedule callbacks from previous tests
    vim.wait(150, function() return false end)
    vim.cmd("only")

    layout.setup()
    I.reset()

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    vim.api.nvim_set_current_win(code_win)
    vim.cmd("close")

    vim.wait(100, function() return false end)

    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)
