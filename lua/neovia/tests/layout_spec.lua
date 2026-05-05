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
-- is_layout_ok (pure check: all panels present and correctly ordered)
------------------------------------------------------------------------

describe("is_layout_ok", function()
  after_each(function()
    vim.cmd("only")
  end)

  it("returns false when only one window exists", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, buf)

    assert.is_false(I.is_layout_ok())

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false when code window is missing", function()
    -- neo-tree + opencode but no code
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_false(I.is_layout_ok())

    vim.api.nvim_buf_delete(tree_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("returns false when opencode window is missing", function()
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    vim.cmd("vsplit")
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    assert.is_false(I.is_layout_ok())

    vim.api.nvim_buf_delete(tree_buf, { force = true })
    vim.api.nvim_buf_delete(code_buf, { force = true })
  end)

  it("returns true when neo-tree + code + notes + opencode exist in correct order", function()
    -- neo-tree (left) -- start here
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    -- code (centre, right of neo-tree)
    vim.cmd("rightbelow vsplit")
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    -- notes (below code)
    vim.cmd("belowright split")
    local notes_buf = vim.api.nvim_create_buf(true, false)
    vim.b[notes_buf].neovia_notes = true
    vim.api.nvim_win_set_buf(0, notes_buf)

    -- opencode (right of notes/code column)
    vim.cmd("rightbelow vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_true(I.is_layout_ok())

    vim.api.nvim_buf_delete(tree_buf, { force = true })
    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(notes_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("returns true when code + opencode exist without neo-tree (neo-tree optional)", function()
    -- code (left)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    -- opencode (right of code)
    vim.cmd("rightbelow vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_true(I.is_layout_ok())

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("returns false when opencode is to the left of code", function()
    -- opencode (left -- wrong!)
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- code (right of opencode -- wrong order!)
    vim.cmd("rightbelow vsplit")
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    assert.is_false(I.is_layout_ok())

    vim.api.nvim_buf_delete(oc_buf, { force = true })
    vim.api.nvim_buf_delete(code_buf, { force = true })
  end)

  it("returns false when neo-tree is to the right of code", function()
    -- code (left)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    -- neo-tree (right of code -- wrong!)
    vim.cmd("rightbelow vsplit")
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    -- opencode (right of neo-tree)
    vim.cmd("rightbelow vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_false(I.is_layout_ok())

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(tree_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- apply (unified layout enforcement)
------------------------------------------------------------------------

describe("apply", function()
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

  it("skips layout enforcement on diffview tabs", function()
    local dv = require("neovia.diffview")
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register("/proj/main", dv_tab)

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    layout.apply()

    assert.equals(win_count_before, #vim.api.nvim_tabpage_list_wins(0),
      "apply should not create windows on diffview tabs")
    assert.is_false(opener_called,
      "apply should not call opencode opener on diffview tabs")
  end)

  it("creates a code window when none exists", function()
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    assert.is_nil(navigate.find_code_win())

    I.set_opencode_opener(function() end)
    layout.apply()

    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win, "expected a code window to be created")

    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("calls opencode opener when no opencode window exists", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    assert.is_nil(I.find_opencode_win())

    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    layout.apply()

    assert.is_true(opener_called, "expected opencode opener to be called")

    vim.api.nvim_buf_delete(code_buf, { force = true })
  end)

  it("preserves the code buffer across rebuild", function()
    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(code_buf, "/tmp/test_apply_preserve.lua")
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    layout.apply()

    local win = navigate.find_code_win()
    assert.is_not_nil(win)
    local buf_in_win = vim.api.nvim_win_get_buf(win)
    assert.equals(code_buf, buf_in_win,
      "code buffer should be preserved across apply")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("uses noname buffer when no code buffer was showing", function()
    I.set_opencode_opener(function() end)

    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    layout.apply()

    local win = navigate.find_code_win()
    assert.is_not_nil(win)
    local buf = vim.api.nvim_win_get_buf(win)
    assert.equals("", vim.api.nvim_buf_get_name(buf))

    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("creates a notes split below the code window", function()
    local notes = require("neovia.notes")
    notes._internal.reset()
    notes.setup({ cache_dir = vim.fn.tempname() .. "_layout_apply_notes_test" })

    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    layout.apply()

    local notes_win = navigate.find_notes_win()
    assert.is_not_nil(notes_win, "expected notes window after apply")
    local nbuf = vim.api.nvim_win_get_buf(notes_win)
    assert.is_true(notes.is_notes(nbuf), "notes window should show a notes buffer")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    notes._internal.reset()
  end)

  it("rebuilds from a messy state", function()
    local opener_called = false
    I.set_opencode_opener(function() opener_called = true end)

    -- Simulate a messy state: code + neo-tree + opencode in wrong order
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

    layout.apply()

    assert.is_true(opener_called, "expected opencode opener to be called")
    assert.is_not_nil(navigate.find_code_win(), "code window should exist after apply")
    assert.is_true(vim.api.nvim_buf_is_valid(code_buf), "code buffer should survive apply")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, tree_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("places code window to the right of neo-tree", function()
    I.set_opencode_opener(function() end)

    -- Start with neo-tree
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[tree_buf].filetype = "neo-tree"
    vim.api.nvim_win_set_buf(0, tree_buf)

    -- Code to the right
    vim.cmd("vsplit")
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    -- Wipe code buffer to force rebuild
    vim.cmd("bwipeout!")

    -- Wait for WinClosed if setup() was called, but here we call directly
    layout.apply()

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win, "code window should be restored")

    -- Neo-tree might have been re-opened via Neotree show, but in test env
    -- it won't be. Check code window position is reasonable.
    if new_code_win and vim.fn.bufwinnr(tree_buf) > 0 then
      local tree_col = vim.api.nvim_win_get_position(
        vim.fn.win_getid(vim.fn.bufwinnr(tree_buf)))[2]
      local code_col = vim.api.nvim_win_get_position(new_code_win)[2]
      assert.is_true(code_col > tree_col,
        "code window should be to the right of neo-tree")
    end

    pcall(vim.api.nvim_buf_delete, tree_buf, { force = true })
  end)

  it("is a no-op when layout is already correct", function()
    I.set_opencode_opener(function() end)

    -- Build correct layout: code + notes + opencode (left to right)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("belowright split")
    local notes_buf = vim.api.nvim_create_buf(true, false)
    vim.b[notes_buf].neovia_notes = true
    vim.api.nvim_win_set_buf(0, notes_buf)

    -- opencode to the RIGHT of the notes/code column
    vim.cmd("rightbelow vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

    layout.apply()

    -- Should not have changed window count (no nuke-and-rebuild needed)
    assert.equals(win_count_before, #vim.api.nvim_tabpage_list_wins(0),
      "apply should be a no-op when layout is correct")

    vim.api.nvim_buf_delete(code_buf, { force = true })
    vim.api.nvim_buf_delete(notes_buf, { force = true })
    vim.api.nvim_buf_delete(oc_buf, { force = true })
  end)

  it("focuses the code window after rebuild", function()
    I.set_opencode_opener(function() end)

    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    layout.apply()

    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win)
    assert.equals(code_win, vim.api.nvim_get_current_win(),
      "focus should be on the code window after apply")

    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("cleans up stray noname buffers after rebuild", function()
    I.set_opencode_opener(function() end)

    -- Create some stray noname buffers
    local stray1 = vim.api.nvim_create_buf(true, false)
    local stray2 = vim.api.nvim_create_buf(true, false)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(code_buf, "/tmp/test_stray.lua")
    vim.api.nvim_win_set_buf(0, code_buf)

    layout.apply()

    -- Stray noname buffers not in any window should be wiped
    assert.is_false(vim.api.nvim_buf_is_valid(stray1),
      "stray noname buffer should be wiped")
    assert.is_false(vim.api.nvim_buf_is_valid(stray2),
      "stray noname buffer should be wiped")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- setup / reset (reload contract)
------------------------------------------------------------------------

describe("setup", function()
  after_each(function()
    I.reset()
    I.set_opencode_opener(nil)
    -- Flush deferred callbacks (WinClosed schedules apply() which may
    -- schedule more callbacks). Two rounds of vim.wait to drain them.
    vim.wait(50, function() return false end)
    vim.wait(50, function() return false end)
    -- Close all extra windows without using only! (hangs on terminals)
    local wins = vim.api.nvim_tabpage_list_wins(0)
    while #wins > 1 do
      for _, w in ipairs(wins) do
        if w ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_is_valid(w) then
          pcall(vim.api.nvim_win_close, w, true)
          break
        end
      end
      wins = vim.api.nvim_tabpage_list_wins(0)
    end
    -- Force-wipe leftover terminal buffers to avoid process leaks
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buftype == "terminal" then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
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

  it("registers a VimEnter autocmd", function()
    layout.setup()

    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_layout", event = "VimEnter" })
    assert.is_true(#cmds > 0, "expected a VimEnter autocmd")
  end)

  it("restores code window via WinClosed when last one closes", function()
    layout.setup()

    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("rightbelow vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode"
    vim.api.nvim_win_set_buf(0, oc_buf)

    vim.api.nvim_set_current_win(code_win)
    vim.cmd("close")

    vim.wait(50, function() return false end)

    assert.is_not_nil(navigate.find_code_win(), "code window should be restored")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("restores code window when terminal opencode is the only window left", function()
    layout.setup()

    I.set_opencode_opener(function() end)

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

  it("restores code window when closed with two opencode terminal windows", function()
    layout.setup()

    I.set_opencode_opener(function() end)

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

  it("restores code window when closed with :q", function()
    layout.setup()

    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit | terminal")
    local oc_out_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_out_buf].filetype = "opencode_output"

    vim.cmd("split | terminal")
    local oc_in_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_in_buf].filetype = "opencode"

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

    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit | terminal")
    local oc_out_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_out_buf].filetype = "opencode_output"

    vim.cmd("split | terminal")
    local oc_in_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_in_buf].filetype = "opencode"

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

    I.set_opencode_opener(function() end)

    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)
    local code_win = vim.api.nvim_get_current_win()

    vim.cmd("vsplit | terminal")
    local oc_buf = vim.api.nvim_get_current_buf()
    vim.bo[oc_buf].filetype = "opencode"

    vim.cmd("startinsert")
    vim.api.nvim_set_current_win(code_win)

    vim.cmd("close")

    vim.wait(100, function() return false end)

    local new_code_win = navigate.find_code_win()
    assert.is_not_nil(new_code_win,
      "code window should be restored even when focus lands in terminal mode")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)

  it("does not create extra code windows when one still exists after close", function()
    layout.setup()

    I.set_opencode_opener(function() end)

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

    assert.is_not_nil(navigate.find_code_win(), "code window should still exist")

    pcall(vim.api.nvim_buf_delete, buf1, { force = true })
    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- enforce_notes_height
------------------------------------------------------------------------

describe("enforce_notes_height", function()
  after_each(function()
    vim.cmd("only")
  end)

  it("sets notes window height to notes_height", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("belowright split")
    local notes_buf = vim.api.nvim_create_buf(true, false)
    vim.b[notes_buf].neovia_notes = true
    vim.api.nvim_win_set_buf(0, notes_buf)
    local notes_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_set_height(notes_win, 40)
    assert.is_not.equals(layout.notes_height, vim.api.nvim_win_get_height(notes_win))

    layout.enforce_notes_height()

    assert.equals(layout.notes_height, vim.api.nvim_win_get_height(notes_win))

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, notes_buf, { force = true })
  end)

  it("sets winfixheight on the notes window", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("belowright split")
    local notes_buf = vim.api.nvim_create_buf(true, false)
    vim.b[notes_buf].neovia_notes = true
    vim.api.nvim_win_set_buf(0, notes_buf)
    local notes_win = vim.api.nvim_get_current_win()

    layout.enforce_notes_height()

    assert.is_true(vim.wo[notes_win].winfixheight)

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, notes_buf, { force = true })
  end)

  it("is a no-op when no notes window exists", function()
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    layout.enforce_notes_height()

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
  end)
end)

describe("apply enforces notes height on existing window", function()
  after_each(function()
    vim.cmd("only")
  end)

  it("re-enforces height when notes window already exists at wrong size", function()
    local notes_mod = require("neovia.notes")
    notes_mod._internal.reset()
    notes_mod.setup({ cache_dir = vim.fn.tempname() .. "_layout_enforce_test" })

    I.set_opencode_opener(function() end)

    -- Create code + notes + opencode manually (correct layout, left to right)
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    vim.cmd("belowright split")
    local nbuf = notes_mod.get_or_create(vim.fn.getcwd())
    vim.api.nvim_win_set_buf(0, nbuf)
    local notes_win = vim.api.nvim_get_current_win()

    -- opencode to the RIGHT
    vim.cmd("rightbelow vsplit")
    local oc_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[oc_buf].filetype = "opencode_output"
    vim.api.nvim_win_set_buf(0, oc_buf)

    -- Simulate height drift
    vim.wo[notes_win].winfixheight = false
    vim.api.nvim_win_set_height(notes_win, 40)

    layout.apply()

    -- Notes height should be enforced (either via no-op path or rebuild)
    local final_notes_win = navigate.find_notes_win()
    assert.is_not_nil(final_notes_win, "notes window should still exist")
    assert.equals(layout.notes_height, vim.api.nvim_win_get_height(final_notes_win),
      "notes window height should be re-enforced")
    assert.is_true(vim.wo[final_notes_win].winfixheight,
      "winfixheight should be set")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, oc_buf, { force = true })
    notes_mod._internal.reset()
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
