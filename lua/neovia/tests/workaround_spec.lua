-- tests/neovia/workaround_spec.lua
-- Unit tests for lua/neovia/workaround.lua
-- DELETE THIS FILE when the workaround is removed (see workaround.lua header).

local wa = require("neovia.workaround")

describe("workaround module", function()
  it("exists and returns a table", function()
    assert.is_table(wa)
  end)

  it("exposes maybe_refresh_output", function()
    assert.is_function(wa.maybe_refresh_output)
  end)
end)

------------------------------------------------------------------------
-- maybe_refresh_output
------------------------------------------------------------------------

describe("maybe_refresh_output", function()
  local saved_getcwd

  before_each(function()
    saved_getcwd = vim.fn.getcwd
  end)

  after_each(function()
    vim.fn.getcwd = saved_getcwd
    package.loaded["opencode.ui.ui"] = nil
  end)

  it("calls render_output for message.updated on current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "message.updated")
    assert.is_true(rendered)
  end)

  it("calls render_output for message.part.updated on current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "message.part.updated")
    assert.is_true(rendered)
  end)

  it("calls render_output for permission.asked on current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "permission.asked")
    assert.is_true(rendered)
  end)

  it("calls render_output for question.asked on current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "question.asked")
    assert.is_true(rendered)
  end)

  it("calls render_output for permission.replied on current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "permission.replied")
    assert.is_true(rendered)
  end)

  it("calls render_output for session.idle on current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "session.idle")
    assert.is_true(rendered)
  end)

  it("does NOT call render_output for non-current worktree", function()
    vim.fn.getcwd = function(_, _) return "/proj/b" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "message.updated")
    assert.is_false(rendered)
  end)

  it("does NOT call render_output for irrelevant event types", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output("/proj/a", "server.connected")
    assert.is_false(rendered)

    wa.maybe_refresh_output("/proj/a", "message.part.delta")
    assert.is_false(rendered)
  end)

  it("does NOT call render_output for nil directory", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }

    wa.maybe_refresh_output(nil, "message.updated")
    assert.is_false(rendered)
  end)

  it("tolerates missing opencode.ui.ui module", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    package.loaded["opencode.ui.ui"] = nil

    -- Should not error
    wa.maybe_refresh_output("/proj/a", "message.updated")
  end)

  it("tolerates render_output errors", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    package.loaded["opencode.ui.ui"] = {
      render_output = function() error("render failed") end,
    }

    -- Should not error (pcall protects)
    wa.maybe_refresh_output("/proj/a", "message.updated")
  end)

  it("does NOT call render_output when output window is focused", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    local fake_win = 42
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }
    package.loaded["opencode.state"] = {
      windows = { output_win = fake_win },
    }
    -- Stub nvim_get_current_win to return the output window
    local saved_get_win = vim.api.nvim_get_current_win
    vim.api.nvim_get_current_win = function() return fake_win end

    wa.maybe_refresh_output("/proj/a", "message.updated")
    assert.is_false(rendered)

    vim.api.nvim_get_current_win = saved_get_win
    package.loaded["opencode.state"] = nil
  end)

  it("calls render_output when a different window is focused", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }
    package.loaded["opencode.state"] = {
      windows = { output_win = 42 },
    }
    local saved_get_win = vim.api.nvim_get_current_win
    vim.api.nvim_get_current_win = function() return 99 end

    wa.maybe_refresh_output("/proj/a", "message.updated")
    assert.is_true(rendered)

    vim.api.nvim_get_current_win = saved_get_win
    package.loaded["opencode.state"] = nil
  end)

  it("calls render_output when opencode.state is not loaded", function()
    vim.fn.getcwd = function(_, _) return "/proj/a" end
    local rendered = false
    package.loaded["opencode.ui.ui"] = {
      render_output = function() rendered = true end,
    }
    package.loaded["opencode.state"] = nil

    wa.maybe_refresh_output("/proj/a", "message.updated")
    assert.is_true(rendered)
  end)
end)
