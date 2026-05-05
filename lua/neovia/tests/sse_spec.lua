-- tests/neovia/sse_spec.lua
-- Unit tests for lua/neovia/sse.lua

local sse = require("neovia.sse")

describe("sse module", function()
  it("exists and returns a table", function()
    assert.is_table(sse)
  end)
end)

--- Helper: make a fresh state entry.
local function make_entry(overrides)
  return vim.tbl_extend("force", {
    status = "unknown",
    branch = "main",
    pending_permissions = {},
    buffer_paths = {},
    subscription = nil,
    session_id = nil,
  }, overrides or {})
end

------------------------------------------------------------------------
-- unsubscribe_all
------------------------------------------------------------------------

describe("unsubscribe_all", function()
  it("calls shutdown on all subscriptions", function()
    local shutdown_count = 0
    local mock_sub = {
      shutdown = function() shutdown_count = shutdown_count + 1 end,
      is_running = function() return true end,
    }
    local state = {
      ["/a"] = make_entry({ branch = "main", subscription = mock_sub }),
      ["/b"] = make_entry({ branch = "feat", subscription = mock_sub }),
    }

    sse.unsubscribe_all(state)

    assert.equals(2, shutdown_count)
    assert.is_nil(state["/a"].subscription)
    assert.is_nil(state["/b"].subscription)
  end)

  it("handles entries without subscriptions", function()
    local state = { ["/a"] = make_entry({ branch = "main" }) }
    sse.unsubscribe_all(state)
  end)

  it("tolerates shutdown errors", function()
    local mock_sub = {
      shutdown = function() error("connection closed") end,
      is_running = function() return false end,
    }
    local state = { ["/a"] = make_entry({ branch = "main", subscription = mock_sub }) }
    sse.unsubscribe_all(state)
    assert.is_nil(state["/a"].subscription)
  end)
end)

------------------------------------------------------------------------
-- subscribe_one
------------------------------------------------------------------------

describe("subscribe_one", function()
  after_each(function()
    package.loaded["opencode.state"] = nil
  end)

  it("is a no-op when opencode.state is not loaded", function()
    package.loaded["opencode.state"] = nil
    local state = { ["/proj/a"] = make_entry({ branch = "main" }) }
    sse.subscribe_one(state, "/proj/a", function() end)
    assert.is_nil(state["/proj/a"].subscription)
  end)

  it("is a no-op when api_client is nil", function()
    package.loaded["opencode.state"] = { api_client = nil }
    local state = { ["/proj/a"] = make_entry({ branch = "main" }) }
    sse.subscribe_one(state, "/proj/a", function() end)
    assert.is_nil(state["/proj/a"].subscription)
  end)

  it("subscribes and stores the handle in state", function()
    local mock_handle = {
      shutdown = function() end,
      is_running = function() return true end,
    }
    package.loaded["opencode.state"] = {
      api_client = {
        subscribe_to_events = function(_, _, _)
          return mock_handle
        end,
      },
    }
    local state = { ["/proj/a"] = make_entry({ branch = "main" }) }
    sse.subscribe_one(state, "/proj/a", function() end)
    assert.equals(mock_handle, state["/proj/a"].subscription)
  end)
end)

------------------------------------------------------------------------
-- process_event
------------------------------------------------------------------------

describe("process_event", function()
  before_each(function()
    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end
  end)

  it("calls the event callback and triggers redraw on change", function()
    local state = {
      ["/proj/a"] = make_entry({ status = "idle", branch = "main" }),
    }
    local callback_called = false
    local function on_event(entry, event)
      callback_called = true
      entry.status = "responding"
      return true  -- changed
    end

    sse.process_event(state, "/proj/a", { type = "test" }, on_event)
    assert.is_true(callback_called)
    assert.equals("responding", state["/proj/a"].status)
  end)

  it("is a no-op for unknown directories", function()
    local state = {}
    sse.process_event(state, "/nonexistent", { type = "test" }, function() end)
    assert.is_nil(state["/nonexistent"])
  end)

  it("triggers magic-context refresh on completed assistant message", function()
    local state = {
      ["/proj/a"] = make_entry({ status = "responding", branch = "main" }),
    }
    -- Spy on magic_context.refresh
    local refresh_called = false
    local mc = require("neovia.magic_context")
    local orig_refresh = mc.refresh
    mc.refresh = function() refresh_called = true end

    sse.process_event(state, "/proj/a", {
      type = "message.updated",
      properties = {
        info = {
          role = "assistant",
          time = { created = 1000, completed = 2000 },
        },
      },
    }, function() return false end)

    assert.is_true(refresh_called,
      "mc.refresh() should be called on completed assistant message")
    mc.refresh = orig_refresh
  end)

  it("triggers magic-context refresh on session.idle", function()
    local state = {
      ["/proj/a"] = make_entry({ status = "responding", branch = "main" }),
    }
    local refresh_called = false
    local mc = require("neovia.magic_context")
    local orig_refresh = mc.refresh
    mc.refresh = function() refresh_called = true end

    sse.process_event(state, "/proj/a", {
      type = "session.idle",
      properties = {},
    }, function() return false end)

    assert.is_true(refresh_called,
      "mc.refresh() should be called on session.idle")
    mc.refresh = orig_refresh
  end)

  it("does not trigger magic-context refresh on unrelated events", function()
    local state = {
      ["/proj/a"] = make_entry({ status = "idle", branch = "main" }),
    }
    local refresh_called = false
    local mc = require("neovia.magic_context")
    local orig_refresh = mc.refresh
    mc.refresh = function() refresh_called = true end

    sse.process_event(state, "/proj/a", {
      type = "permission.asked",
      properties = { id = "perm_1" },
    }, function() return false end)

    assert.is_false(refresh_called,
      "mc.refresh() should not be called on permission.asked")
    mc.refresh = orig_refresh
  end)
end)
