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
-- lualine_current_color
------------------------------------------------------------------------

describe("lualine_current_color", function()
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

  it("returns nil when cwd has no state entry", function()
    I.set_state({})
    assert.is_nil(wt.lualine_current_color())
  end)

  it("returns green fg for idle", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "idle" }),
    })
    assert.same({ fg = I.status_hl.idle.fg }, wt.lualine_current_color())
  end)

  it("returns yellow fg for responding", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "responding" }),
    })
    assert.same({ fg = I.status_hl.responding.fg }, wt.lualine_current_color())
  end)

  it("returns red fg for needs_attention", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ status = "needs_attention" }),
    })
    assert.same({ fg = I.status_hl.needs_attention.fg }, wt.lualine_current_color())
  end)
end)

------------------------------------------------------------------------
-- lualine_aggregate_color
------------------------------------------------------------------------

describe("lualine_aggregate_color", function()
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

  it("returns nil with zero worktrees", function()
    I.set_state({})
    assert.is_nil(wt.lualine_aggregate_color())
  end)

  it("returns nil with one worktree", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "responding" }),
    })
    assert.is_nil(wt.lualine_aggregate_color())
  end)

  it("returns nil when all idle", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "idle" }),
      ["/b"] = I.make_entry({ status = "idle" }),
    })
    assert.is_nil(wt.lualine_aggregate_color())
  end)

  it("returns yellow fg when any is responding", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "idle" }),
      ["/b"] = I.make_entry({ status = "responding" }),
    })
    assert.same({ fg = I.status_hl.responding.fg }, wt.lualine_aggregate_color())
  end)

  it("returns red fg when any needs attention", function()
    I.set_state({
      ["/a"] = I.make_entry({ status = "responding" }),
      ["/b"] = I.make_entry({ status = "needs_attention" }),
    })
    assert.same({ fg = I.status_hl.needs_attention.fg }, wt.lualine_aggregate_color())
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

------------------------------------------------------------------------
-- derive_worktree_path
------------------------------------------------------------------------

describe("derive_worktree_path", function()
  it("returns sibling of main worktree when no linked worktrees exist", function()
    local worktrees = {
      { path = "/home/user/project", branch = "main", head = "abc1234", bare = false },
    }
    local result = I.derive_worktree_path("feature-auth", worktrees)
    assert.equals("/home/user/feature-auth", result)
  end)

  it("follows .worktrees/ convention when existing worktrees are under it", function()
    local worktrees = {
      { path = "/home/user/project", branch = "main", head = "abc1234", bare = false },
      { path = "/home/user/project/.worktrees/feat-a", branch = "feat-a", head = "bbb1234", bare = false },
      { path = "/home/user/project/.worktrees/feat-b", branch = "feat-b", head = "ccc1234", bare = false },
    }
    local result = I.derive_worktree_path("feat-c", worktrees)
    assert.equals("/home/user/project/.worktrees/feat-c", result)
  end)

  it("follows sibling convention when existing worktrees are siblings", function()
    local worktrees = {
      { path = "/home/user/project", branch = "main", head = "abc1234", bare = false },
      { path = "/home/user/feat-a", branch = "feat-a", head = "bbb1234", bare = false },
      { path = "/home/user/feat-b", branch = "feat-b", head = "ccc1234", bare = false },
    }
    local result = I.derive_worktree_path("feat-c", worktrees)
    assert.equals("/home/user/feat-c", result)
  end)

  it("falls back to sibling of main when worktree paths are mixed", function()
    local worktrees = {
      { path = "/home/user/project", branch = "main", head = "abc1234", bare = false },
      { path = "/home/user/project/.worktrees/feat-a", branch = "feat-a", head = "bbb1234", bare = false },
      { path = "/tmp/random/feat-b", branch = "feat-b", head = "ccc1234", bare = false },
    }
    local result = I.derive_worktree_path("feat-c", worktrees)
    assert.equals("/home/user/feat-c", result)
  end)
end)

------------------------------------------------------------------------
-- tab tracking
------------------------------------------------------------------------

describe("tab tracking", function()
  after_each(function()
    I.reset()
  end)

  it("register_tab stores tab-to-dir mapping", function()
    I.register_tab(1, "/home/user/project")
    assert.equals("/home/user/project", I.get_tab_dir(1))
  end)

  it("find_tab_for_dir returns correct tab id", function()
    I.register_tab(1, "/home/user/project")
    I.register_tab(2, "/home/user/feature-x")
    assert.equals(2, I.find_tab_for_dir("/home/user/feature-x"))
  end)

  it("find_tab_for_dir returns nil when no tab matches", function()
    I.register_tab(1, "/home/user/project")
    assert.is_nil(I.find_tab_for_dir("/home/user/unknown"))
  end)

  it("unregister_tab removes the mapping", function()
    I.register_tab(1, "/home/user/project")
    I.unregister_tab(1)
    assert.is_nil(I.get_tab_dir(1))
    assert.is_nil(I.find_tab_for_dir("/home/user/project"))
  end)
end)

------------------------------------------------------------------------
-- parse_create_result
------------------------------------------------------------------------

describe("parse_create_result", function()
  it("returns ok on success", function()
    local result = I.parse_create_result(0, "", "feat-x", {})
    assert.equals("ok", result.status)
  end)

  it("returns branch_exists when branch already exists", function()
    local stderr = "fatal: a branch named 'feat-x' already exists"
    local result = I.parse_create_result(128, stderr, "feat-x", {})
    assert.equals("branch_exists", result.status)
  end)

  it("returns branch_exists with worktree path when worktree already exists for that branch", function()
    local stderr = "fatal: a branch named 'feat-x' already exists"
    local worktrees = {
      { path = "/home/user/project", branch = "main", head = "abc1234", bare = false },
      { path = "/home/user/feat-x", branch = "feat-x", head = "bbb1234", bare = false },
    }
    local result = I.parse_create_result(128, stderr, "feat-x", worktrees)
    assert.equals("branch_exists", result.status)
    assert.equals("/home/user/feat-x", result.existing_worktree)
  end)

  it("returns error for other failures", function()
    local stderr = "fatal: something else went wrong"
    local result = I.parse_create_result(128, stderr, "feat-x", {})
    assert.equals("error", result.status)
    assert.equals(stderr, result.message)
  end)
end)

------------------------------------------------------------------------
-- parse_delete_result
------------------------------------------------------------------------

describe("parse_delete_result", function()
  it("returns ok on success", function()
    local result = I.parse_delete_result(0, "")
    assert.equals("ok", result.status)
  end)

  it("returns dirty when worktree has modifications", function()
    local stderr = "fatal: '/home/user/feat-x' contains modified or untracked files, use --force to delete it"
    local result = I.parse_delete_result(128, stderr)
    assert.equals("dirty", result.status)
  end)

  it("returns error for other failures", function()
    local stderr = "fatal: something unexpected"
    local result = I.parse_delete_result(128, stderr)
    assert.equals("error", result.status)
    assert.equals(stderr, result.message)
  end)
end)

------------------------------------------------------------------------
-- parse_branch_delete_result
------------------------------------------------------------------------

describe("parse_branch_delete_result", function()
  it("returns ok on success", function()
    local result = I.parse_branch_delete_result(0, "")
    assert.equals("ok", result.status)
  end)

  it("returns not_merged when branch is not fully merged", function()
    local stderr = "error: the branch 'feat-x' is not fully merged"
    local result = I.parse_branch_delete_result(1, stderr)
    assert.equals("not_merged", result.status)
  end)

  it("returns error for other failures", function()
    local stderr = "error: branch 'feat-x' not found"
    local result = I.parse_branch_delete_result(1, stderr)
    assert.equals("error", result.status)
    assert.equals(stderr, result.message)
  end)
end)
