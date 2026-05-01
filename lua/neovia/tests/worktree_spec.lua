-- tests/neovia/worktree_spec.lua
-- Unit tests for lua/neovia/worktree.lua

-- Ensure vim.ui is available (not loadable in nvim -l test runner).
-- Use rawset to bypass vim's __newindex metamethod.
if not pcall(require, "vim.ui") then
  rawset(vim, "ui", {
    input = function(_, cb) cb(nil) end,
    select = function(_, _, cb) cb(nil) end,
  })
end

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

  it("permission.replied with permissionID clears permission and reverts to responding", function()
    entry.status = "needs_attention"
    entry.pending_permissions = { ["perm-456"] = true }

    local event = {
      type = "permission.replied",
      properties = { permissionID = "perm-456" },
    }
    local changed = I.apply_event(entry, event)
    assert.is_true(changed)
    assert.equals("responding", entry.status)
    assert.is_nil(entry.pending_permissions["perm-456"])
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

  -- question.asked

  it("question.asked sets needs_attention", function()
    entry.status = "responding"
    local changed = I.apply_event(entry, {
      type = "question.asked",
      properties = { id = "q-1", questions = {} },
    })
    assert.is_true(changed)
    assert.equals("needs_attention", entry.status)
  end)

  -- question.replied

  it("question.replied reverts to responding", function()
    entry.status = "needs_attention"
    local changed = I.apply_event(entry, {
      type = "question.replied",
      properties = { id = "q-1" },
    })
    assert.is_true(changed)
    assert.equals("responding", entry.status)
  end)

  -- question.rejected

  it("question.rejected reverts to responding", function()
    entry.status = "needs_attention"
    local changed = I.apply_event(entry, {
      type = "question.rejected",
      properties = { id = "q-1" },
    })
    assert.is_true(changed)
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

  it("tracks lifecycle when permission.replied uses permissionID field", function()
    local entry = I.make_entry({ status = "idle" })

    -- Assistant starts responding
    I.apply_event(entry, {
      type = "message.updated",
      properties = { info = { role = "assistant", time = { created = 100 } } },
    })
    assert.equals("responding", entry.status)

    -- Permission asked with id
    I.apply_event(entry, {
      type = "permission.asked",
      properties = { id = "perm-abc" },
    })
    assert.equals("needs_attention", entry.status)

    -- Permission replied using permissionID (not requestID)
    I.apply_event(entry, {
      type = "permission.replied",
      properties = { permissionID = "perm-abc" },
    })
    assert.equals("responding", entry.status)
    assert.same({}, entry.pending_permissions)
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

  it("excludes notes buffers", function()
    local notes = require("neovia.notes")
    local test_cache_dir = vim.fn.tempname() .. "_wt_collect_test"
    notes._internal.reset()
    notes.setup({ cache_dir = test_cache_dir })

    local notes_buf = notes.get_or_create("/tmp/wt_collect")
    assert.is_false(vim.bo[notes_buf].buflisted, "notes buffers are unlisted")

    local paths = I.collect_file_buffers()
    local notes_name = vim.api.nvim_buf_get_name(notes_buf)
    for _, p in ipairs(paths) do
      assert.is_not_equal(notes_name, p)
    end

    notes._internal.reset()
    vim.fn.delete(test_cache_dir, "rf")
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

  it("stops treesitter on buffers before unlisting (fold race workaround)", function()
    local ok_ts, ts = pcall(require, "vim.treesitter")
    if not ok_ts then return pending("vim.treesitter unavailable in test runner") end

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/test_unlist_ts.lua")
    -- Seed buffer with valid Lua so treesitter can parse it.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1" })
    ts.start(buf, "lua")
    -- Sanity: highlighter should be active before unlist.
    assert.is_truthy(ts.highlighter.active[buf])

    I.unlist_file_buffers()

    assert.is_false(vim.bo[buf].buflisted)
    -- After unlist, treesitter highlighter should have been stopped.
    assert.is_falsy(ts.highlighter.active[buf])

    vim.api.nvim_buf_delete(buf, { force = true })
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

  it("removes state for worktrees that no longer exist on disk", function()
    -- ensure_subscriptions calls list_worktrees which runs git, so in
    -- headless test with no git repo it returns {}. This means all
    -- entries get pruned.
    I.set_state({
      ["/gone/a"] = I.make_entry({ branch = "gone" }),
      ["/gone/b"] = I.make_entry({ branch = "also-gone" }),
    })

    I.ensure_subscriptions()

    assert.is_nil(I.get_state()["/gone/a"])
    assert.is_nil(I.get_state()["/gone/b"])
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
  end)

  it("schedules layout restoration after switching", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    local layout_restored = false
    local orig_restore = require("neovia.layout").restore_layout
    require("neovia.layout").restore_layout = function()
      layout_restored = true
    end

    -- Mock ensure_layout instead since restore_layout is too aggressive
    local layout_ensured = false
    local layout_internal = require("neovia.layout")._internal
    local orig_ensure = layout_internal.ensure_layout
    layout_internal.ensure_layout = function()
      layout_ensured = true
    end

    wt.switch_to(dir_b)

    -- ensure_layout should be deferred; flush pending callbacks
    vim.wait(200, function() return layout_ensured end)

    require("neovia.layout").restore_layout = orig_restore
    layout_internal.ensure_layout = orig_ensure

    assert.is_true(layout_ensured, "Expected layout check to be scheduled after switch")
  end)

  it("leaves noname buffer in code window on first visit", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", buffer_paths = {} }),
    })

    -- Create a code window
    local code_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, code_buf)

    wt.switch_to(dir_b)

    -- The code window should still be there (noname or original buffer)
    local navigate = require("neovia.navigate")
    local code_win = navigate.find_code_win()
    assert.is_not_nil(code_win, "code window should exist after first visit")

    pcall(vim.api.nvim_buf_delete, code_buf, { force = true })
  end)

  it("tells neo-tree the new root after switching", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    local neotree_dir_cmd = nil
    local orig_cmd = vim.cmd
    local mt = getmetatable(vim.cmd) or {}
    -- Wrap vim.cmd to capture the Neotree dir= call specifically
    vim.cmd = setmetatable({}, {
      __call = function(_, c)
        if type(c) == "string" and c:find("Neotree") and c:find("dir=") then
          neotree_dir_cmd = c
        end
        -- Always delegate so ensure_layout etc. still work
        orig_cmd(c)
      end,
      __index = function(_, k)
        return mt.__index and mt.__index(vim.cmd, k) or rawget(orig_cmd, k)
      end,
    })

    wt.switch_to(dir_b)

    -- Neotree dir= is deferred via vim.schedule; flush pending callbacks
    -- (keep the wrapper active during the wait so the scheduled call is captured)
    vim.wait(200, function() return neotree_dir_cmd ~= nil end)

    -- Restore vim.cmd before assertions so cleanup works
    vim.cmd = orig_cmd

    assert.is_truthy(neotree_dir_cmd, "expected a Neotree dir= command after switch")
    assert.is_truthy(neotree_dir_cmd:find("dir="), "expected Neotree dir= argument")
  end)

  it("clears neo-tree git status for target worktree before navigating", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    -- Mock neo-tree.git module with a worktree entry that has cached status
    local fake_neo_git = {
      worktrees = {
        [dir_b] = {
          status = { ["some/file.lua"] = "M" },
          git_dir = dir_b .. "/.git",
        },
      },
      _upward_worktree_cache = {},
    }
    package.loaded["neo-tree.git"] = fake_neo_git

    wt.switch_to(dir_b)

    -- The vim.schedule callback needs to run
    vim.wait(200, function()
      return fake_neo_git.worktrees[dir_b].status == nil
    end)

    assert.is_nil(fake_neo_git.worktrees[dir_b].status,
      "git status should be cleared for target worktree before Neotree dir=")

    package.loaded["neo-tree.git"] = nil
  end)

  it("does not include notes buffer in saved buffer_paths", function()
    local notes = require("neovia.notes")
    local test_cache_dir = vim.fn.tempname() .. "_wt_switch_paths_test"
    notes._internal.reset()
    notes.setup({ cache_dir = test_cache_dir })

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    -- Create a notes buffer for dir_a AND a normal file buffer
    local notes_buf = notes.get_or_create(dir_a)
    local file_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file_buf, dir_a .. "/real_file.lua")
    vim.bo[file_buf].buflisted = true

    wt.switch_to(dir_b)

    -- Saved paths for dir_a should contain the file but not the notes
    local saved = I.get_state()[dir_a].buffer_paths
    local file_name = vim.api.nvim_buf_get_name(file_buf)
    local notes_name = vim.api.nvim_buf_get_name(notes_buf)
    local found_file, found_notes = false, false
    for _, p in ipairs(saved) do
      if p == file_name then found_file = true end
      if p == notes_name then found_notes = true end
    end
    assert.is_true(found_file, "Expected real file in saved buffer_paths")
    assert.is_false(found_notes, "Notes buffer should not be in saved buffer_paths")

    pcall(vim.api.nvim_buf_delete, file_buf, { force = true })
    notes._internal.reset()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("saves neo-tree expanded nodes before switching away", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    -- Stub neo-tree renderer to return fake expanded nodes
    local fake_expanded = { dir_a .. "/src", dir_a .. "/src/lib" }
    local fake_tree = {}
    package.loaded["neo-tree.ui.renderer"] = {
      get_expanded_nodes = function() return fake_expanded end,
    }
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function() return { tree = fake_tree } end,
    }

    wt.switch_to(dir_b)

    local saved = I.get_state()[dir_a].neo_tree_expanded
    assert.is_not_nil(saved, "expected neo_tree_expanded to be saved")
    assert.same(fake_expanded, saved)

    -- Cleanup stubs
    package.loaded["neo-tree.ui.renderer"] = nil
    package.loaded["neo-tree.sources.manager"] = nil
  end)

  it("restores neo-tree expanded nodes via force_open_folders after switching back", function()
    vim.cmd.tcd(dir_a)

    -- Pre-populate saved expanded state for dir_b
    local saved_expanded = { dir_b .. "/src", dir_b .. "/src/lib" }
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({
        branch = "feat",
        neo_tree_expanded = saved_expanded,
      }),
    })

    -- Stub neo-tree modules: track what force_open_folders is set to
    local captured_force_open = nil
    package.loaded["neo-tree.ui.renderer"] = {
      get_expanded_nodes = function() return {} end,
    }
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function()
        return {
          tree = {},
          force_open_folders = captured_force_open,
        }
      end,
    }

    -- Capture the state assignment via the manager stub
    local real_manager_get_state = package.loaded["neo-tree.sources.manager"].get_state
    local neo_tree_state = { tree = {} }
    package.loaded["neo-tree.sources.manager"].get_state = function()
      return neo_tree_state
    end

    wt.switch_to(dir_b)

    -- The deferred vim.schedule callback sets force_open_folders; flush it
    vim.wait(200, function() return neo_tree_state.force_open_folders ~= nil end)

    assert.is_not_nil(neo_tree_state.force_open_folders,
      "expected force_open_folders to be set on neo-tree state")
    assert.same(saved_expanded, neo_tree_state.force_open_folders)

    -- Cleanup stubs
    package.loaded["neo-tree.ui.renderer"] = nil
    package.loaded["neo-tree.sources.manager"] = nil
  end)

  it("does not set force_open_folders when no expanded state is saved", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    -- Stub neo-tree modules
    package.loaded["neo-tree.ui.renderer"] = {
      get_expanded_nodes = function() return {} end,
    }
    local neo_tree_state = { tree = {} }
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function() return neo_tree_state end,
    }

    wt.switch_to(dir_b)

    -- Flush scheduled callbacks
    vim.wait(200, function() return false end)

    assert.is_nil(neo_tree_state.force_open_folders,
      "force_open_folders should not be set when there is no saved state")

    -- Cleanup stubs
    package.loaded["neo-tree.ui.renderer"] = nil
    package.loaded["neo-tree.sources.manager"] = nil
  end)

  it("jumps to the target worktree's diffview tab when last_view is diff", function()
    local dv = require("neovia.diffview")
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", last_view = "diff" }),
    })

    -- Create a diffview tab for dir_b
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register(dir_b, dv_tab)
    -- Go back to the first tab
    vim.cmd("tabfirst")

    wt.switch_to(dir_b)

    -- Should be on the diffview tab now
    assert.equals(dv_tab, vim.api.nvim_get_current_tabpage(),
      "should land on the diffview tab when last_view is diff")

    -- Cleanup
    vim.cmd("tabfirst")
    pcall(vim.cmd.tcd, orig_cwd)
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tablast | tabclose")
    end
    dv._internal.reset()
  end)

  it("stays on code tab when target has no diffview tab even if last_view is diff", function()
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", last_view = "diff" }),
    })

    local code_tab = vim.api.nvim_get_current_tabpage()

    wt.switch_to(dir_b)

    assert.equals(code_tab, vim.api.nvim_get_current_tabpage(),
      "should stay on code tab when no diffview tab exists")
  end)

  it("saves last_view as diff when switching away from a diffview tab", function()
    local dv = require("neovia.diffview")
    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    -- Create and register a diffview tab for dir_a, and make it current
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register(dir_a, dv_tab)
    -- We're now on the diffview tab for dir_a

    wt.switch_to(dir_b)

    -- dir_a's last_view should be "diff"
    assert.equals("diff", I.get_state()[dir_a].last_view,
      "should save last_view as diff when switching away from diffview tab")

    -- Cleanup
    vim.cmd("tabfirst")
    pcall(vim.cmd.tcd, orig_cwd)
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tablast | tabclose")
    end
    dv._internal.reset()
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
    -- No start_point arg when none provided
    assert.is_nil(captured_cmd[7])
  end)

  it("passes start_point to git worktree add when provided", function()
    local captured_cmd = nil
    vim.system = function(cmd)
      captured_cmd = cmd
      return { wait = function() return { code = 1, stderr = "test stop" } end }
    end

    local orig_notify = vim.notify
    vim.notify = function() end

    wt._create_continue("feat/from-other", false, "other-branch")

    vim.notify = orig_notify
    assert.is_not_nil(captured_cmd)
    assert.equals("git", captured_cmd[1])
    assert.equals("worktree", captured_cmd[2])
    assert.equals("add", captured_cmd[3])
    assert.equals("-b", captured_cmd[4])
    assert.equals("feat/from-other", captured_cmd[5])
    -- Path at [6]
    assert.is_true(captured_cmd[6]:find("feat%-from%-other") ~= nil)
    -- start_point at [7]
    assert.equals("other-branch", captured_cmd[7])
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

  it("sends empty JSON object as fork_data", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local captured_fork_data = nil
    local mock_promise = {
      and_then = function(self, cb) return self end,
      catch = function(self) return self end,
    }
    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function(_, session_id, fork_data, path)
          captured_fork_data = fork_data
          return mock_promise
        end,
      },
      active_session = { id = "s1" },
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    local orig_switch = wt.switch_to
    wt.switch_to = function() end

    wt._create_continue("fork-empty-body", true)

    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil

    -- Must encode to "{}" (object) not "[]" (array) for the server.
    assert.is_not_nil(captured_fork_data,
      "fork_data must not be nil")
    assert.equals("{}", vim.json.encode(captured_fork_data),
      "fork_data should encode to an empty JSON object")
  end)

  it("switches to new worktree only after fork completes", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local switch_called = false

    -- Build a mock promise that captures the and_then callback
    local captured_then_cb = nil
    local mock_promise = {}
    mock_promise.and_then = function(self, cb)
      captured_then_cb = cb
      return self
    end
    mock_promise.catch = function(self) return self end

    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function()
          return mock_promise
        end,
      },
      active_session = { id = "s1" },
      last_user_message = { info = { id = "m1" } },
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    -- Intercept switch_to to track when it's called
    local orig_switch = wt.switch_to
    wt.switch_to = function(dir)
      switch_called = true
    end

    wt._create_continue("fork-wait-branch", true)

    -- switch_to should NOT have been called yet (fork hasn't resolved)
    assert.is_false(switch_called, "switch_to should not be called before fork resolves")

    -- The and_then callback should have been captured (fork is deferred)
    assert.is_not_nil(captured_then_cb, "fork_session and_then callback should be registered")

    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil
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

  it("activates the forked session via core.switch_session after switching", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    -- Make vim.schedule run callbacks synchronously for this test
    local orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    -- Capture the and_then callback so we can invoke it manually
    local captured_then_cb = nil
    local mock_promise = {}
    mock_promise.and_then = function(self, cb)
      captured_then_cb = cb
      return self
    end
    mock_promise.catch = function(self) return self end

    -- Track set_current_cwd calls
    local cwd_set_to = nil
    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function()
          return mock_promise
        end,
      },
      active_session = { id = "s1" },
      last_user_message = { info = { id = "m1" } },
      context = {
        set_current_cwd = function(path)
          cwd_set_to = path
        end,
      },
    }

    -- Mock core.switch_session to capture calls
    local switch_session_id = nil
    package.loaded["opencode.core"] = {
      switch_session = function(session_id)
        switch_session_id = session_id
      end,
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    -- Track ordering: set_current_cwd must be called before switch_to
    local call_order = {}
    local oc_state_ref = package.loaded["opencode.state"]
    local orig_set_cwd = oc_state_ref.context.set_current_cwd
    oc_state_ref.context.set_current_cwd = function(path)
      table.insert(call_order, "set_current_cwd")
      orig_set_cwd(path)
    end

    local orig_switch = wt.switch_to
    wt.switch_to = function()
      table.insert(call_order, "switch_to")
    end

    wt._create_continue("fork-activate-branch", true)

    assert.is_not_nil(captured_then_cb, "and_then callback should be registered")

    -- Simulate the fork completing with a session ID.
    -- vim.schedule is mocked to run synchronously above.
    captured_then_cb({ id = "forked-session-42" })

    -- set_current_cwd must be called before switch_to to prevent the
    -- DirChanged autocmd from triggering handle_directory_change
    assert.same({ "set_current_cwd", "switch_to" }, call_order,
      "set_current_cwd must be called before switch_to")
    assert.is_truthy(cwd_set_to and cwd_set_to:find("fork%-activate%-branch"),
      "set_current_cwd should receive the new worktree path")
    assert.equals("forked-session-42", switch_session_id,
      "core.switch_session should be called with the forked session ID")

    vim.schedule = orig_schedule
    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil
    package.loaded["opencode.core"] = nil
  end)

  it("passes start_point through to fork_session path argument", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local captured_fork_path = nil
    local mock_promise = {
      and_then = function(self, cb) return self end,
      catch = function(self) return self end,
    }
    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function(_, session_id, opts, path)
          captured_fork_path = path
          return mock_promise
        end,
      },
      active_session = { id = "s1" },
      last_user_message = { info = { id = "m1" } },
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    local orig_switch = wt.switch_to
    wt.switch_to = function() end

    wt._create_continue("fork-from-other", true, "other-branch")

    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil

    -- fork_session receives the new worktree path, not the start_point
    assert.is_not_nil(captured_fork_path)
    assert.is_truthy(captured_fork_path:find("fork%-from%-other"))
  end)

  it("forks the active session", function()
    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local forked_session_id = nil
    local fork_promise = {
      and_then = function(self, cb) return self end,
      catch = function(self) return self end,
    }
    package.loaded["opencode.state"] = {
      api_client = {
        fork_session = function(_, session_id)
          forked_session_id = session_id
          return fork_promise
        end,
      },
      active_session = { id = "current-session-1" },
    }

    I.set_state({
      [orig_cwd] = I.make_entry({ branch = "main" }),
    })

    local orig_switch = wt.switch_to
    wt.switch_to = function() end

    wt._create_continue("fork-current", true)

    wt.switch_to = orig_switch
    package.loaded["opencode.state"] = nil

    assert.equals("current-session-1", forked_session_id,
      "fork_session should use the current active session")
  end)
