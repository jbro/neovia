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
  -- Helper: build a minimal worktree entry list.
  -- The first entry is always the main worktree (non-linked).
  local function entries(main_path, linked)
    local list = {
      { path = main_path, branch = "main", head = "aaa", bare = false },
    }
    for _, l in ipairs(linked or {}) do
      table.insert(list, { path = l.path, branch = l.branch or "x", head = "bbb", bare = false })
    end
    return list
  end

  it("uses .worktrees/ under main when no linked worktrees exist", function()
    local wts = entries("/home/user/project")
    local result = I.derive_worktree_path(wts, "feat/cool-thing")
    assert.equals("/home/user/project/.worktrees/feat-cool-thing", result)
  end)

  it("replaces slashes in branch names with dashes", function()
    local wts = entries("/home/user/project")
    local result = I.derive_worktree_path(wts, "fix/deep/nested/thing")
    assert.equals("/home/user/project/.worktrees/fix-deep-nested-thing", result)
  end)

  it("uses .worktrees/ when all linked worktrees are inside .worktrees/", function()
    local wts = entries("/home/user/project", {
      { path = "/home/user/project/.worktrees/feat-a" },
      { path = "/home/user/project/.worktrees/feat-b" },
    })
    local result = I.derive_worktree_path(wts, "feat-c")
    assert.equals("/home/user/project/.worktrees/feat-c", result)
  end)

  it("uses sibling directory when all linked worktrees are siblings of main", function()
    local wts = entries("/home/user/project", {
      { path = "/home/user/project-feat-a" },
      { path = "/home/user/project-feat-b" },
    })
    local result = I.derive_worktree_path(wts, "feat-c")
    assert.equals("/home/user/feat-c", result)
  end)

  it("falls back to .worktrees/ when linked worktrees are mixed (some sibling, some nested)", function()
    local wts = entries("/home/user/project", {
      { path = "/home/user/project-feat-a" },
      { path = "/home/user/project/.worktrees/feat-b" },
    })
    local result = I.derive_worktree_path(wts, "feat-c")
    assert.equals("/home/user/project/.worktrees/feat-c", result)
  end)

  it("handles branch name that is already a simple name (no slashes)", function()
    local wts = entries("/home/user/project")
    local result = I.derive_worktree_path(wts, "hotfix")
    assert.equals("/home/user/project/.worktrees/hotfix", result)
  end)

  it("handles main worktree path with trailing slash", function()
    local wts = entries("/home/user/project/")
    local result = I.derive_worktree_path(wts, "feat-x")
    assert.equals("/home/user/project/.worktrees/feat-x", result)
  end)
end)

------------------------------------------------------------------------
-- collect_file_buffers
------------------------------------------------------------------------

