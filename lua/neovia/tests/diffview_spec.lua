-- tests/neovia/diffview_spec.lua
-- Unit tests for lua/neovia/diffview.lua

local diffview = require("neovia.diffview")

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Close all tabs except the first, reset state.
local function cleanup()
  -- Close all extra tab pages
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("tablast | tabclose")
  end
  if diffview._internal and diffview._internal.reset then
    diffview._internal.reset()
  end
end

------------------------------------------------------------------------
-- Tab registry
------------------------------------------------------------------------

describe("tab registry", function()
  before_each(cleanup)
  after_each(cleanup)

  it("exposes _internal table", function()
    assert.is_table(diffview._internal)
  end)

  it("tab_for_worktree returns nil when no diffview tab exists", function()
    assert.is_nil(diffview._internal.tab_for_worktree("/proj/main"))
  end)

  it("register stores a tab for a worktree directory", function()
    -- Create a real tab page to register
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    diffview._internal.register("/proj/main", tab)
    assert.equals(tab, diffview._internal.tab_for_worktree("/proj/main"))
  end)

  it("unregister removes the tab mapping", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    diffview._internal.register("/proj/main", tab)
    diffview._internal.unregister("/proj/main")
    assert.is_nil(diffview._internal.tab_for_worktree("/proj/main"))
  end)

  it("is_diffview_tab returns true for registered tabs", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    diffview._internal.register("/proj/main", tab)
    assert.is_true(diffview._internal.is_diffview_tab(tab))
  end)

  it("is_diffview_tab returns false for unregistered tabs", function()
    local tab = vim.api.nvim_get_current_tabpage()
    assert.is_false(diffview._internal.is_diffview_tab(tab))
  end)

  it("is_diffview_tab returns false after unregister", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    diffview._internal.register("/proj/main", tab)
    diffview._internal.unregister("/proj/main")
    assert.is_false(diffview._internal.is_diffview_tab(tab))
  end)

  it("tab_for_worktree returns nil for invalid (closed) tabs", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()

    diffview._internal.register("/proj/main", tab)

    -- Close the tab
    vim.cmd("tabclose")

    -- Should return nil since the tab is no longer valid
    assert.is_nil(diffview._internal.tab_for_worktree("/proj/main"))
  end)

  it("supports multiple worktrees with separate tabs", function()
    vim.cmd("tabnew")
    local tab1 = vim.api.nvim_get_current_tabpage()

    vim.cmd("tabnew")
    local tab2 = vim.api.nvim_get_current_tabpage()

    diffview._internal.register("/proj/main", tab1)
    diffview._internal.register("/proj/feat", tab2)

    assert.equals(tab1, diffview._internal.tab_for_worktree("/proj/main"))
    assert.equals(tab2, diffview._internal.tab_for_worktree("/proj/feat"))
  end)
end)

------------------------------------------------------------------------
-- Public API: is_diffview_tab (delegates to internal)
------------------------------------------------------------------------

describe("is_diffview_tab (public)", function()
  before_each(cleanup)
  after_each(cleanup)

  it("returns false for the main code tab", function()
    local tab = vim.api.nvim_get_current_tabpage()
    assert.is_false(diffview.is_diffview_tab(tab))
  end)

  it("returns true for a registered diffview tab", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/main", tab)
    assert.is_true(diffview.is_diffview_tab(tab))
  end)
end)

------------------------------------------------------------------------
-- worktree_for_tab
------------------------------------------------------------------------

describe("worktree_for_tab", function()
  before_each(cleanup)
  after_each(cleanup)

  it("returns the worktree dir associated with a diffview tab", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/feat", tab)
    assert.equals("/proj/feat", diffview._internal.worktree_for_tab(tab))
  end)

  it("returns nil for non-diffview tabs", function()
    local tab = vim.api.nvim_get_current_tabpage()
    assert.is_nil(diffview._internal.worktree_for_tab(tab))
  end)
end)

------------------------------------------------------------------------
-- close_for_worktree
------------------------------------------------------------------------