end)

------------------------------------------------------------------------
-- create / create_from (public API existence)
------------------------------------------------------------------------

describe("create", function()
  local orig_list, orig_continue, orig_input

  before_each(function()
    I.reset()
    I.set_initialised(true)
    orig_list = I.list_worktrees
    orig_continue = wt._create_continue
    orig_input = vim.ui.input
  end)

  after_each(function()
    I.list_worktrees = orig_list
    wt._create_continue = orig_continue
    vim.ui.input = orig_input
    I.reset()
  end)

  it("is a function on the public API", function()
    assert.is_function(wt.create)
  end)

  it("passes the main branch as start_point by default", function()
    I.list_worktrees = function()
      return {
        { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
        { path = "/proj/.worktrees/feat", branch = "feat", head = "def5678", bare = false },
      }
    end

    local captured_args = nil
    wt._create_continue = function(branch, do_fork, start_point)
      captured_args = { branch = branch, do_fork = do_fork, start_point = start_point }
    end

    vim.ui.input = function(opts, cb) cb("new-feature") end

    wt.create()

    assert.is_not_nil(captured_args, "_create_continue should have been called")
    assert.equals("new-feature", captured_args.branch)
    assert.is_false(captured_args.do_fork)
    assert.equals("main", captured_args.start_point,
      "create() should pass the main branch as start_point")
  end)

  it("does not pass start_point when from_current is true", function()
    I.list_worktrees = function()
      return {
        { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      }
    end

    local captured_args = nil
    wt._create_continue = function(branch, do_fork, start_point)
      captured_args = { branch = branch, do_fork = do_fork, start_point = start_point }
    end

    vim.ui.input = function(opts, cb) cb("from-current") end

    wt.create({ from_current = true })

    assert.is_not_nil(captured_args, "_create_continue should have been called")
    assert.equals("from-current", captured_args.branch)
    assert.is_false(captured_args.do_fork)
    assert.is_nil(captured_args.start_point,
      "from_current should not pass start_point (branches from current HEAD)")
  end)

  it("does not pass start_point when fork is true", function()
    I.list_worktrees = function()
      return {
        { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      }
    end

    local captured_args = nil
    wt._create_continue = function(branch, do_fork, start_point)
      captured_args = { branch = branch, do_fork = do_fork, start_point = start_point }
    end

    vim.ui.input = function(opts, cb) cb("fork-branch") end

    wt.create({ fork = true })

    assert.is_not_nil(captured_args, "_create_continue should have been called")
    assert.equals("fork-branch", captured_args.branch)
    assert.is_true(captured_args.do_fork)
    assert.is_nil(captured_args.start_point,
      "fork should not pass start_point (branches from current HEAD)")
  end)
end)

describe("create_from", function()
  it("is not on the public API (removed: use wC for create-from-source)", function()
    assert.is_nil(wt.create_from)
  end)
end)

------------------------------------------------------------------------
-- prompt_branch (internal: vim.ui.input wrapper)
------------------------------------------------------------------------

describe("prompt_branch", function()
  it("is exposed on _internal", function()
    assert.is_function(I.prompt_branch)
  end)

  it("calls callback with entered branch name", function()
    local captured_branch = nil
    local orig_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      cb("test-branch")
    end

    I.prompt_branch(function(branch)
      captured_branch = branch
    end)

    vim.ui.input = orig_input
    assert.equals("test-branch", captured_branch)
  end)

  it("does not call callback on empty input", function()
    local called = false
    local orig_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      cb("")
    end

    I.prompt_branch(function()
      called = true
    end)

    vim.ui.input = orig_input
    assert.is_false(called)
  end)

  it("does not call callback on nil input (cancelled)", function()
    local called = false
    local orig_input = vim.ui.input
    vim.ui.input = function(opts, cb)
      cb(nil)
    end

    I.prompt_branch(function()
      called = true
    end)

    vim.ui.input = orig_input
    assert.is_false(called)
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

  it("retries with --force when clean remove fails", function()
    local cmds = {}
    vim.system = function(cmd)
      table.insert(cmds, cmd)
      -- First worktree remove fails (dirty), force succeeds
      if cmd[2] == "worktree" and cmd[3] == "remove" then
        if #cmd == 4 then -- no --force
          return { wait = function() return { code = 1, stderr = "contains modified files" } end }
        else -- has --force
          return { wait = function() return { code = 0, stdout = "" } end }
        end
      end
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    local wt_entry = { path = "/proj/dirty", branch = "dirty", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    -- Should have: clean remove, force remove, branch -d
    local found_clean = false
    local found_force = false
    for _, cmd in ipairs(cmds) do
      if cmd[2] == "worktree" and cmd[3] == "remove" then
        if cmd[4] == "--force" then
          found_force = true
        else
          found_clean = true
        end
      end
    end
    assert.is_true(found_clean, "Expected clean worktree remove attempt")
    assert.is_true(found_force, "Expected force worktree remove after clean fails")
  end)

  it("tears down SSE subscription before removing", function()
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
      [dir_feat] = I.make_entry({ branch = "feat", subscription = mock_sub }),
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

  it("closes diffview tab for deleted worktree", function()
    local dv = require("neovia.diffview")

    vim.system = function()
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    I.set_state({
      ["/proj/feat"] = I.make_entry({ branch = "feat" }),
    })

    -- Create and register a diffview tab for /proj/feat
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register("/proj/feat", dv_tab)
    vim.cmd("tabfirst")

    local tab_count_before = #vim.api.nvim_list_tabpages()

    local wt_entry = { path = "/proj/feat", branch = "feat", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    assert.equals(tab_count_before - 1, #vim.api.nvim_list_tabpages(),
      "diffview tab should be closed on worktree delete")
    assert.is_false(dv.has_diffview_tab("/proj/feat"),
      "diffview tab should be unregistered on worktree delete")

    -- Cleanup
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tablast | tabclose")
    end
    dv._internal.reset()
  end)

  it("force-deletes branch via async vim.system when user confirms", function()
    local call_idx = 0
    local force_cmd = nil
    local force_callback = nil

    vim.system = function(cmd, opts, on_exit)
      call_idx = call_idx + 1
      if on_exit then
        -- Async call (force delete) -- capture for later invocation
        force_cmd = cmd
        force_callback = on_exit
        return
      end
      -- Sync calls: worktree remove succeeds, branch -d fails (not merged)
      if cmd[2] == "worktree" then
        return { wait = function() return { code = 0, stdout = "" } end }
      elseif cmd[2] == "branch" and cmd[3] == "-d" then
        return { wait = function() return { code = 1, stderr = "not fully merged" } end }
      end
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    -- Mock vim.ui.select to auto-pick "Force delete (-D)"
    local orig_select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      cb("Force delete (-D)")
    end

    -- Make vim.schedule run synchronously
    local orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    I.set_state({
      ["/proj/unmerged"] = I.make_entry({ branch = "unmerged" }),
    })

    local wt_entry = { path = "/proj/unmerged", branch = "unmerged", head = "abc", bare = false }
    wt._delete_continue(wt_entry)

    -- The async vim.system call should have been made
    assert.is_not_nil(force_cmd, "Expected async vim.system call for force delete")
    assert.equals("-D", force_cmd[3])
    assert.equals("unmerged", force_cmd[4])

    -- Simulate the async call completing successfully
    local notified_msg = nil
    local orig_notify = vim.notify
    vim.notify = function(msg) notified_msg = msg end

    force_callback({ code = 0, stdout = "" })

    vim.notify = orig_notify
    vim.schedule = orig_schedule
    vim.ui.select = orig_select

    assert.is_truthy(notified_msg and notified_msg:find("force%-deleted"),
      "Expected force-delete success notification")
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
    })
  end)

  after_each(function()
    I.reset()
  end)

  it("returns entries from state matching worktree list", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/feat", branch = "feat-a", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals(2, #entries)
    assert.equals("main", entries[1].branch)
    assert.equals("idle", entries[1].status)
    assert.equals("feat-a", entries[2].branch)
    assert.equals("responding", entries[2].status)
  end)

  it("marks unknown worktrees with unknown status", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/new", branch = "new-branch", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals(2, #entries)
    assert.equals("unknown", entries[2].status)
  end)

  it("uses tab-level cwd for current marker, ignoring window-local lcd", function()
    -- Simulate: tcd is set to /proj/feat, but current window has lcd to /proj/main
    -- (this can happen when a plugin sets lcd on the code window)
    local orig_cwd = I.tab_cwd()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "responding" }),
    })

    -- Set tab-level cwd to feat
    vim.cmd.tcd(dir_feat)
    -- Set window-level cwd to main (simulating a plugin's lcd)
    vim.cmd.lcd(dir_main)

    local worktrees = {
      { path = dir_main, branch = "main", head = "abc1234", bare = false },
      { path = dir_feat, branch = "feat", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)

    -- The current worktree should be feat (tab-level), not main (window-level)
    assert.is_false(entries[1].current, "main should not be current (that's only the window lcd)")
    assert.is_true(entries[2].current, "feat should be current (matches tab-level tcd)")

    -- Cleanup: restore tcd first (clears window-level lcd implicitly)
    vim.cmd.tcd(orig_cwd)
    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
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
  it("includes path in each entry", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/feat", branch = "feat-a", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.equals("/proj/main", entries[1].path)
    assert.equals("/proj/feat", entries[2].path)
  end)

  it("populates pr field from pr module cache", function()
    local ok_pr, pr = pcall(require, "neovia.pr")
    if not ok_pr then return end

    pr._internal.set_cache({
      ["feat-a"] = { state = "open", number = 42, url = "https://example.com/42" },
    })

    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/feat", branch = "feat-a", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.is_nil(entries[1].pr, "main has no PR")
    assert.is_not_nil(entries[2].pr, "feat-a has a PR")
    assert.equals("open", entries[2].pr.state)
    assert.equals(42, entries[2].pr.number)

    pr._internal.set_cache({})
  end)

  it("sets pr to nil when branch has no PR", function()
    local ok_pr, pr = pcall(require, "neovia.pr")
    if not ok_pr then return end

    pr._internal.set_cache({})

    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    assert.is_nil(entries[1].pr)

    pr._internal.set_cache({})
  end)

  it("sets view to 'diff' when worktree has a diffview tab and it is current", function()
    local dv = require("neovia.diffview")
    -- Create a tab and register it as diffview for /proj/feat
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register("/proj/feat", dv_tab)

    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/feat", branch = "feat-a", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    -- We're on the diffview tab for /proj/feat, so it should be "diff"
    assert.equals("diff", entries[2].view)
    -- main has no diffview tab
    assert.is_nil(entries[1].view)

    -- Cleanup
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tablast | tabclose")
    end
    dv._internal.reset()
  end)

  it("sets view to diff when worktree has a diffview tab even if not current tab", function()
    local dv = require("neovia.diffview")
    -- Create a tab and register it, then switch away
    vim.cmd("tabnew")
    local dv_tab = vim.api.nvim_get_current_tabpage()
    dv._internal.register("/proj/feat", dv_tab)
    -- Switch back to first tab (not on the diffview tab)
    vim.cmd("tabfirst")

    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc1234", bare = false },
      { path = "/proj/feat", branch = "feat-a", head = "abc1234", bare = false },
    }
    local entries = wt.get_entries(worktrees)
    -- The diffview tab exists for feat, so [diff] should show regardless
    assert.equals("diff", entries[2].view,
      "view should be diff when a diffview tab exists, even from another tab")
    -- main still has no diffview tab
    assert.is_nil(entries[1].view)

    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd("tablast | tabclose")
    end
    dv._internal.reset()
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
    local cwd = I.tab_cwd()
    I.set_state({
      [cwd] = I.make_entry({ branch = "main", status = "idle" }),
    })

    local result = wt.get_current_status()
    assert.equals("idle", result.status)
    assert.is_string(result.icon)
    assert.is_table(result.hl)
  end)

  it("returns needs_attention status correctly", function()
    local cwd = I.tab_cwd()
    I.set_state({
      [cwd] = I.make_entry({ branch = "main", status = "needs_attention" }),
    })

    local result = wt.get_current_status()
    assert.equals("needs_attention", result.status)
    assert.equals("[needs you]", result.icon)
  end)

  it("returns responding status correctly", function()
    local cwd = I.tab_cwd()
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

  it("uses tab-level cwd, ignoring window-local lcd", function()
    local orig_cwd = I.tab_cwd()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "needs_attention" }),
    })

    -- tcd to feat, but window lcd to main
    vim.cmd.tcd(dir_feat)
    vim.cmd.lcd(dir_main)

    local result = wt.get_current_status()
    -- Should return feat's status (tab-level), not main's (window-level)
    assert.is_not_nil(result)
    assert.equals("needs_attention", result.status)

    -- Cleanup: restore tcd (clears window-level lcd implicitly)
    vim.cmd.tcd(orig_cwd)
    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
  end)
end)