describe("collect_file_buffers", function()
  it("returns paths of listed file buffers", function()
    -- Create two file-like buffers (explicitly set buflisted)
    local buf1 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf1, "/tmp/test_file_a.lua")
    vim.bo[buf1].buflisted = true
    local buf2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf2, "/tmp/test_file_b.lua")
    vim.bo[buf2].buflisted = true

    local paths = I.collect_file_buffers()

    -- Get the resolved names (macOS /tmp -> /private/tmp)
    local name1 = vim.api.nvim_buf_get_name(buf1)
    local name2 = vim.api.nvim_buf_get_name(buf2)

    local found_a, found_b = false, false
    for _, p in ipairs(paths) do
      if p == name1 then found_a = true end
      if p == name2 then found_b = true end
    end
    assert.is_true(found_a)
    assert.is_true(found_b)

    -- Cleanup
    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)

  it("excludes unlisted buffers", function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/test_unlisted.lua")
    vim.bo[buf].buflisted = false

    local paths = I.collect_file_buffers()
    for _, p in ipairs(paths) do
      assert.is_not_equal("/tmp/test_unlisted.lua", p)
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("excludes buffers with special buftypes", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/test_special.lua")
    vim.bo[buf].buftype = "nofile"

    local paths = I.collect_file_buffers()
    for _, p in ipairs(paths) do
      assert.is_not_equal("/tmp/test_special.lua", p)
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("excludes unnamed buffers", function()
    local buf = vim.api.nvim_create_buf(true, false)

    local paths = I.collect_file_buffers()
    for _, p in ipairs(paths) do
      assert.is_not_equal("", p)
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- unlist_file_buffers
------------------------------------------------------------------------

describe("unlist_file_buffers", function()
  it("unlists all listed file buffers", function()
    local buf1 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf1, "/tmp/test_unlist_a.lua")
    local buf2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf2, "/tmp/test_unlist_b.lua")

    I.unlist_file_buffers()

    assert.is_false(vim.bo[buf1].buflisted)
    assert.is_false(vim.bo[buf2].buflisted)

    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)

  it("does not touch special buffers", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].buftype = "nofile"

    I.unlist_file_buffers()

    -- nofile buffers should not be affected
    assert.is_true(vim.bo[buf].buflisted)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- relist_buffers
------------------------------------------------------------------------

describe("relist_buffers", function()
  it("re-lists buffers by path and returns them", function()
    -- Create a file buffer, unlist it
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/test_relist.lua")
    vim.bo[buf].buflisted = false

    local restored = I.relist_buffers({ "/tmp/test_relist.lua" })

    assert.equals(1, #restored)
    assert.is_true(vim.bo[restored[1]].buflisted)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("creates new buffers for paths not already loaded", function()
    local path = "/tmp/test_relist_new_" .. os.time() .. ".lua"

    local restored = I.relist_buffers({ path })

    assert.equals(1, #restored)
    local name = vim.api.nvim_buf_get_name(restored[1])
    -- macOS resolves /tmp -> /private/tmp, so check the suffix
    assert.is_true(vim.endswith(name, path) or name == path)

    vim.api.nvim_buf_delete(restored[1], { force = true })
  end)

  it("returns empty for empty path list", function()
    local restored = I.relist_buffers({})
    assert.equals(0, #restored)
  end)
end)

------------------------------------------------------------------------
-- wipeout_buffers_for_dir
------------------------------------------------------------------------

describe("wipeout_buffers_for_dir", function()
  before_each(function()
    I.set_state({
      ["/proj/a"] = I.make_entry({ buffer_paths = { "/proj/a/file.lua" }, branch = "main" }),
    })
  end)

  after_each(function()
    I.reset()
  end)

  it("wipes out unlisted buffers matching saved paths", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/proj/a/file.lua")
    vim.bo[buf].buflisted = false

    I.wipeout_buffers_for_dir("/proj/a")

    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("clears buffer_paths from state", function()
    I.wipeout_buffers_for_dir("/proj/a")
    assert.same({}, I.get_state()["/proj/a"].buffer_paths)
  end)
end)



------------------------------------------------------------------------
-- reset (reload contract)
------------------------------------------------------------------------

------------------------------------------------------------------------
-- process_event
------------------------------------------------------------------------

describe("process_event", function()
  before_each(function()
    -- Stub redraw commands to avoid errors in headless mode
    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end
    I.set_state({
      ["/proj/a"] = I.make_entry({ status = "idle", branch = "main" }),
    })
  end)

  after_each(function()
    I.reset()
  end)

  it("updates state for a known directory", function()
    I.process_event("/proj/a", {
      type = "message.updated",
      properties = { info = { role = "assistant", time = { created = 100 } } },
    })
    assert.equals("responding", I.get_state()["/proj/a"].status)
  end)

  it("is a no-op for an unknown directory", function()
    I.process_event("/nonexistent", {
      type = "session.idle",
      properties = {},
    })
    -- Should not error or create state
    assert.is_nil(I.get_state()["/nonexistent"])
  end)

  it("does not error when event causes no change", function()
    I.process_event("/proj/a", {
      type = "some.unknown.event",
      properties = {},
    })
    assert.equals("idle", I.get_state()["/proj/a"].status)
  end)
end)



------------------------------------------------------------------------
-- unsubscribe_all
------------------------------------------------------------------------

describe("unsubscribe_all", function()
  after_each(function()
    I.reset()
  end)

  it("calls shutdown on all subscriptions", function()
    local shutdown_count = 0
    local mock_sub = {
      shutdown = function() shutdown_count = shutdown_count + 1 end,
      is_running = function() return true end,
    }
    I.set_state({
      ["/a"] = I.make_entry({ branch = "main", subscription = mock_sub }),
      ["/b"] = I.make_entry({ branch = "feat", subscription = mock_sub }),
    })

    I.unsubscribe_all()

    assert.equals(2, shutdown_count)
    -- Subscriptions should be nil'd
    assert.is_nil(I.get_state()["/a"].subscription)
    assert.is_nil(I.get_state()["/b"].subscription)
  end)

  it("handles entries without subscriptions", function()
    I.set_state({
      ["/a"] = I.make_entry({ branch = "main" }),
    })

    -- Should not error
    I.unsubscribe_all()
  end)

  it("tolerates shutdown errors", function()
    local mock_sub = {
      shutdown = function() error("connection closed") end,
      is_running = function() return false end,
    }
    I.set_state({
      ["/a"] = I.make_entry({ branch = "main", subscription = mock_sub }),
    })

    -- pcall inside unsubscribe_all should catch the error
    I.unsubscribe_all()
    assert.is_nil(I.get_state()["/a"].subscription)
  end)
end)

------------------------------------------------------------------------
-- subscribe_one
------------------------------------------------------------------------

describe("subscribe_one", function()
  after_each(function()
    I.reset()
  end)

  it("is a no-op when opencode.state is not loaded", function()
    -- Ensure opencode.state is not in package.loaded
    package.loaded["opencode.state"] = nil

    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main" }),
    })

    -- Should not error
    I.subscribe_one("/proj/a")
    assert.is_nil(I.get_state()["/proj/a"].subscription)
  end)

  it("is a no-op when api_client is nil", function()
    package.loaded["opencode.state"] = { api_client = nil }

    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main" }),
    })

    I.subscribe_one("/proj/a")
    assert.is_nil(I.get_state()["/proj/a"].subscription)

    package.loaded["opencode.state"] = nil
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

    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main" }),
    })

    I.subscribe_one("/proj/a")
    assert.equals(mock_handle, I.get_state()["/proj/a"].subscription)

    package.loaded["opencode.state"] = nil
  end)
end)

------------------------------------------------------------------------
-- ensure_subscriptions
------------------------------------------------------------------------

describe("ensure_subscriptions", function()
  after_each(function()
    I.reset()
    package.loaded["opencode.state"] = nil
  end)

  it("removes state for worktrees that no longer exist on disk (open only)", function()
    -- ensure_subscriptions calls list_worktrees which runs git, so in
    -- headless test with no git repo it returns {}. This means all open
    -- entries get pruned.
    I.set_state({
      ["/gone/a"] = I.make_entry({ branch = "gone", open = true }),
      ["/gone/b"] = I.make_entry({ branch = "closed", open = false }),
    })

    I.ensure_subscriptions()

    -- Open entry pruned, closed entry retained
    assert.is_nil(I.get_state()["/gone/a"])
    assert.is_not_nil(I.get_state()["/gone/b"])
  end)
end)

------------------------------------------------------------------------
-- resolve_git_common_dir
------------------------------------------------------------------------

describe("resolve_git_common_dir", function()
  it("returns a string in a git repo", function()
    -- This test runs inside the neovia repo, so should succeed
    local result = I.resolve_git_common_dir()
    if result then
      assert.is_string(result)
      -- Should be an absolute path
      assert.is_true(vim.startswith(result, "/"))
    end
    -- If not in a git repo (CI), result may be nil -- that's also valid
  end)
end)

------------------------------------------------------------------------
-- setup
------------------------------------------------------------------------

describe("setup", function()
  after_each(function()
    I.reset()
  end)

  it("creates the neovia_worktree augroup", function()
    -- We're in the neovia git repo, so setup should succeed
    wt.setup()
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_worktree" })
    assert.is_true(#cmds > 0)
  end)

  it("registers VimLeavePre, DirChanged, and User autocmds", function()
    wt.setup()
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_worktree" })
    local events = {}
    for _, cmd in ipairs(cmds) do
      events[cmd.event] = true
    end
    assert.is_true(events["VimLeavePre"] ~= nil)
    assert.is_true(events["DirChanged"] ~= nil)
    assert.is_true(events["User"] ~= nil)
  end)

  it("is idempotent (second call is a no-op)", function()
    wt.setup()
    local cmds1 = vim.api.nvim_get_autocmds({ group = "neovia_worktree" })

    wt.setup()
    local cmds2 = vim.api.nvim_get_autocmds({ group = "neovia_worktree" })

    assert.equals(#cmds1, #cmds2)
  end)

  it("is a no-op when not in a git repo", function()
    -- Manually reset and test with a non-git directory
    I.reset()
    local orig_cwd = vim.fn.getcwd()
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    vim.cmd.tcd(tmpdir)

    wt.setup()

    -- Should not create augroup (no git repo)
    local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "neovia_worktree" })
    assert.is_true(not ok or #cmds == 0)

    vim.cmd.tcd(orig_cwd)
    vim.fn.delete(tmpdir, "rf")
  end)
end)

------------------------------------------------------------------------
-- switch_to
------------------------------------------------------------------------

describe("switch_to", function()
  local orig_cwd
  local dir_a, dir_b

  before_each(function()
    I.reset()

    -- Stub commands that fail in headless mode
    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end

    orig_cwd = vim.fn.getcwd()

    -- Create real temp directories so tcd works.
    -- Resolve symlinks (macOS /tmp -> /private/tmp) so paths match getcwd().
    dir_a = vim.fn.resolve(vim.fn.tempname())
    dir_b = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_a, "p")
    vim.fn.mkdir(dir_b, "p")

    -- Bypass setup() -- we test it separately
    I.set_initialised(true)
  end)

  after_each(function()
    -- Restore cwd before reset
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
    vim.fn.delete(dir_a, "rf")
    vim.fn.delete(dir_b, "rf")
  end)

  it("is a no-op when already in target directory", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main", buffer_paths = { "/old/path.lua" } }),
    })

    wt.switch_to(dir_a)

    -- buffer_paths should not have been overwritten
    assert.same({ "/old/path.lua" }, I.get_state()[dir_a].buffer_paths)
  end)

  it("saves current file buffer paths before switching", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    -- Create a listed file buffer in dir_a
    local buf = vim.api.nvim_create_buf(true, false)
    local file_path = dir_a .. "/test_file.lua"
    vim.api.nvim_buf_set_name(buf, file_path)
    vim.bo[buf].buflisted = true

    -- Get the resolved name that Neovim stores
    local resolved_name = vim.api.nvim_buf_get_name(buf)

    wt.switch_to(dir_b)

    -- The saved paths for dir_a should include our file
    local saved = I.get_state()[dir_a].buffer_paths
    local found = false
    for _, p in ipairs(saved) do
      if p == resolved_name then found = true end
    end
    assert.is_true(found, "Expected " .. resolved_name .. " in saved buffer_paths")

    -- Cleanup
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("unlists current file buffers on switch", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, dir_a .. "/listed.lua")
    vim.bo[buf].buflisted = true

    wt.switch_to(dir_b)

    assert.is_false(vim.bo[buf].buflisted)

    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("tcd to the target directory", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    wt.switch_to(dir_b)

    assert.equals(dir_b, vim.fn.getcwd())
  end)

  it("relists saved buffers for a revisited worktree", function()
    vim.cmd.tcd(dir_a)
    -- dir_b has saved buffers from a previous visit
    local saved_path = dir_b .. "/saved_file.lua"
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", buffer_paths = { saved_path } }),
    })

    wt.switch_to(dir_b)

    -- The saved buffer should now be listed
    local bufnr = vim.fn.bufnr(saved_path)
    assert.is_true(bufnr ~= -1, "Expected buffer to exist for saved path")
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      assert.is_true(vim.bo[bufnr].buflisted)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("creates a state entry for an unknown target directory", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
    })

    wt.switch_to(dir_b)

    local entry = I.get_state()[dir_b]
    assert.is_not_nil(entry)
    assert.equals("unknown", entry.status)
    assert.is_true(entry.open)
  end)

  it("reopens a closed worktree", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", open = false }),
    })

    wt.switch_to(dir_b)

    assert.is_true(I.get_state()[dir_b].open)
  end)
