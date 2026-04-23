-- tests/neovia/layout_spec.lua
-- Unit tests for lua/neovia/layout.lua

local layout = require("neovia.layout")
local I = layout._internal
local navigate = require("neovia.navigate")

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
    vim.cmd("only")
    I.set_opencode_opener(nil)
  end)

  it("creates a code window with scratch buffer when none exists", function()
    local scratch = require("neovia.scratch")
    scratch._internal.reset()
    scratch.setup({ state_dir = vim.fn.tempname() .. "_layout_test" })

    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_nil(navigate.find_code_win())

    I.ensure_layout()

    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win, "expected a code window to be created")
    local buf = vim.api.nvim_win_get_buf(code_win)
    assert.is_true(scratch.is_scratch(buf), "expected scratch buffer in code window")

    scratch._internal.reset()
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

  it("does nothing when both code and opencode windows exist", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    I.ensure_layout()

    assert.equals(win_count_before, #vim.api.nvim_tabpage_list_wins(0))

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
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

  it("restores code window when scratch buffer is closed with two opencode terminal windows", function()
    layout.setup()

    -- Code window showing scratch buffer (left)
    local scratch = require("neovia.scratch")
    scratch._internal.reset()
    scratch.setup({ state_dir = vim.fn.tempname() .. "_layout_scratch_close_test" })

    local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    local project_root = vim.fn.fnamemodify(spec_dir, ":h:h:h")
    local scratch_buf = scratch.get_or_create(project_root)
    vim.api.nvim_win_set_buf(0, scratch_buf)
    local code_win = vim.api.nvim_get_current_win()

    -- Opencode output (right, top) -- terminal buffer
    vim.cmd("vsplit | terminal")
    local oc_out_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_out_buf].filetype = "opencode_output"

    -- Opencode input (right, bottom) -- terminal buffer
    vim.cmd("split | terminal")
    local oc_in_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_in_buf].filetype = "opencode"

    -- Close the scratch window
    vim.api.nvim_set_current_win(code_win)
    vim.cmd("close")

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored after scratch close")

    pcall(vim.api.nvim_buf_delete, oc_out_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_in_buf, { force = true })
    scratch._internal.reset()
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

  it("open_scratch_in_code_win works when current window is a terminal", function()
    local scratch = require("neovia.scratch")
    scratch._internal.reset()
    scratch.setup({ state_dir = vim.fn.tempname() .. "_layout_term_test" })

    vim.cmd("terminal")
    local term_buf = vim.api.nvim_get_current_buf()
    vim.bo[term_buf].filetype = "opencode"

    assert.is_nil(navigate.find_code_win(), "no code window should exist yet")

    local spec_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    local project_root = vim.fn.fnamemodify(spec_dir, ":h:h:h")

    local ok, err = pcall(navigate.open_scratch_in_code_win, project_root)

    assert.is_true(ok, "open_scratch_in_code_win should not error: " .. tostring(err))
    assert.is_not_nil(navigate.find_code_win(), "code window should be created")

    vim.cmd("only")
    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
    scratch._internal.reset()
  end)

  it("does nothing when layout is correct after close", function()
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

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    vim.api.nvim_set_current_win(win2)
    vim.cmd("close")

    vim.wait(50, function() return false end)

    assert.equals(win_count_before - 1, #vim.api.nvim_tabpage_list_wins(0))

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

  it("rebuilds layout from scratch, closing extra windows", function()
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

  it("falls back to scratch buffer when no code buffer was showing", function()
    local scratch = require("neovia.scratch")
    scratch._internal.reset()
    scratch.setup({ state_dir = vim.fn.tempname() .. "_layout_restore_test" })

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
    assert.is_true(scratch.is_scratch(buf), "expected scratch buffer in code window")

    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
    scratch._internal.reset()
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
    vim.wait(50, function() return false end)

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

    vim.wait(50, function() return false end)

    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))

    vim.cmd("only")
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)
