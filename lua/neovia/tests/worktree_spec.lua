-- tests/neovia/worktree_spec.lua
-- Unit tests for lua/neovia/worktree.lua

local wt = require("neovia.worktree")
local I = wt._internal

------------------------------------------------------------------------
-- parse_worktree_porcelain
------------------------------------------------------------------------

describe("parse_worktree_porcelain", function()
  it("parses a single worktree", function()
    local output = table.concat({
      "worktree /home/user/project",
      "HEAD abc1234def5678901234567890abcdef12345678",
      "branch refs/heads/main",
      "",
    }, "\n")

    local entries = I.parse_worktree_porcelain(output)

    assert.equals(1, #entries)
    assert.equals("/home/user/project", entries[1].path)
    assert.equals("main", entries[1].branch)
    assert.equals("abc1234", entries[1].head)
    assert.is_false(entries[1].bare)
  end)

  it("parses multiple worktrees", function()
    local output = table.concat({
      "worktree /home/user/project",
      "HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "branch refs/heads/main",
      "",
      "worktree /home/user/project-feat",
      "HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "branch refs/heads/feat/cool-thing",
      "",
    }, "\n")

    local entries = I.parse_worktree_porcelain(output)

    assert.equals(2, #entries)
    assert.equals("main", entries[1].branch)
    assert.equals("/home/user/project-feat", entries[2].path)
    assert.equals("feat/cool-thing", entries[2].branch)
  end)

  it("handles detached HEAD", function()
    local output = table.concat({
      "worktree /home/user/project-detached",
      "HEAD cccccccccccccccccccccccccccccccccccccccc",
      "detached",
      "",
    }, "\n")

    local entries = I.parse_worktree_porcelain(output)

    assert.equals(1, #entries)
    assert.equals("(detached)", entries[1].branch)
  end)

  it("marks bare worktrees", function()
    local output = table.concat({
      "worktree /home/user/project.git",
      "bare",
      "",
    }, "\n")

    local entries = I.parse_worktree_porcelain(output)

    assert.equals(1, #entries)
    assert.is_true(entries[1].bare)
  end)

  it("handles empty input", function()
    local entries = I.parse_worktree_porcelain("")
    assert.equals(0, #entries)
  end)

  it("handles trailing newlines gracefully", function()
    local output = "worktree /a\nHEAD aabbccdd00112233445566778899aabbccddeeff\nbranch refs/heads/dev\n\n\n"
    local entries = I.parse_worktree_porcelain(output)
    assert.equals(1, #entries)
    assert.equals("dev", entries[1].branch)
  end)
end)

------------------------------------------------------------------------
-- apply_event
------------------------------------------------------------------------

describe("apply_event", function()
  local entry

  before_each(function()
    entry = I.make_entry({ status = "unknown" })
  end)

  -- session.idle

  it("session.idle sets status to idle", function()
    entry.status = "responding"
    local changed = I.apply_event(entry, { type = "session.idle", properties = {} })
    assert.is_true(changed)
    assert.equals("idle", entry.status)
  end)

  it("session.idle clears pending permissions", function()
    entry.pending_permissions = { perm1 = true, perm2 = true }
    I.apply_event(entry, { type = "session.idle", properties = {} })
    assert.same({}, entry.pending_permissions)
  end)

  -- message.updated (assistant, responding)

  it("assistant message without time.completed sets responding", function()
    local event = {
      type = "message.updated",
      properties = {
        info = {
          role = "assistant",
          time = { created = 1000 },
        },
      },
    }
    local changed = I.apply_event(entry, event)
    assert.is_true(changed)
    assert.equals("responding", entry.status)
  end)

  -- message.updated (assistant, completed)

  it("assistant message with time.completed sets idle", function()
    entry.status = "responding"
    local event = {
      type = "message.updated",
      properties = {
        info = {
          role = "assistant",
          time = { created = 1000, completed = 2000 },
        },
      },
    }
    local changed = I.apply_event(entry, event)
    assert.is_true(changed)
    assert.equals("idle", entry.status)
  end)

  -- message.updated (user message -- should not change status)

  it("user message does not change status", function()
    entry.status = "idle"
    local event = {
      type = "message.updated",
      properties = {
        info = {
          role = "user",
          time = { created = 1000 },
        },
      },
    }
    local changed = I.apply_event(entry, event)
    assert.is_false(changed)
    assert.equals("idle", entry.status)
  end)

  -- permission.asked

  it("permission.asked sets needs_attention", function()
    entry.status = "responding"
    local event = {
      type = "permission.asked",
      properties = { id = "perm-123" },
    }
    local changed = I.apply_event(entry, event)
    assert.is_true(changed)
    assert.equals("needs_attention", entry.status)
    assert.is_true(entry.pending_permissions["perm-123"])
  end)

  it("permission.asked tracks multiple permission IDs", function()
    I.apply_event(entry, {
      type = "permission.asked",
      properties = { id = "p1" },
    })
    I.apply_event(entry, {
      type = "permission.asked",
      properties = { id = "p2" },
    })
    assert.is_true(entry.pending_permissions["p1"])
    assert.is_true(entry.pending_permissions["p2"])
  end)

  -- permission.replied

  it("permission.replied clears permission and reverts to responding", function()
    entry.status = "needs_attention"
    entry.pending_permissions = { ["perm-123"] = true }

    local event = {
      type = "permission.replied",
      properties = { requestID = "perm-123" },
    }
    local changed = I.apply_event(entry, event)
    assert.is_true(changed)
    assert.equals("responding", entry.status)
    assert.is_nil(entry.pending_permissions["perm-123"])
  end)

  it("permission.replied stays needs_attention when other perms remain", function()
    entry.status = "needs_attention"
    entry.pending_permissions = { ["p1"] = true, ["p2"] = true }

    I.apply_event(entry, {
      type = "permission.replied",
      properties = { requestID = "p1" },
    })
    -- p2 still pending, so tbl_isempty is false -> no status change in that branch
    assert.equals("needs_attention", entry.status)
    assert.is_true(entry.pending_permissions["p2"])
  end)

  -- session.error

  it("session.error sets idle and clears permissions", function()
    entry.status = "responding"
    entry.pending_permissions = { x = true }
    I.apply_event(entry, { type = "session.error", properties = {} })
    assert.equals("idle", entry.status)
    assert.same({}, entry.pending_permissions)
  end)

  -- server.connected

  it("server.connected promotes unknown to idle", function()
    entry.status = "unknown"
    local changed = I.apply_event(entry, { type = "server.connected", properties = {} })
    assert.is_true(changed)
    assert.equals("idle", entry.status)
  end)

  it("server.connected does not overwrite responding", function()
    entry.status = "responding"
    local changed = I.apply_event(entry, { type = "server.connected", properties = {} })
    assert.is_false(changed)
    assert.equals("responding", entry.status)
  end)

  -- unknown event types

  it("unknown event type is a no-op", function()
    entry.status = "idle"
    local changed = I.apply_event(entry, { type = "some.random.event", properties = {} })
    assert.is_false(changed)
    assert.equals("idle", entry.status)
  end)

  -- missing properties

  it("handles missing properties gracefully", function()
    entry.status = "idle"
    local changed = I.apply_event(entry, { type = "session.idle" })
    assert.is_true(changed == false or entry.status == "idle")
  end)
end)

------------------------------------------------------------------------
-- set_status
------------------------------------------------------------------------

describe("set_status", function()
  before_each(function()
    -- Stub redrawstatus to avoid errors in headless mode
    vim.cmd.redrawstatus = function() end
    I.set_state({
      ["/proj/a"] = I.make_entry({ status = "responding", branch = "main" }),
    })
  end)

  after_each(function()
    I.reset()
  end)

  it("updates status for a known directory", function()
    wt.set_status("/proj/a", "idle")
    assert.equals("idle", I.get_state()["/proj/a"].status)
  end)

  it("clears pending permissions when set to idle", function()
    I.get_state()["/proj/a"].pending_permissions = { x = true }
    wt.set_status("/proj/a", "idle")
    assert.same({}, I.get_state()["/proj/a"].pending_permissions)
  end)

  it("is a no-op for unknown directories", function()
    wt.set_status("/nonexistent", "idle")
    assert.is_nil(I.get_state()["/nonexistent"])
  end)
end)

------------------------------------------------------------------------
-- lualine_aggregate (logic via state injection)
------------------------------------------------------------------------

describe("lualine_aggregate", function()
  local orig_setup
  local orig_ensure_hl

  before_each(function()
    -- Bypass setup() and ensure_highlights() side effects in headless mode
    orig_setup = wt.setup
    wt.setup = function() end
    vim.cmd.redrawstatus = function() end
  end)

  after_each(function()
    wt.setup = orig_setup
    I.reset()
  end)

  it("returns empty with zero worktrees", function()
    I.set_state({})
    assert.equals("", wt.lualine_aggregate())
  end)

  it("returns empty with one worktree", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "responding" }),
    })
    assert.equals("", wt.lualine_aggregate())
  end)

  it("returns empty when all idle", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "idle" }),
      ["/b"] = I.make_entry({ status = "idle" }),
    })
    assert.equals("", wt.lualine_aggregate())
  end)

  it("shows working when any is responding", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "idle" }),
      ["/b"] = I.make_entry({ status = "responding" }),
    })
    assert.equals("[wt: working]", wt.lualine_aggregate())
  end)

  it("shows needs_you when any needs attention", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "responding" }),
      ["/b"] = I.make_entry({ status = "needs_attention" }),
    })
    assert.equals("[wt: needs you]", wt.lualine_aggregate())
  end)

  it("needs_attention takes priority over responding", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "responding" }),
      ["/b"] = I.make_entry({ status = "needs_attention" }),
      ["/c"] = I.make_entry({ status = "idle" }),
    })
    assert.equals("[wt: needs you]", wt.lualine_aggregate())
  end)