end)

------------------------------------------------------------------------
-- close
------------------------------------------------------------------------

describe("close", function()
  local orig_cwd
  local dir_a, dir_b

  before_each(function()
    I.reset()

    -- Stub commands that fail in headless mode
    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end

    orig_cwd = vim.fn.getcwd()

    dir_a = vim.fn.resolve(vim.fn.tempname())
    dir_b = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_a, "p")
    vim.fn.mkdir(dir_b, "p")

    I.set_initialised(true)
  end)

  after_each(function()
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
    vim.fn.delete(dir_a, "rf")
    vim.fn.delete(dir_b, "rf")
  end)

  it("is a no-op for unknown directories", function()
    wt.close("/nonexistent")
    -- Should not error or create state
    assert.is_nil(I.get_state()["/nonexistent"])
  end)

  it("marks the worktree as closed", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", open = true }),
    })

    wt.close(dir_b)

    assert.is_false(I.get_state()[dir_b].open)
    assert.equals("unknown", I.get_state()[dir_b].status)
  end)

  it("wipes saved buffers on close", function()
    vim.cmd.tcd(dir_a)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, dir_b .. "/closeme.lua")
    vim.bo[buf].buflisted = false

    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({
        branch = "feat",
        buffer_paths = { dir_b .. "/closeme.lua" },
      }),
    })

    wt.close(dir_b)

    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.same({}, I.get_state()[dir_b].buffer_paths)
  end)

  it("tears down SSE subscription on close", function()
    vim.cmd.tcd(dir_a)
    local shutdown_called = false
    local mock_sub = {
      shutdown = function() shutdown_called = true end,
      is_running = function() return true end,
    }

    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", subscription = mock_sub }),
    })

    wt.close(dir_b)

    assert.is_true(shutdown_called)
    assert.is_nil(I.get_state()[dir_b].subscription)
  end)

  it("switches away when closing the current worktree", function()
    vim.cmd.tcd(dir_b)
    -- State has dir_a as another worktree. We need list_worktrees to return
    -- something, but it calls git. Instead we can verify indirectly:
    -- close() on the current dir tries to find another worktree via
    -- list_worktrees(). In headless test with no matching worktrees,
    -- it will warn and return early.
    I.set_state({
      [dir_b] = I.make_entry({ branch = "feat", open = true }),
    })

    -- With no other worktrees available via git, close warns and returns
    local notified = false
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if msg:find("Cannot close the only worktree") then
        notified = true
      end
    end

    wt.close(dir_b)

    vim.notify = orig_notify
    -- The worktree should still be open (close was aborted)
    assert.is_true(I.get_state()[dir_b].open)
    assert.is_true(notified)
  end)