describe("close_for_worktree", function()
  before_each(cleanup)
  after_each(cleanup)

  it("closes the diffview tab for a worktree", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/main", tab)

    local tab_count_before = #vim.api.nvim_list_tabpages()
    diffview.close_for_worktree("/proj/main")

    assert.equals(tab_count_before - 1, #vim.api.nvim_list_tabpages())
    assert.is_nil(diffview._internal.tab_for_worktree("/proj/main"))
  end)

  it("is a no-op when no diffview tab exists for the worktree", function()
    local tab_count_before = #vim.api.nvim_list_tabpages()
    diffview.close_for_worktree("/proj/nonexistent")
    assert.equals(tab_count_before, #vim.api.nvim_list_tabpages())
  end)

  it("does not close other worktree diffview tabs", function()
    vim.cmd("tabnew")
    local tab1 = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/main", tab1)

    vim.cmd("tabnew")
    local tab2 = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/feat", tab2)

    diffview.close_for_worktree("/proj/main")

    assert.is_nil(diffview._internal.tab_for_worktree("/proj/main"))
    assert.equals(tab2, diffview._internal.tab_for_worktree("/proj/feat"))
  end)
end)

------------------------------------------------------------------------
-- has_diffview_tab
------------------------------------------------------------------------

describe("has_diffview_tab", function()
  before_each(cleanup)
  after_each(cleanup)

  it("returns true when a diffview tab exists for the worktree", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/main", tab)
    assert.is_true(diffview.has_diffview_tab("/proj/main"))
  end)

  it("returns false when no diffview tab exists", function()
    assert.is_false(diffview.has_diffview_tab("/proj/main"))
  end)

  it("returns false after tab is closed externally", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/main", tab)
    vim.cmd("tabclose")
    assert.is_false(diffview.has_diffview_tab("/proj/main"))
  end)
end)

------------------------------------------------------------------------
-- Reset (reload contract)
------------------------------------------------------------------------

describe("reset", function()
  before_each(cleanup)
  after_each(cleanup)

  it("clears all tab registrations", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    diffview._internal.register("/proj/main", tab)

    diffview._internal.reset()

    assert.is_nil(diffview._internal.tab_for_worktree("/proj/main"))
    assert.is_false(diffview._internal.is_diffview_tab(tab))
  end)

  it("allows setup to run again after reset", function()
    diffview.setup()
    diffview._internal.reset()
    -- Should not error
    diffview.setup()
    diffview._internal.reset()
  end)

  it("clears the augroup", function()
    diffview.setup()
    diffview._internal.reset()
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_diffview" })
    assert.equals(0, #cmds)
  end)
end)

------------------------------------------------------------------------
-- Setup (idempotent, augroup)
------------------------------------------------------------------------

describe("setup", function()
  before_each(cleanup)
  after_each(cleanup)

  it("creates the neovia_diffview augroup", function()
    diffview.setup()
    local ok, id = pcall(vim.api.nvim_create_augroup, "neovia_diffview", { clear = false })
    assert.is_true(ok)
    assert.is_number(id)
  end)

  it("is idempotent", function()
    diffview.setup()
    local cmds1 = vim.api.nvim_get_autocmds({ group = "neovia_diffview" })
    diffview.setup()
    local cmds2 = vim.api.nvim_get_autocmds({ group = "neovia_diffview" })
    assert.equals(#cmds1, #cmds2)
  end)
end)

------------------------------------------------------------------------
-- current_file
------------------------------------------------------------------------

describe("current_file", function()
  before_each(cleanup)
  after_each(cleanup)

  it("returns nil when diffview.lib is not available", function()
    -- No diffview loaded in test environment, so get_current_view returns nil.
    assert.is_nil(diffview.current_file())
  end)

  it("returns path when panel.cur_file is a table with path", function()
    -- Simulate diffview.lib.get_current_view returning a view
    -- where panel.cur_file is a table (DiffView style).
    local fake_view = {
      panel = { cur_file = { path = "lua/foo.lua" } },
    }
    local result = diffview._internal.extract_current_file(fake_view)
    assert.equals("lua/foo.lua", result)
  end)

  it("returns path when panel.cur_file is a function (FileHistoryView)", function()
    -- FileHistoryView: panel.cur_file is a method that returns an entry.
    local fake_view = {
      panel = {
        cur_file = function(_self) return { path = "lua/bar.lua" } end,
      },
    }
    local result = diffview._internal.extract_current_file(fake_view)
    assert.equals("lua/bar.lua", result)
  end)

  it("returns nil when panel.cur_file function returns nil", function()
    local fake_view = {
      panel = {
        cur_file = function(_self) return nil end,
      },
    }
    local result = diffview._internal.extract_current_file(fake_view)
    assert.is_nil(result)
  end)

  it("returns nil when panel.cur_file function errors", function()
    local fake_view = {
      panel = {
        cur_file = function(_self) error("boom") end,
      },
    }
    local result = diffview._internal.extract_current_file(fake_view)
    assert.is_nil(result)
  end)

  it("returns nil when view has no panel", function()
    local fake_view = {}
    local result = diffview._internal.extract_current_file(fake_view)
    assert.is_nil(result)
  end)

  it("returns nil when entry has no path field", function()
    local fake_view = {
      panel = { cur_file = { name = "no-path" } },
    }
    local result = diffview._internal.extract_current_file(fake_view)
    assert.is_nil(result)
  end)
end)
