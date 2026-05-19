-- Test suite for opencode event handler session guards.
-- These tests verify that event handlers are wrapped to filter
-- cross-worktree events (events from non-active sessions).
-- This captures the requirement that opencode.nvim's /global/event
-- stream delivers events for all worktrees, but handlers should only
-- process events for the active session AND its child sessions
-- (subagent tasks spawned via the task tool).

local mock_state = {}
local mock_render_state = {}

--- Mock for render_state:get_task_part_by_child_session(session_id).
--- Returns the task part ID if the session is a known child, nil otherwise.
local function mock_get_task_part_by_child_session(session_id)
  if mock_render_state.known_children then
    return mock_render_state.known_children[session_id]
  end
  return nil
end

--- Mirror of the production make_session_guard in lua/plugins/opencode.lua.
--- Must be kept in sync with the real implementation.
--- Allows events from the active session and its child sessions (subagents).
local function make_guarded_handler(orig_handler)
  return function(properties)
    if not properties then return end
    local sid = properties.sessionID
    local active = mock_state.active_session
    if sid and active and active.id ~= sid then
      -- Allow child-session events (subagent tasks) through
      if not mock_get_task_part_by_child_session(sid) then
        return
      end
    end
    return orig_handler(properties)
  end
end

describe("opencode event handler session guards", function()
  before_each(function()
    mock_state = {
      active_session = { id = "session-main" },
    }
  end)

  describe("on_message_removed guard", function()
    it("skips message removal from non-active session", function()
      local called = false
      local removed_id = nil

      local orig = function(properties)
        called = true
        removed_id = properties.messageID
      end

      local guarded = make_guarded_handler(orig)

      guarded({ messageID = "msg-1", sessionID = "session-other" })
      assert.is_false(called)
      assert.is_nil(removed_id)

      guarded({ messageID = "msg-2", sessionID = "session-main" })
      assert.is_true(called)
      assert.equals("msg-2", removed_id)
    end)
  end)

  describe("on_part_removed guard", function()
    it("skips part removal from non-active session", function()
      local called = false
      local removed_part = nil

      local orig = function(properties)
        called = true
        removed_part = properties.partID
      end

      local guarded = make_guarded_handler(orig)

      guarded({ partID = "p-1", sessionID = "session-other" })
      assert.is_false(called)
      assert.is_nil(removed_part)

      guarded({ partID = "p-2", sessionID = "session-main" })
      assert.is_true(called)
      assert.equals("p-2", removed_part)
    end)
  end)

  describe("on_permission_replied guard", function()
    it("skips permission reply from non-active session", function()
      local called = false
      local replied_id = nil

      local orig = function(properties)
        called = true
        replied_id = properties.permissionID or properties.requestID
      end

      local guarded = make_guarded_handler(orig)

      guarded({ permissionID = "perm-1", sessionID = "session-other" })
      assert.is_false(called)
      assert.is_nil(replied_id)

      guarded({ permissionID = "perm-2", sessionID = "session-main" })
      assert.is_true(called)
      assert.equals("perm-2", replied_id)
    end)
  end)

  describe("clear_question_display guard", function()
    it("skips question clear from non-active session", function()
      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ sessionID = "session-other" })
      assert.is_false(called)

      guarded({ sessionID = "session-main" })
      assert.is_true(called)
    end)
  end)

  describe("on_restore_points guard", function()
    it("skips restore point from non-active session", function()
      local called = false
      local appended_point = nil

      local orig = function(properties)
        called = true
        appended_point = properties.restore_point
      end

      local guarded = make_guarded_handler(orig)

      guarded({ restore_point = { id = "rp-1" }, sessionID = "session-other" })
      assert.is_false(called)
      assert.is_nil(appended_point)

      guarded({ restore_point = { id = "rp-2" }, sessionID = "session-main" })
      assert.is_true(called)
      assert.is_truthy(appended_point)
    end)
  end)

  describe("on_session_compacted guard", function()
    it("skips session compacted notification from non-active session", function()
      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ sessionID = "session-other" })
      assert.is_false(called)

      guarded({ sessionID = "session-main" })
      assert.is_true(called)
    end)
  end)

  describe("on_session_error guard", function()
    it("skips session error notification from non-active session", function()
      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ sessionID = "session-other" })
      assert.is_false(called)

      guarded({ sessionID = "session-main" })
      assert.is_true(called)
    end)
  end)

  describe("on_file_edited guard", function()
    it("skips file edited event from non-active session", function()
      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ file = "/file1", sessionID = "session-other" })
      assert.is_false(called)

      guarded({ file = "/file2", sessionID = "session-main" })
      assert.is_true(called)
    end)
  end)

  describe("guard behavior with nil properties", function()
    it("handles nil properties gracefully", function()
      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded(nil)
      assert.is_false(called)
    end)
  end)

  describe("guard behavior with missing sessionID", function()
    it("allows through events without sessionID (system events)", function()
      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      -- Event with no sessionID should be allowed through
      guarded({ someField = "value" })
      assert.is_true(called)
    end)
  end)

  describe("guard allows no-op when no active session", function()
    it("allows through when active_session is nil", function()
      mock_state.active_session = nil

      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ sessionID = "session-any" })
      assert.is_true(called)
    end)
  end)

  describe("subagent (child session) events", function()
    -- Subagent tasks spawn child sessions whose sessionID differs from the
    -- active (parent) session. The guard must allow these through so that
    -- permission and question prompts from subagents are displayed.
    -- opencode.nvim tracks child sessions via render_state's
    -- get_task_part_by_child_session(sessionID), which returns the parent's
    -- task part ID when a child session is known.

    it("allows permission event from a child session known to render_state", function()
      mock_state.active_session = { id = "session-parent" }
      -- Simulate render_state knowing about this child session
      mock_render_state.known_children = { ["session-child-1"] = "task-part-1" }

      local called = false
      local received_props = nil

      local orig = function(properties)
        called = true
        received_props = properties
      end

      local guarded = make_guarded_handler(orig)

      -- Event from child session should be allowed through
      guarded({ permissionID = "perm-sub-1", sessionID = "session-child-1" })
      assert.is_true(called, "permission from child session was incorrectly filtered")
      assert.equals("perm-sub-1", received_props.permissionID)
    end)

    it("allows question event from a child session known to render_state", function()
      mock_state.active_session = { id = "session-parent" }
      mock_render_state.known_children = { ["session-child-1"] = "task-part-1" }

      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ questionID = "q-sub-1", sessionID = "session-child-1" })
      assert.is_true(called, "question from child session was incorrectly filtered")
    end)

    it("still blocks events from unrelated sessions even when children exist", function()
      mock_state.active_session = { id = "session-parent" }
      mock_render_state.known_children = { ["session-child-1"] = "task-part-1" }

      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      -- Event from a completely unrelated session should still be blocked
      guarded({ sessionID = "session-other-worktree" })
      assert.is_false(called, "event from unrelated session should be blocked")
    end)

    it("blocks child-session events when render_state has no children", function()
      mock_state.active_session = { id = "session-parent" }
      mock_render_state.known_children = {}

      local called = false

      local orig = function(properties)
        called = true
      end

      local guarded = make_guarded_handler(orig)

      guarded({ sessionID = "session-unknown-child" })
      assert.is_false(called)
    end)
  end)
end)