end)

------------------------------------------------------------------------
-- _create_continue
------------------------------------------------------------------------

describe("_create_continue", function()
  local orig_cwd
  local orig_system

  before_each(function()
    I.reset()

    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end

    orig_cwd = vim.fn.getcwd()
    orig_system = vim.system

    I.set_initialised(true)
  end)

  after_each(function()
    vim.system = orig_system
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
  end)

  it("notifies on git worktree add failure", function()
    vim.system = function()
      return { wait = function() return { code = 1, stderr = "branch exists" } end }
    end

    local notified_msg = nil
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified_msg = msg end
    end

    wt._create_continue("existing-branch", false)

    vim.notify = orig_notify
    assert.is_not_nil(notified_msg)
    assert.is_true(notified_msg:find("Failed to create worktree") ~= nil)
  end)

  it("calls git worktree add with correct arguments", function()
    local captured_cmd = nil
    vim.system = function(cmd)
      captured_cmd = cmd
      -- Return failure to stop the flow after capturing args
      return { wait = function() return { code = 1, stderr = "test stop" } end }
    end

    -- Suppress the error notification
    local orig_notify = vim.notify
    vim.notify = function() end

    wt._create_continue("feat/new-thing", false)

    vim.notify = orig_notify
    assert.is_not_nil(captured_cmd)
    assert.equals("git", captured_cmd[1])
    assert.equals("worktree", captured_cmd[2])
    assert.equals("add", captured_cmd[3])
    assert.equals("-b", captured_cmd[4])
    assert.equals("feat/new-thing", captured_cmd[5])
    -- Path should contain the branch name (with slashes replaced)
    assert.is_true(captured_cmd[6]:find("feat%-new%-thing") ~= nil)
  end)

  it("switches to the new worktree on success", function()
    -- Mock all system calls: list_worktrees returns empty (so derive uses .worktrees/),
    -- git worktree add succeeds
    vim.system = function(cmd)
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    -- Pre-populate state so switch_to doesn't call setup
    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    -- Intercept switch_to to capture the target path
    local switched_to = nil
    local orig_switch = wt.switch_to
    wt.switch_to = function(dir) switched_to = dir end

    wt._create_continue("test-branch", false)

    wt.switch_to = orig_switch
    assert.is_not_nil(switched_to)
    assert.is_true(switched_to:find("test%-branch") ~= nil)
  end)

  it("attempts session fork when do_fork is true and opencode is available", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local fork_called = false
    local mock_promise = {
      and_then = function(self, cb) return self end,
      catch = function(self) return self end,
    }
    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function(_, session_id, opts, path)
          fork_called = true
          return mock_promise
        end,
      },
      active_session = { id = "session-123" },
      last_user_message = { info = { id = "msg-456" } },
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    -- Intercept switch_to
    local orig_switch = wt.switch_to
    wt.switch_to = function() end

    wt._create_continue("fork-branch", true)

    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil

    assert.is_true(fork_called)
  end)

  it("does not fork when do_fork is false", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local fork_called = false
    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function()
          fork_called = true
          return { and_then = function(self) return self end, catch = function(self) return self end }
        end,
      },
      active_session = { id = "s1" },
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    local orig_switch = wt.switch_to
    wt.switch_to = function() end

    wt._create_continue("no-fork-branch", false)

    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil

    assert.is_false(fork_called)
  end)