end)

------------------------------------------------------------------------
-- lualine_current (logic via state injection)
------------------------------------------------------------------------

describe("lualine_current", function()
  local orig_setup

  before_each(function()
    orig_setup = wt.setup
    wt.setup = function() end
    vim.cmd.redrawstatus = function() end
  end)

  after_each(function()
    wt.setup = orig_setup
    I.reset()
  end)

  it("returns empty when cwd has no state entry", function()
    I.set_state({})
    assert.equals("", wt.lualine_current())
  end)

  it("returns [idle] when idle", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "idle" }),
    })
    assert.equals("[idle]", wt.lualine_current())
  end)

  it("returns [idle] when unknown (pre-connection)", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "unknown" }),
    })
    assert.equals("[idle]", wt.lualine_current())
  end)

  it("returns [working] when responding", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "responding" }),
    })
    assert.equals("[working]", wt.lualine_current())
  end)

  it("returns [needs you] when needs_attention", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "needs_attention" }),
    })
    assert.equals("[needs you]", wt.lualine_current())
  end)
end)

------------------------------------------------------------------------
-- Full event sequence scenario
------------------------------------------------------------------------

describe("event sequence scenario", function()
  it("tracks a complete prompt lifecycle", function()
    local entry = I.make_entry({ status = "idle" })

    -- User sends a prompt, assistant starts responding
    I.apply_event(entry, {
      type = "message.updated",
      properties = { info = { role = "assistant", time = { created = 100 } } },
    })
    assert.equals("responding", entry.status)

    -- Assistant needs permission for a file edit
    I.apply_event(entry, {
      type = "permission.asked",
      properties = { id = "perm-1" },
    })
    assert.equals("needs_attention", entry.status)

    -- User approves
    I.apply_event(entry, {
      type = "permission.replied",
      properties = { requestID = "perm-1" },
    })
    assert.equals("responding", entry.status)

    -- Assistant finishes
    I.apply_event(entry, {
      type = "message.updated",
      properties = { info = { role = "assistant", time = { created = 100, completed = 200 } } },
    })
    assert.equals("idle", entry.status)

    -- Session goes idle (belt-and-suspenders)
    I.apply_event(entry, {
      type = "session.idle",
      properties = {},
    })
    assert.equals("idle", entry.status)
  end)

  it("handles error mid-response", function()
    local entry = I.make_entry({ status = "idle" })

    I.apply_event(entry, {
      type = "message.updated",
      properties = { info = { role = "assistant", time = { created = 100 } } },
    })
    assert.equals("responding", entry.status)

    I.apply_event(entry, {
      type = "session.error",
      properties = { sessionID = "s1" },
    })
    assert.equals("idle", entry.status)
  end)
end)