------------------------------------------------------------------------
-- find_current_worktree
------------------------------------------------------------------------

describe("find_current_worktree", function()
  it("returns the worktree matching the current tab cwd", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc", bare = false },
      { path = "/proj/feat", branch = "feat", head = "abc", bare = false },
    }
    local result = I.find_current_worktree(worktrees, "/proj/feat")
    assert.is_not_nil(result)
    assert.equals("/proj/feat", result.path)
  end)

  it("returns nil when cwd does not match any worktree", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc", bare = false },
    }
    local result = I.find_current_worktree(worktrees, "/somewhere/else")
    assert.is_nil(result)
  end)

  it("returns the worktree index (1-based)", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc", bare = false },
      { path = "/proj/feat", branch = "feat", head = "abc", bare = false },
    }
    local result, idx = I.find_current_worktree(worktrees, "/proj/feat")
    assert.equals(2, idx)
  end)

  it("returns index 1 for main worktree", function()
    local worktrees = {
      { path = "/proj/main", branch = "main", head = "abc", bare = false },
      { path = "/proj/feat", branch = "feat", head = "abc", bare = false },
    }
    local result, idx = I.find_current_worktree(worktrees, "/proj/main")
    assert.equals(1, idx)
  end)
end)

------------------------------------------------------------------------
-- delete_current
------------------------------------------------------------------------