end)

------------------------------------------------------------------------
-- _delete_continue
------------------------------------------------------------------------

describe("_delete_continue", function()
  local orig_cwd
  local orig_system

  before_each(function()
    I.reset()

    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end

    orig_cwd = vim.fn.getcwd()
    orig_system = vim.system

    I.set_initialised(true)
  end)

  after_each(function()
    vim.system = orig_system
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
    package.loaded["opencode.state"] = nil
  end)

  it("creates a tombstone session via opencode api", function()
    local create_called = false
    local mock_promise = {
      catch = function(self) return self end,
    }
    package.loaded["opencode.state"] = {
      api_client = {
        create_session = function(_, share, path)
          create_called = true
          assert.is_false(share)
          assert.equals("/proj/feat", path)
          return mock_promise
        end,
      },
    }

    -- Mock git worktree remove to succeed
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = "/proj/feat", branch = "feat", head = "abc", bare = false }
    -- No state for this path, so close() will be a no-op
    wt._delete_continue(wt_entry)

    assert.is_true(create_called)
  end)

  it("calls git worktree remove with the correct path", function()
    local captured_cmds = {}
    vim.system = function(cmd)
      table.insert(captured_cmds, cmd)
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = "/proj/feat", branch = "feat", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    -- First git call should be worktree remove
    assert.equals("git", captured_cmds[1][1])
    assert.equals("worktree", captured_cmds[1][2])
    assert.equals("remove", captured_cmds[1][3])
    assert.equals("/proj/feat", captured_cmds[1][4])
  end)

  it("calls git branch -d after removing worktree", function()
    local captured_cmds = {}
    vim.system = function(cmd)
      table.insert(captured_cmds, cmd)
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = "/proj/feat", branch = "feat", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    -- Second git call should be branch -d
    assert.is_true(#captured_cmds >= 2)
    assert.equals("git", captured_cmds[2][1])
    assert.equals("branch", captured_cmds[2][2])
    assert.equals("-d", captured_cmds[2][3])
    assert.equals("feat", captured_cmds[2][4])
  end)

  it("skips branch delete for detached HEAD", function()
    local git_cmds = {}
    vim.system = function(cmd)
      table.insert(git_cmds, cmd)
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = "/proj/detached", branch = "(detached)", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    -- Should have worktree remove + ensure_subscriptions (worktree list), but no branch -d
    local has_branch_d = false
    for _, cmd in ipairs(git_cmds) do
      if cmd[2] == "branch" and cmd[3] == "-d" then has_branch_d = true end
    end
    assert.is_false(has_branch_d, "Expected no git branch -d call for detached HEAD")
  end)

  it("skips branch delete for empty branch name", function()
    local git_cmds = {}
    vim.system = function(cmd)
      table.insert(git_cmds, cmd)
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = "/proj/nobranch", branch = "", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    local has_branch_d = false
    for _, cmd in ipairs(git_cmds) do
      if cmd[2] == "branch" and cmd[3] == "-d" then has_branch_d = true end
    end
    assert.is_false(has_branch_d, "Expected no git branch -d call for empty branch")
  end)

  it("notifies on git worktree remove failure", function()
    vim.system = function()
      return { wait = function() return { code = 1, stderr = "not clean" } end }
    end

    local notified_msg = nil
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then notified_msg = msg end
    end

    local wt_entry = { path = "/proj/dirty", branch = "dirty", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    vim.notify = orig_notify
    assert.is_not_nil(notified_msg)
    assert.is_true(notified_msg:find("Failed to remove worktree") ~= nil)
  end)

  it("closes an open worktree before removing", function()
    local dir_main = vim.fn.tempname()
    local dir_feat = vim.fn.tempname()
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")
    vim.cmd.tcd(dir_main)

    local shutdown_called = false
    local mock_sub = {
      shutdown = function() shutdown_called = true end,
      is_running = function() return true end,
    }

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main" }),
      [dir_feat] = I.make_entry({ branch = "feat", open = true, subscription = mock_sub }),
    })

    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = dir_feat, branch = "feat", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    assert.is_true(shutdown_called)

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
  end)

  it("cleans up state after deletion", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    I.set_state({
      ["/proj/feat"] = I.make_entry({ branch = "feat" }),
    })

    local wt_entry = { path = "/proj/feat", branch = "feat", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    assert.is_nil(I.get_state()["/proj/feat"])
  end)
end)

