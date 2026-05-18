-- Test suite for opencode event handler session guards.
-- These tests verify that event handlers are wrapped to filter
-- cross-worktree events (events from non-active sessions).
-- This captures the requirement that opencode.nvim's /global/event
-- stream delivers events for all worktrees, but handlers should only
-- process events for the active session.

local mock_state = {}

local function make_guarded_handler(orig_handler)
  return function(properties)
    if not properties then return end
    local sid = properties.sessionID
    local active = mock_state.active_session
    if sid and active and active.id ~= sid then return end
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
end)