describe("delete_current", function()
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

  it("is a function on the public API", function()
    assert.is_function(wt.delete_current)
  end)
end)

------------------------------------------------------------------------
-- next / prev (cycle through open worktrees)
------------------------------------------------------------------------

describe("next", function()
  local orig_cwd
  local orig_system

  before_each(function()
    I.reset()
    orig_cwd = vim.fn.getcwd()
    orig_system = vim.system

    -- Stub vim.system for list_worktrees
    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree /proj/main",
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree /proj/feat",
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
          "worktree /proj/hotfix",
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/hotfix",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      ["/proj/main"] = I.make_entry({ branch = "main", status = "idle" }),
      ["/proj/feat"] = I.make_entry({ branch = "feat", status = "responding" }),
      ["/proj/hotfix"] = I.make_entry({ branch = "hotfix", status = "idle" }),
    })
    I.set_initialised(true)
  end)

  after_each(function()
    vim.system = orig_system
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
  end)

  it("is a function on the public API", function()
    assert.is_function(wt.next)
  end)

  it("switches to the next open worktree", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    local dir_hotfix = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")
    vim.fn.mkdir(dir_hotfix, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
          "worktree " .. dir_hotfix,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/hotfix",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "responding" }),
      [dir_hotfix] = I.make_entry({ branch = "hotfix", status = "idle" }),
    })

    vim.cmd.tcd(dir_main)
    wt.next()
    assert.equals(dir_feat, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
    vim.fn.delete(dir_hotfix, "rf")
  end)

  it("wraps around from the last worktree to the first", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "responding" }),
    })

    vim.cmd.tcd(dir_feat)
    wt.next()
    assert.equals(dir_main, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
  end)

  it("is a no-op when only one worktree exists", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
    })

    vim.cmd.tcd(dir_main)
    wt.next()
    assert.equals(dir_main, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
  end)