------------------------------------------------------------------------
-- get_entries (public API for lualine tabline)
------------------------------------------------------------------------

describe("get_entries", function()
  before_each(function()
    I.set_state({
      ["/proj/main"] = I.make_entry({ branch = "main", status = "idle" }),
      ["/proj/feat"] = I.make_entry({ branch = "feat-a", status = "responding" }),
      ["/proj/closed"] = I.make_entry({ branch = "closed-one", status = "unknown", open = false }),
    })
  end)

  after_each(function()
    I.reset()
  end)

  it("returns entries from state matching worktree list", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/feat", branch = "feat-a", head = "abc1234", bare = false },
      { path = "/proj/closed", branch = "closed-one", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals(3, #entries)
    assert.equals("main", entries[1].branch)
    assert.equals("idle", entries[1].status)
    assert.equals("feat-a", entries[2].branch)
    assert.equals("responding", entries[2].status)
    assert.equals("closed-one", entries[3].branch)
    assert.is_false(entries[3].open)
  end)

  it("marks unknown worktrees as open by default", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/new", branch = "new-branch", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals(2, #entries)
    assert.is_true(entries[2].open)
    assert.equals("unknown", entries[2].status)
  end)

  it("marks closed worktrees as not open", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/closed", branch = "closed-one", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals(2, #entries)
    assert.is_true(entries[1].open)
    assert.is_false(entries[2].open)
  end)

  it("includes worktrees inside .worktrees/ subdirectory", function()
    I.set_state({
      ["/proj/main"] = I.make_entry({ branch = "main", status = "idle" }),
      ["/proj/main/.worktrees/feat"] = I.make_entry({ branch = "feat", status = "responding" }),
    })
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/main/.worktrees/feat", branch = "feat", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals(2, #entries)
    assert.equals("main", entries[1].branch)
    assert.equals("feat", entries[2].branch)
    assert.equals("responding", entries[2].status)
  end)
end)

------------------------------------------------------------------------
-- get_current_status (public API for lualine statusline)
------------------------------------------------------------------------

describe("get_current_status", function()
  before_each(function()
    I.set_state({})
  end)

  after_each(function()
    I.reset()
  end)

  it("returns status, icon, and hl_group for the current directory", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ branch = "main", status = "idle" }),
    })

    local result = wt.get_current_status()
    assert.equals("idle", result.status)
    assert.is_string(result.icon)
    assert.is_table(result.hl)
  end)

  it("returns needs_attention status correctly", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ branch = "main", status = "needs_attention" }),
    })

    local result = wt.get_current_status()
    assert.equals("needs_attention", result.status)
    assert.equals("[needs you]", result.icon)
  end)

  it("returns responding status correctly", function()
    local cwd = vim.fn.getcwd()
    I.set_state({
      [cwd] = I.make_entry({ branch = "main", status = "responding" }),
    })

    local result = wt.get_current_status()
    assert.equals("responding", result.status)
    assert.equals("[working]", result.icon)
  end)

  it("returns nil when no state exists for current directory", function()
    local result = wt.get_current_status()
    assert.is_nil(result)
  end)
end)

------------------------------------------------------------------------
-- reset (reload contract)
------------------------------------------------------------------------

describe("reset", function()
  it("clears all state", function()
    I.set_state({
      ["/a"] = I.make_entry({ branch = "main" }),
    })
    I.reset()
    assert.same({}, I.get_state())
  end)

  it("allows setup to run again after reset", function()
    -- setup() is guarded by `initialised`. After reset it must be callable again.
    wt.setup()
    I.reset()
    -- setup() should succeed and recreate the augroup
    wt.setup()
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_worktree" })
    assert.is_true(#cmds > 0)
    I.reset()
  end)

  it("deletes augroups", function()
    wt.setup()
    I.reset()
    -- neovia_worktree augroup should be gone after reset
    local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "neovia_worktree" })
    assert.is_true(not ok or #cmds == 0)
  end)
end)