end)

describe("prev", function()
  local orig_cwd
  local orig_system

  before_each(function()
    I.reset()
    orig_cwd = vim.fn.getcwd()
    orig_system = vim.system
    I.set_initialised(true)
  end)

  after_each(function()
    vim.system = orig_system
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
  end)

  it("is a function on the public API", function()
    assert.is_function(wt.prev)
  end)

  it("switches to the previous open worktree", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    local dir_hotfix = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")
    vim.fn.mkdir(dir_hotfix, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
          "worktree " .. dir_hotfix,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/hotfix",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "responding" }),
      [dir_hotfix] = I.make_entry({ branch = "hotfix", status = "idle" }),
    })

    vim.cmd.tcd(dir_hotfix)
    wt.prev()
    assert.equals(dir_feat, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
    vim.fn.delete(dir_hotfix, "rf")
  end)

  it("wraps around from the first worktree to the last", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "responding" }),
    })

    vim.cmd.tcd(dir_main)
    wt.prev()
    assert.equals(dir_feat, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
  end)
end)

------------------------------------------------------------------------
-- next_attention (cycle to next worktree needing attention)
------------------------------------------------------------------------

describe("next_attention", function()
  local orig_cwd
  local orig_system

  before_each(function()
    I.reset()
    orig_cwd = vim.fn.getcwd()
    orig_system = vim.system
    I.set_initialised(true)
  end)

  after_each(function()
    vim.system = orig_system
    pcall(vim.cmd.tcd, orig_cwd)
    I.reset()
  end)

  it("is a function on the public API", function()
    assert.is_function(wt.next_attention)
  end)

  it("switches to the next worktree with needs_attention status", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    local dir_hotfix = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")
    vim.fn.mkdir(dir_hotfix, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
          "worktree " .. dir_hotfix,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/hotfix",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "needs_attention" }),
      [dir_hotfix] = I.make_entry({ branch = "hotfix", status = "idle" }),
    })

    vim.cmd.tcd(dir_main)
    wt.next_attention()
    assert.equals(dir_feat, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
    vim.fn.delete(dir_hotfix, "rf")
  end)

  it("wraps around when searching for attention worktrees", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    local dir_hotfix = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")
    vim.fn.mkdir(dir_hotfix, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
          "worktree " .. dir_hotfix,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/hotfix",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "needs_attention" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "idle" }),
      [dir_hotfix] = I.make_entry({ branch = "hotfix", status = "idle" }),
    })

    -- Starting from hotfix, should wrap to main
    vim.cmd.tcd(dir_hotfix)
    wt.next_attention()
    assert.equals(dir_main, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
    vim.fn.delete(dir_hotfix, "rf")
  end)

  it("is a no-op when no worktree needs attention", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "idle" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "responding" }),
    })

    vim.cmd.tcd(dir_main)
    wt.next_attention()
    assert.equals(dir_main, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
  end)

  it("cycles forward from the current attention worktree to the next one", function()
    local dir_main = vim.fn.resolve(vim.fn.tempname())
    local dir_feat = vim.fn.resolve(vim.fn.tempname())
    local dir_hotfix = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir_main, "p")
    vim.fn.mkdir(dir_feat, "p")
    vim.fn.mkdir(dir_hotfix, "p")

    vim.system = function(cmd, opts)
      if cmd[1] == "git" and cmd[2] == "worktree" then
        local output = table.concat({
          "worktree " .. dir_main,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/main",
          "",
          "worktree " .. dir_feat,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/feat",
          "",
          "worktree " .. dir_hotfix,
          "HEAD abc1234def5678901234567890abcdef12345678",
          "branch refs/heads/hotfix",
          "",
        }, "\n")
        return { wait = function() return { code = 0, stdout = output } end }
      end
      return orig_system(cmd, opts)
    end

    I.set_state({
      [dir_main] = I.make_entry({ branch = "main", status = "needs_attention" }),
      [dir_feat] = I.make_entry({ branch = "feat", status = "idle" }),
      [dir_hotfix] = I.make_entry({ branch = "hotfix", status = "needs_attention" }),
    })

    -- Start at main (needs attention), next_attention should go to hotfix
    vim.cmd.tcd(dir_main)
    wt.next_attention()
    assert.equals(dir_hotfix, I.tab_cwd())

    vim.fn.delete(dir_main, "rf")
    vim.fn.delete(dir_feat, "rf")
    vim.fn.delete(dir_hotfix, "rf")
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

------------------------------------------------------------------------
-- save_session_id
------------------------------------------------------------------------

describe("save_session_id", function()
  after_each(function()
    I.reset()
    package.loaded["opencode.state"] = nil
  end)

  it("saves active session ID into state", function()
    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main" }),
    })
    package.loaded["opencode.state"] = {
      active_session = { id = "session-42" },
    }

    I.save_session_id("/proj/a")

    assert.equals("session-42", I.get_state()["/proj/a"].session_id)
  end)

  it("is a no-op for unknown directories", function()
    I.set_state({})
    package.loaded["opencode.state"] = {
      active_session = { id = "session-42" },
    }

    I.save_session_id("/nonexistent")
    assert.is_nil(I.get_state()["/nonexistent"])
  end)

  it("is a no-op when opencode.state is not loaded", function()
    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main" }),
    })
    package.loaded["opencode.state"] = nil

    I.save_session_id("/proj/a")
    assert.is_nil(I.get_state()["/proj/a"].session_id)
  end)

  it("is a no-op when active_session is nil", function()
    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main" }),
    })
    package.loaded["opencode.state"] = {
      active_session = nil,
    }

    I.save_session_id("/proj/a")
    assert.is_nil(I.get_state()["/proj/a"].session_id)
  end)

  it("does not overwrite with nil when session has no id", function()
    I.set_state({
      ["/proj/a"] = I.make_entry({ branch = "main", session_id = "old-id" }),
    })
    package.loaded["opencode.state"] = {
      active_session = {},
    }

    I.save_session_id("/proj/a")
    -- Should not overwrite: active_session.id is nil
    assert.equals("old-id", I.get_state()["/proj/a"].session_id)
  end)
end)

------------------------------------------------------------------------
-- switch_to: session switching integration
------------------------------------------------------------------------

describe("switch_to session switching", function()
  local orig_cwd
  local dir_a, dir_b

  before_each(function()
    I.reset()

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
    package.loaded["opencode.state"] = nil
    package.loaded["opencode.core"] = nil
  end)

  it("does not pre-set opencode current_cwd before tcd", function()
    -- set_current_cwd was previously called before tcd to suppress
    -- opencode.nvim's DirChanged handler. This caused the event manager
    -- to tear down and reconnect SSE prematurely, creating a gap where
    -- streaming events were lost. Now we let DirChanged handle everything.
    local cwd_set_calls = {}
    package.loaded["opencode.state"] = {
      active_session = { id = "s1" },
      context = {
        set_current_cwd = function(path)
          table.insert(cwd_set_calls, path)
        end,
      },
    }
    package.loaded["opencode.core"] = {
      switch_session = function() end,
      handle_directory_change = function() end,
    }

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", session_id = "s2" }),
    })

    wt.switch_to(dir_b)

    assert.equals(0, #cwd_set_calls,
      "set_current_cwd should NOT be called by switch_to; DirChanged handles it")
  end)

  it("does not call core.switch_session or handle_directory_change", function()
    -- Session switching is now handled by opencode.nvim's DirChanged
    -- autocmd, which fires synchronously during tcd. neovia should not
    -- call these functions directly to avoid racing with the event
    -- manager's SSE reconnection.
    package.loaded["opencode.state"] = {
      active_session = { id = "s1" },
      context = { set_current_cwd = function() end },
    }
    local switch_called = false
    local hdc_called = false
    package.loaded["opencode.core"] = {
      switch_session = function()
        switch_called = true
      end,
      handle_directory_change = function()
        hdc_called = true
      end,
    }

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", session_id = "target-session-99" }),
    })

    wt.switch_to(dir_b)

    assert.is_false(switch_called,
      "core.switch_session should NOT be called by switch_to")
    assert.is_false(hdc_called,
      "handle_directory_change should NOT be called by switch_to")
  end)

  it("saves current session_id before switching away", function()
    package.loaded["opencode.state"] = {
      active_session = { id = "current-session-77" },
      context = { set_current_cwd = function() end },
    }
    package.loaded["opencode.core"] = {
      switch_session = function() end,
      handle_directory_change = function() end,
    }

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", session_id = "s2" }),
    })

    wt.switch_to(dir_b)

    assert.equals("current-session-77", I.get_state()[dir_a].session_id,
      "Session ID should be saved for the worktree we switched away from")
  end)

   it("does not re-subscribe SSE from switch_to (plugin restores via REST)", function()
    -- Pending permissions/questions are restored by opencode.nvim's
    -- render_full_session() via REST API calls after renderer.reset().
    -- switch_to must not touch SSE subscriptions.
    local resubscribe_called = false
    local mock_server = { url = "http://localhost:1234" }
    package.loaded["opencode.state"] = {
      active_session = { id = "s1" },
      context = { set_current_cwd = function() end },
      opencode_server = mock_server,
      event_manager = {
        _subscribe_to_server_events = function()
          resubscribe_called = true
        end,
      },
    }
    package.loaded["opencode.core"] = {}

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    wt.switch_to(dir_b)

    -- Wait well past the deferred callback window
    vim.wait(200, function() return resubscribe_called end)

    assert.is_false(resubscribe_called,
      "switch_to should not re-subscribe SSE; plugin restores via REST API")
  end)

  it("saves model state before switching away", function()
    package.loaded["opencode.state"] = {
      active_session = { id = "s1" },
      current_model = "anthropic/claude-opus-4-6",
      current_variant = "high",
      current_mode = "build",
      user_mode_model_map = { build = "anthropic/claude-opus-4-6", plan = "openai/o3" },
      model = {
        set_model = function() end,
        set_variant = function() end,
        set_mode_model_map = function() end,
      },
    }
    package.loaded["opencode.core"] = {}

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    wt.switch_to(dir_b)

    local saved = I.get_state()[dir_a].model_state
    assert.is_table(saved, "model_state should be saved for the worktree we left")
    assert.equals("anthropic/claude-opus-4-6", saved.model)
    assert.equals("high", saved.variant)
    assert.equals("build", saved.mode)
    assert.same({ build = "anthropic/claude-opus-4-6", plan = "openai/o3" }, saved.mode_model_map)
  end)

  it("does not save model state when opencode is not loaded", function()
    package.loaded["opencode.state"] = nil
    package.loaded["opencode.core"] = nil

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),
    })

    wt.switch_to(dir_b)

    assert.is_nil(I.get_state()[dir_a].model_state)
  end)

  it("restores model state after switching to a worktree that has it", function()
    local set_model_calls = {}
    local set_variant_calls = {}
    local set_map_calls = {}
    package.loaded["opencode.state"] = {
      active_session = { id = "s1" },
      current_model = "openai/o3",
      current_variant = nil,
      current_mode = "build",
      user_mode_model_map = {},
      model = {
        set_model = function(m) table.insert(set_model_calls, m) end,
        set_variant = function(v) table.insert(set_variant_calls, v) end,
        set_mode_model_map = function(map) table.insert(set_map_calls, map) end,
      },
    }
    package.loaded["opencode.core"] = {}

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat", model_state = {
        model = "anthropic/claude-opus-4-6",
        variant = "high",
        mode = "plan",
        mode_model_map = { plan = "anthropic/claude-opus-4-6" },
      }}),
    })

    wt.switch_to(dir_b)

    -- Restore is deferred (100ms, same as layout/SSE resubscribe)
    vim.wait(200, function() return #set_model_calls > 0 end)

    assert.equals(1, #set_model_calls)
    assert.equals("anthropic/claude-opus-4-6", set_model_calls[1])
    assert.equals(1, #set_variant_calls)
    assert.equals("high", set_variant_calls[1])
    assert.equals(1, #set_map_calls)
    assert.same({ plan = "anthropic/claude-opus-4-6" }, set_map_calls[1])
  end)

  it("does not restore model state when target has no saved model_state", function()
    local set_model_calls = {}
    package.loaded["opencode.state"] = {
      active_session = { id = "s1" },
      current_model = "openai/o3",
      model = {
        set_model = function(m) table.insert(set_model_calls, m) end,
        set_variant = function() end,
        set_mode_model_map = function() end,
      },
    }
    package.loaded["opencode.core"] = {}

    vim.cmd.tcd(dir_a)
    I.set_state({
      [dir_a] = I.make_entry({ branch = "main" }),
      [dir_b] = I.make_entry({ branch = "feat" }),  -- no model_state
    })

    wt.switch_to(dir_b)

    vim.wait(200, function() return false end)  -- let any deferred callbacks fire

    assert.equals(0, #set_model_calls,
      "should not call set_model when target has no saved model_state")
  end)
end)

------------------------------------------------------------------------
-- make_entry includes session_id
------------------------------------------------------------------------

describe("make_entry", function()
  it("includes session_id as nil by default", function()
    local entry = I.make_entry()
    assert.is_nil(entry.session_id)
  end)

  it("accepts session_id override", function()
    local entry = I.make_entry({ session_id = "custom-id" })
    assert.equals("custom-id", entry.session_id)
  end)

  it("includes model_state as nil by default", function()
    local entry = I.make_entry()
    assert.is_nil(entry.model_state)
  end)

  it("accepts model_state override", function()
    local ms = { model = "anthropic/claude-opus-4-6", variant = "high", mode_model_map = {} }
    local entry = I.make_entry({ model_state = ms })
    assert.same(ms, entry.model_state)
  end)
end)

------------------------------------------------------------------------
-- resync (public API)
------------------------------------------------------------------------

describe("resync", function()
  after_each(function()
    I.reset()
    package.loaded["opencode.state"] = nil
  end)

  it("is a function on the public API", function()
    assert.is_function(wt.resync)
  end)

  it("saves current worktree session from active_session", function()
    local cwd = I.tab_cwd()
    I.set_state({
      [cwd] = I.make_entry({ branch = "main" }),
    })
    package.loaded["opencode.state"] = {
      active_session = { id = "active-123" },
      api_client = {},
    }

    wt.resync()

    assert.equals("active-123", I.get_state()[cwd].session_id)
  end)

  it("warns when opencode is not available", function()
    package.loaded["opencode.state"] = nil
    I.set_state({})

    local notified_msg = nil
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then notified_msg = msg end
    end

    wt.resync()

    vim.notify = orig_notify
    assert.is_not_nil(notified_msg)
    assert.is_truthy(notified_msg:find("not available"))
  end)

  it("queries API for other worktrees", function()
    local cwd = I.tab_cwd()
    local queried_dirs = {}

    local mock_promise = {}
    mock_promise.and_then = function(self, cb)
      return self
    end
    mock_promise.catch = function(self) return self end

    I.set_state({
      [cwd] = I.make_entry({ branch = "main" }),
      ["/proj/feat"] = I.make_entry({ branch = "feat" }),
    })

    package.loaded["opencode.state"] = {
      active_session = { id = "active-1" },
      api_client = {
        list_sessions = function(_, dir)
          table.insert(queried_dirs, dir)
          return mock_promise
        end,
      },
    }

    wt.resync()

    -- Should query /proj/feat (not current) but NOT cwd
    assert.equals(1, #queried_dirs)
    assert.equals("/proj/feat", queried_dirs[1])
  end)
end)

------------------------------------------------------------------------
-- strip_worktrees_ignored
------------------------------------------------------------------------

describe("strip_worktrees_ignored", function()
  it("removes ignored status for .worktrees directory itself", function()
    local root = "/home/user/project"
    local status = {
      [root .. "/.worktrees"] = "!",
      [root .. "/src/main.lua"] = ".M",
    }

    I.strip_worktrees_ignored(status, root)

    assert.is_nil(status[root .. "/.worktrees"])
    assert.equals(".M", status[root .. "/src/main.lua"])
  end)

  it("removes ignored status for paths under .worktrees/", function()
    local root = "/home/user/project"
    local status = {
      [root .. "/.worktrees/feat-foo"] = "!",
      [root .. "/.worktrees/feat-foo/src"] = "!",
      [root .. "/.worktrees/feat-foo/src/main.lua"] = "!",
      [root .. "/node_modules"] = "!",
    }

    I.strip_worktrees_ignored(status, root)

    assert.is_nil(status[root .. "/.worktrees/feat-foo"])
    assert.is_nil(status[root .. "/.worktrees/feat-foo/src"])
    assert.is_nil(status[root .. "/.worktrees/feat-foo/src/main.lua"])
    assert.equals("!", status[root .. "/node_modules"])
  end)

  it("preserves non-ignored statuses under .worktrees/", function()
    local root = "/home/user/project"
    local status = {
      [root .. "/.worktrees/feat-foo/src/main.lua"] = ".M",
    }

    I.strip_worktrees_ignored(status, root)

    assert.equals(".M", status[root .. "/.worktrees/feat-foo/src/main.lua"])
  end)

  it("does nothing when status table is empty", function()
    local status = {}
    I.strip_worktrees_ignored(status, "/home/user/project")
    assert.same({}, status)
  end)

  it("does nothing when no .worktrees entries exist", function()
    local root = "/home/user/project"
    local status = {
      [root .. "/node_modules"] = "!",
      [root .. "/.env"] = "!",
      [root .. "/src/main.lua"] = ".M",
    }
    local original = vim.deepcopy(status)

    I.strip_worktrees_ignored(status, root)

    assert.same(original, status)
  end)

  it("does not match paths that merely start with .worktrees", function()
    local root = "/home/user/project"
    local status = {
      [root .. "/.worktrees_backup"] = "!",
      [root .. "/.worktreesomething"] = "!",
    }
    local original = vim.deepcopy(status)

    I.strip_worktrees_ignored(status, root)

    assert.same(original, status)
  end)
end)

------------------------------------------------------------------------
-- strip_all_worktrees_ignored
------------------------------------------------------------------------

describe("strip_all_worktrees_ignored", function()
  local saved_neo_git

  before_each(function()
    saved_neo_git = package.loaded["neo-tree.git"]
  end)

  after_each(function()
    package.loaded["neo-tree.git"] = saved_neo_git
  end)

  it("strips .worktrees/ entries from all registered worktrees", function()
    local parent_root = "/home/user/project"
    local child_root = parent_root .. "/.worktrees/feat"
    package.loaded["neo-tree.git"] = {
      worktrees = {
        [parent_root] = {
          status = {
            [parent_root .. "/.worktrees"] = "!",
            [parent_root .. "/.worktrees/feat"] = "!",
            [parent_root .. "/node_modules"] = "!",
            [parent_root .. "/src/main.lua"] = ".M",
          },
        },
        [child_root] = {
          status = {
            [child_root .. "/src/app.lua"] = ".M",
          },
        },
      },
    }

    I.strip_all_worktrees_ignored()

    local parent_status = package.loaded["neo-tree.git"].worktrees[parent_root].status
    assert.is_nil(parent_status[parent_root .. "/.worktrees"])
    assert.is_nil(parent_status[parent_root .. "/.worktrees/feat"])
    assert.equals("!", parent_status[parent_root .. "/node_modules"])
    assert.equals(".M", parent_status[parent_root .. "/src/main.lua"])

    local child_status = package.loaded["neo-tree.git"].worktrees[child_root].status
    assert.equals(".M", child_status[child_root .. "/src/app.lua"])
  end)

  it("skips worktrees with nil status", function()
    package.loaded["neo-tree.git"] = {
      worktrees = {
        ["/home/user/project"] = { status = nil },
      },
    }

    -- Should not error
    I.strip_all_worktrees_ignored()
  end)

  it("handles neo-tree.git not loaded", function()
    package.loaded["neo-tree.git"] = nil

    -- Should not error
    I.strip_all_worktrees_ignored()
  end)
end)

------------------------------------------------------------------------
-- patch_neo_tree_git_lookup
------------------------------------------------------------------------

describe("patch_neo_tree_git_lookup", function()
  local saved_neo_git, saved_neo_utils

  before_each(function()
    saved_neo_git = package.loaded["neo-tree.git"]
    saved_neo_utils = package.loaded["neo-tree.utils"]
    -- Reset the patch flag so each test gets a clean state
    I.reset()
    -- Re-require to pick up the reset
  end)

  after_each(function()
    package.loaded["neo-tree.git"] = saved_neo_git
    package.loaded["neo-tree.utils"] = saved_neo_utils
  end)

  -- Minimal is_subpath that mirrors neo-tree's behaviour for tests
  local function mock_is_subpath(base, path, _fast)
    if base == path then return true end
    if #path < #base then return false end
    if path:sub(1, #base) ~= base then return false end
    return path:byte(#base + 1) == string.byte("/")
  end

  it("returns the deepest matching worktree root", function()
    local parent = "/home/user/project"
    local child = parent .. "/.worktrees/feat"
    local neo_git = {
      worktrees = {
        [parent] = { status = {} },
        [child] = { status = { [child .. "/src/app.lua"] = ".M" } },
      },
      _upward_worktree_cache = setmetatable({}, { __mode = "kv" }),
    }
    package.loaded["neo-tree.git"] = neo_git
    package.loaded["neo-tree.utils"] = { is_subpath = mock_is_subpath }

    I.patch_neo_tree_git_lookup()

    local root, info = neo_git.find_existing_worktree(child .. "/src/app.lua")
    assert.equals(child, root)
    assert.equals(".M", info.status[child .. "/src/app.lua"])
  end)

  it("returns parent when path is not under any child worktree", function()
    local parent = "/home/user/project"
    local child = parent .. "/.worktrees/feat"
    local neo_git = {
      worktrees = {
        [parent] = { status = { [parent .. "/README.md"] = ".M" } },
        [child] = { status = {} },
      },
      _upward_worktree_cache = setmetatable({}, { __mode = "kv" }),
    }
    package.loaded["neo-tree.git"] = neo_git
    package.loaded["neo-tree.utils"] = { is_subpath = mock_is_subpath }

    I.patch_neo_tree_git_lookup()

    local root, info = neo_git.find_existing_worktree(parent .. "/README.md")
    assert.equals(parent, root)
  end)

  it("returns nil when no worktree matches", function()
    local neo_git = {
      worktrees = {
        ["/home/user/project"] = { status = {} },
      },
      _upward_worktree_cache = setmetatable({}, { __mode = "kv" }),
    }
    package.loaded["neo-tree.git"] = neo_git
    package.loaded["neo-tree.utils"] = { is_subpath = mock_is_subpath }

    I.patch_neo_tree_git_lookup()

    local root, info = neo_git.find_existing_worktree("/other/path")
    assert.is_nil(root)
    assert.is_nil(info)
  end)

  it("uses cache for subsequent lookups", function()
    local parent = "/home/user/project"
    local child = parent .. "/.worktrees/feat"
    local call_count = 0
    local counting_is_subpath = function(base, path, fast)
      call_count = call_count + 1
      return mock_is_subpath(base, path, fast)
    end
    local neo_git = {
      worktrees = {
        [parent] = { status = {} },
        [child] = { status = {} },
      },
      _upward_worktree_cache = setmetatable({}, { __mode = "kv" }),
    }
    package.loaded["neo-tree.git"] = neo_git
    package.loaded["neo-tree.utils"] = { is_subpath = counting_is_subpath }

    I.patch_neo_tree_git_lookup()

    -- First call iterates worktrees
    neo_git.find_existing_worktree(child .. "/src/app.lua")
    local first_count = call_count

    -- Second call uses cache, no new is_subpath calls
    neo_git.find_existing_worktree(child .. "/src/app.lua")
    assert.equals(first_count, call_count)
  end)

  it("is idempotent", function()
    local parent = "/home/user/project"
    local child = parent .. "/.worktrees/feat"
    local neo_git = {
      worktrees = {
        [parent] = { status = {} },
        [child] = { status = {} },
      },
      _upward_worktree_cache = setmetatable({}, { __mode = "kv" }),
    }
    package.loaded["neo-tree.git"] = neo_git
    package.loaded["neo-tree.utils"] = { is_subpath = mock_is_subpath }

    I.patch_neo_tree_git_lookup()
    local fn_first = neo_git.find_existing_worktree
    I.patch_neo_tree_git_lookup()
    local fn_second = neo_git.find_existing_worktree

    -- Same function reference: second call was a no-op
    assert.equals(fn_first, fn_second)
  end)

  it("does not error when neo-tree.git is not available", function()
    package.loaded["neo-tree.git"] = nil
    package.loaded["neo-tree.utils"] = nil

    -- Should not error
    I.patch_neo_tree_git_lookup()
  end)
end)
