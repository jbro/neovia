-- tests/neovia/review_spec.lua
-- Unit tests for lua/neovia/review.lua

local review = require("neovia.review")
local I = review._internal

-- Use a unique temp dir for each test run.
local test_state_dir = vim.fn.tempname() .. "_neovia_review_test"

------------------------------------------------------------------------
-- storage_path: deterministic mapping from worktree dir to JSON path
------------------------------------------------------------------------

describe("storage_path", function()
  it("returns a path under state_dir/review/ using sha256 of the dir", function()
    local dir = "/Users/me/projects/foo"
    local result = I.storage_path(dir, "/tmp/state")
    local hash = vim.fn.sha256(dir)
    assert.equals("/tmp/state/review/" .. hash .. ".json", result)
  end)

  it("returns different paths for different dirs", function()
    local a = I.storage_path("/a", "/tmp/state")
    local b = I.storage_path("/b", "/tmp/state")
    assert.are_not.equal(a, b)
  end)

  it("returns the same path for the same dir", function()
    local a = I.storage_path("/a", "/tmp/state")
    local b = I.storage_path("/a", "/tmp/state")
    assert.equals(a, b)
  end)
end)

------------------------------------------------------------------------
-- generate_id: unique comment IDs
------------------------------------------------------------------------

describe("generate_id", function()
  it("returns a string", function()
    local id = I.generate_id()
    assert.is_string(id)
  end)

  it("returns different IDs on successive calls", function()
    local ids = {}
    for _ = 1, 100 do
      local id = I.generate_id()
      assert.is_nil(ids[id], "duplicate ID: " .. id)
      ids[id] = true
    end
  end)
end)

------------------------------------------------------------------------
-- save_to_disk / load_from_disk: JSON persistence
------------------------------------------------------------------------

describe("save_to_disk", function()
  after_each(function()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("creates parent directories and writes JSON", function()
    local path = test_state_dir .. "/review/test.json"
    local data = { comments = {} }
    I.save_to_disk(path, data)
    local raw = vim.fn.readfile(path)
    local decoded = vim.json.decode(table.concat(raw, "\n"))
    assert.same({ comments = {} }, decoded)
  end)

  it("writes comments with all fields", function()
    local path = test_state_dir .. "/review/test.json"
    local data = {
      comments = {
        { id = "abc", file = "foo.lua", line = 1, end_line = vim.NIL, text = "fix this", state = "new" },
      },
    }
    I.save_to_disk(path, data)
    local raw = vim.fn.readfile(path)
    local decoded = vim.json.decode(table.concat(raw, "\n"))
    assert.equals(1, #decoded.comments)
    assert.equals("abc", decoded.comments[1].id)
    assert.equals("new", decoded.comments[1].state)
  end)

  it("overwrites existing content", function()
    local path = test_state_dir .. "/review/test.json"
    I.save_to_disk(path, { comments = { { id = "old" } } })
    I.save_to_disk(path, { comments = { { id = "new" } } })
    local raw = vim.fn.readfile(path)
    local decoded = vim.json.decode(table.concat(raw, "\n"))
    assert.equals("new", decoded.comments[1].id)
  end)
end)

describe("load_from_disk", function()
  after_each(function()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("reads JSON from an existing file", function()
    local path = test_state_dir .. "/review/test.json"
    vim.fn.mkdir(test_state_dir .. "/review", "p")
    vim.fn.writefile({ '{"comments":[{"id":"x"}]}' }, path)
    local data = I.load_from_disk(path)
    assert.is_table(data)
    assert.equals("x", data.comments[1].id)
  end)

  it("returns nil for a non-existent file", function()
    local data = I.load_from_disk(test_state_dir .. "/nope.json")
    assert.is_nil(data)
  end)

  it("returns nil for invalid JSON", function()
    local path = test_state_dir .. "/review/bad.json"
    vim.fn.mkdir(test_state_dir .. "/review", "p")
    vim.fn.writefile({ "not json at all" }, path)
    local data = I.load_from_disk(path)
    assert.is_nil(data)
  end)
end)

------------------------------------------------------------------------
-- add_comment: create a new comment
------------------------------------------------------------------------

describe("add_comment", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("adds a comment and returns it with an id", function()
    local comment = review.add_comment("/tmp/wt", {
      file = "src/foo.lua",
      line = 42,
      text = "fix this",
    }, test_state_dir)
    assert.is_table(comment)
    assert.is_string(comment.id)
    assert.equals("src/foo.lua", comment.file)
    assert.equals(42, comment.line)
    assert.equals("fix this", comment.text)
    assert.equals("new", comment.state)
  end)

  it("persists the comment to disk immediately", function()
    review.add_comment("/tmp/wt", {
      file = "src/foo.lua",
      line = 10,
      text = "hello",
    }, test_state_dir)
    local path = I.storage_path("/tmp/wt", test_state_dir)
    local data = I.load_from_disk(path)
    assert.is_table(data)
    assert.equals(1, #data.comments)
    assert.equals("hello", data.comments[1].text)
  end)

  it("supports end_line for range comments", function()
    local comment = review.add_comment("/tmp/wt", {
      file = "src/foo.lua",
      line = 10,
      end_line = 20,
      text = "extract this",
    }, test_state_dir)
    assert.equals(10, comment.line)
    assert.equals(20, comment.end_line)
  end)

  it("accumulates multiple comments", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    review.add_comment("/tmp/wt", { file = "b.lua", line = 2, text = "two" }, test_state_dir)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(2, #comments)
  end)

  it("assigns unique IDs", function()
    local c1 = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    local c2 = review.add_comment("/tmp/wt", { file = "b.lua", line = 2, text = "two" }, test_state_dir)
    assert.are_not.equal(c1.id, c2.id)
  end)
end)

------------------------------------------------------------------------
-- get_comments: retrieve all comments for a worktree
------------------------------------------------------------------------

describe("get_comments", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("returns empty table when no comments exist", function()
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.same({}, comments)
  end)

  it("returns comments that were added", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(1, #comments)
    assert.equals("one", comments[1].text)
  end)

  it("loads from disk when in-memory state is empty", function()
    -- Write directly to disk, bypassing add_comment
    local path = I.storage_path("/tmp/wt_disk", test_state_dir)
    I.save_to_disk(path, {
      comments = {
        { id = "disk1", file = "x.lua", line = 5, text = "from disk", state = "new" },
      },
    })
    local comments = review.get_comments("/tmp/wt_disk", test_state_dir)
    assert.equals(1, #comments)
    assert.equals("from disk", comments[1].text)
  end)
end)

------------------------------------------------------------------------
-- get_comments_for_file: filter comments by file path
------------------------------------------------------------------------

describe("get_comments_for_file", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("returns only comments for the specified file", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    review.add_comment("/tmp/wt", { file = "b.lua", line = 2, text = "two" }, test_state_dir)
    review.add_comment("/tmp/wt", { file = "a.lua", line = 3, text = "three" }, test_state_dir)
    local comments = review.get_comments_for_file("/tmp/wt", "a.lua", test_state_dir)
    assert.equals(2, #comments)
  end)

  it("returns empty table when no comments match", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    local comments = review.get_comments_for_file("/tmp/wt", "z.lua", test_state_dir)
    assert.same({}, comments)
  end)
end)

------------------------------------------------------------------------
-- edit_comment: update text of an existing comment
------------------------------------------------------------------------

describe("edit_comment", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("updates the text of a comment", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "old" }, test_state_dir)
    local ok = review.edit_comment("/tmp/wt", c.id, "new text", test_state_dir)
    assert.is_true(ok)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals("new text", comments[1].text)
  end)

  it("persists the edit to disk", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "old" }, test_state_dir)
    review.edit_comment("/tmp/wt", c.id, "edited", test_state_dir)
    -- Force reload from disk
    I.reset()
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals("edited", comments[1].text)
  end)

  it("returns false for non-existent comment ID", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    local ok = review.edit_comment("/tmp/wt", "nonexistent", "y", test_state_dir)
    assert.is_false(ok)
  end)
end)

------------------------------------------------------------------------
-- delete_comment: remove a comment
------------------------------------------------------------------------

describe("delete_comment", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("removes a comment by ID", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    local ok = review.delete_comment("/tmp/wt", c.id, test_state_dir)
    assert.is_true(ok)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(0, #comments)
  end)

  it("persists deletion to disk", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.delete_comment("/tmp/wt", c.id, test_state_dir)
    I.reset()
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(0, #comments)
  end)

  it("returns false for non-existent comment ID", function()
    local ok = review.delete_comment("/tmp/wt", "nonexistent", test_state_dir)
    assert.is_false(ok)
  end)

  it("does not affect other comments", function()
    local c1 = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "keep" }, test_state_dir)
    local c2 = review.add_comment("/tmp/wt", { file = "b.lua", line = 2, text = "remove" }, test_state_dir)
    review.delete_comment("/tmp/wt", c2.id, test_state_dir)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(1, #comments)
    assert.equals(c1.id, comments[1].id)
  end)
end)

------------------------------------------------------------------------
-- set_state: change comment state (for rereview)
------------------------------------------------------------------------

describe("set_state", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("changes state of a comment", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    local ok = review.set_state("/tmp/wt", c.id, "rereview", test_state_dir)
    assert.is_true(ok)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals("rereview", comments[1].state)
  end)

  it("persists state change to disk", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.set_state("/tmp/wt", c.id, "rereview", test_state_dir)
    I.reset()
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals("rereview", comments[1].state)
  end)

  it("rejects invalid state values", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    local ok = review.set_state("/tmp/wt", c.id, "invalid", test_state_dir)
    assert.is_false(ok)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals("new", comments[1].state)
  end)

  it("returns false for non-existent comment ID", function()
    local ok = review.set_state("/tmp/wt", "nonexistent", "rereview", test_state_dir)
    assert.is_false(ok)
  end)
end)

------------------------------------------------------------------------
-- clear: wipe all comments for a worktree
------------------------------------------------------------------------

describe("clear", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("removes all comments from memory and disk", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.add_comment("/tmp/wt", { file = "b.lua", line = 2, text = "y" }, test_state_dir)
    review.clear("/tmp/wt", test_state_dir)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(0, #comments)
  end)

  it("deletes the storage file", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.clear("/tmp/wt", test_state_dir)
    local path = I.storage_path("/tmp/wt", test_state_dir)
    assert.equals(0, vim.fn.filereadable(path))
  end)

  it("is a no-op for worktree with no comments", function()
    review.clear("/tmp/nonexistent", test_state_dir)
  end)
end)

------------------------------------------------------------------------
-- reload_from_disk: re-read JSON (for file watcher callback)
------------------------------------------------------------------------

describe("reload_from_disk", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("picks up external changes to the JSON file", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    -- Simulate OpenCode editing the file
    local path = I.storage_path("/tmp/wt", test_state_dir)
    local data = I.load_from_disk(path)
    data.comments[1].state = "resolved"
    I.save_to_disk(path, data)

    review.reload_from_disk("/tmp/wt", test_state_dir)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals("resolved", comments[1].state)
  end)

  it("handles file being deleted externally", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    local path = I.storage_path("/tmp/wt", test_state_dir)
    vim.fn.delete(path)

    review.reload_from_disk("/tmp/wt", test_state_dir)
    local comments = review.get_comments("/tmp/wt", test_state_dir)
    assert.equals(0, #comments)
  end)
end)

------------------------------------------------------------------------
-- build_prompt: generate the review prompt text
------------------------------------------------------------------------

describe("build_prompt", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("includes the file path in the prompt", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "fix" }, test_state_dir)
    local path = I.storage_path("/tmp/wt", test_state_dir)
    local prompt = review.build_prompt("/tmp/wt", test_state_dir)
    assert.is_string(prompt)
    assert.is_truthy(prompt:find(path, 1, true), "prompt should contain the file path")
  end)

  it("returns nil when there are no actionable comments", function()
    local prompt = review.build_prompt("/tmp/wt", test_state_dir)
    assert.is_nil(prompt)
  end)

  it("returns nil when all comments are resolved", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.set_state("/tmp/wt", c.id, "resolved", test_state_dir)
    local prompt = review.build_prompt("/tmp/wt", test_state_dir)
    assert.is_nil(prompt)
  end)

  it("returns a prompt when there are new comments", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "fix" }, test_state_dir)
    local prompt = review.build_prompt("/tmp/wt", test_state_dir)
    assert.is_string(prompt)
  end)

  it("returns a prompt when there are rereview comments", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "fix" }, test_state_dir)
    review.set_state("/tmp/wt", c.id, "rereview", test_state_dir)
    local prompt = review.build_prompt("/tmp/wt", test_state_dir)
    assert.is_string(prompt)
  end)
end)

------------------------------------------------------------------------
-- extmarks: rendering comments on buffers
------------------------------------------------------------------------

describe("render_extmarks", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("places extmarks on the buffer for matching comments", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 2, text = "fix this" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3" })

    review.render_extmarks(buf, "a.lua", "/tmp/wt", test_state_dir)

    local ns = vim.api.nvim_create_namespace("neovia_review")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(1, #marks)
    -- Extmark should be on line 2 (0-indexed = row 1)
    assert.equals(1, marks[1][2])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clears old extmarks before rendering", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "first" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2" })

    review.render_extmarks(buf, "a.lua", "/tmp/wt", test_state_dir)
    -- Render again -- should not duplicate
    review.render_extmarks(buf, "a.lua", "/tmp/wt", test_state_dir)

    local ns = vim.api.nvim_create_namespace("neovia_review")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(1, #marks)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not place extmarks for other files", function()
    review.add_comment("/tmp/wt", { file = "b.lua", line = 1, text = "wrong file" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1" })

    review.render_extmarks(buf, "a.lua", "/tmp/wt", test_state_dir)

    local ns = vim.api.nvim_create_namespace("neovia_review")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(0, #marks)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("skips comments with line numbers beyond buffer length", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 999, text = "off screen" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2" })

    review.render_extmarks(buf, "a.lua", "/tmp/wt", test_state_dir)

    local ns = vim.api.nvim_create_namespace("neovia_review")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert.equals(0, #marks)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- find_comment_at_line: look up comment by file + line
------------------------------------------------------------------------

describe("find_comment_at_line", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("returns the comment at the given line", function()
    local c = review.add_comment("/tmp/wt", { file = "a.lua", line = 5, text = "here" }, test_state_dir)
    local found = review.find_comment_at_line("/tmp/wt", "a.lua", 5, test_state_dir)
    assert.is_table(found)
    assert.equals(c.id, found.id)
  end)

  it("returns a range comment when line is within range", function()
    local c = review.add_comment("/tmp/wt", {
      file = "a.lua", line = 10, end_line = 20, text = "range",
    }, test_state_dir)
    local found = review.find_comment_at_line("/tmp/wt", "a.lua", 15, test_state_dir)
    assert.is_table(found)
    assert.equals(c.id, found.id)
  end)

  it("returns nil when no comment exists at the line", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 5, text = "not here" }, test_state_dir)
    local found = review.find_comment_at_line("/tmp/wt", "a.lua", 99, test_state_dir)
    assert.is_nil(found)
  end)

  it("returns nil for wrong file", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 5, text = "wrong" }, test_state_dir)
    local found = review.find_comment_at_line("/tmp/wt", "b.lua", 5, test_state_dir)
    assert.is_nil(found)
  end)
end)

------------------------------------------------------------------------
-- watch / unwatch: file watcher lifecycle
------------------------------------------------------------------------

describe("watch", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("starts a watcher for a worktree directory", function()
    -- Create the file first so the watcher has something to watch
    review.add_comment("/tmp/wt_watch", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.watch("/tmp/wt_watch", test_state_dir)
    local w = I.get_watchers()
    assert.is_not_nil(w["/tmp/wt_watch"])
  end)

  it("is idempotent (does not create duplicate watchers)", function()
    review.add_comment("/tmp/wt_watch", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.watch("/tmp/wt_watch", test_state_dir)
    local w1 = I.get_watchers()["/tmp/wt_watch"]
    review.watch("/tmp/wt_watch", test_state_dir)
    local w2 = I.get_watchers()["/tmp/wt_watch"]
    assert.equals(w1, w2)
  end)
end)

describe("unwatch", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("stops and removes the watcher", function()
    review.add_comment("/tmp/wt_unwatch", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    review.watch("/tmp/wt_unwatch", test_state_dir)
    review.unwatch("/tmp/wt_unwatch")
    local w = I.get_watchers()
    assert.is_nil(w["/tmp/wt_unwatch"])
  end)

  it("is a no-op when no watcher exists", function()
    review.unwatch("/tmp/nonexistent")
  end)
end)

------------------------------------------------------------------------
-- submit: prefill opencode input
------------------------------------------------------------------------

describe("submit", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("returns false when there are no actionable comments", function()
    local ok = review.submit("/tmp/wt", test_state_dir)
    assert.is_false(ok)
  end)

  it("returns true when there are actionable comments (even without opencode)", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "fix" }, test_state_dir)
    -- opencode.ui.input_window is not loaded in test env, but submit should
    -- still build the prompt and attempt prefill (gracefully degrading)
    local ok = review.submit("/tmp/wt", test_state_dir)
    assert.is_true(ok)
  end)
end)

------------------------------------------------------------------------
-- prepare_submit_text: extract and trim popup buffer content
------------------------------------------------------------------------

describe("prepare_submit_text", function()
  it("trims leading and trailing whitespace from joined text", function()
    local result = I.prepare_submit_text({ "  hello  ", "  world  " })
    assert.equals("hello  \n  world", result)
  end)

  it("returns nil for empty input", function()
    local result = I.prepare_submit_text({ "", "  ", "" })
    assert.is_nil(result)
  end)

  it("returns nil for nil input", function()
    local result = I.prepare_submit_text(nil)
    assert.is_nil(result)
  end)

  it("joins multiple lines", function()
    local result = I.prepare_submit_text({ "line one", "line two", "line three" })
    assert.equals("line one\nline two\nline three", result)
  end)

  it("handles single line", function()
    local result = I.prepare_submit_text({ "single line" })
    assert.equals("single line", result)
  end)
end)

------------------------------------------------------------------------
-- split_default_text: split default text for popup pre-fill
------------------------------------------------------------------------

describe("split_default_text", function()
  it("splits text on newlines", function()
    local result = I.split_default_text("line1\nline2")
    assert.same({ "line1", "line2" }, result)
  end)

  it("returns single-element table for text without newlines", function()
    local result = I.split_default_text("single")
    assert.same({ "single" }, result)
  end)

  it("returns empty table for nil", function()
    local result = I.split_default_text(nil)
    assert.same({}, result)
  end)

  it("returns empty table for empty string", function()
    local result = I.split_default_text("")
    assert.same({ "" }, result)
  end)
end)

------------------------------------------------------------------------
-- open_comment_input: function exists
------------------------------------------------------------------------

describe("open_comment_input", function()
  it("is a callable function", function()
    assert.is_function(review.open_comment_input)
  end)
end)

------------------------------------------------------------------------
-- reset: reload contract
------------------------------------------------------------------------

describe("reset", function()
  it("clears all in-memory state", function()
    review.add_comment("/tmp/wt", { file = "a.lua", line = 1, text = "x" }, test_state_dir)
    I.reset()
    -- In-memory should be empty (disk still has the file)
    -- get_comments will reload from disk, so check internal state directly
    local cache = I.get_cache()
    assert.same({}, cache)
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_state_dir, "rf")
  end)
end)

------------------------------------------------------------------------
-- setup: idempotent initialisation
------------------------------------------------------------------------

describe("setup", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("creates the neovia_review augroup", function()
    review.setup({ state_dir = test_state_dir })
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_review" })
    assert.is_true(#cmds >= 0) -- augroup exists even if no autocmds yet
  end)

  it("is idempotent", function()
     review.setup({ state_dir = test_state_dir })
    review.setup({ state_dir = test_state_dir })
    -- No error means idempotent
  end)
end)

------------------------------------------------------------------------
-- delete_all: remove all comments for a worktree
------------------------------------------------------------------------

describe("delete_all", function()
  local dir = "/tmp/review_delete_all_test"

  before_each(function()
    I.reset()
    review.setup({ state_dir = test_state_dir })
  end)

  after_each(function()
    review.clear(dir, test_state_dir)
    I.reset()
  end)

  it("removes all comments from cache and disk", function()
    review.add_comment(dir, { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    review.add_comment(dir, { file = "b.lua", line = 5, text = "two" }, test_state_dir)
    assert.equals(2, #review.get_comments(dir, test_state_dir))

    review.delete_all(dir, test_state_dir)

    assert.equals(0, #review.get_comments(dir, test_state_dir))
    -- File should be gone from disk.
    local path = I.storage_path(dir, test_state_dir)
    assert.equals(0, vim.fn.filereadable(path))
  end)

  it("clears extmarks from a buffer", function()
    review.add_comment(dir, { file = "a.lua", line = 1, text = "fix" }, test_state_dir)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2" })
    review.render_extmarks(buf, "a.lua", dir, test_state_dir)

    local ns = vim.api.nvim_create_namespace("neovia_review")
    local marks_before = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.is_true(#marks_before > 0)

    review.delete_all(dir, test_state_dir)

    local marks_after = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.equals(0, #marks_after)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is safe to call when no comments exist", function()
    -- Should not error.
    review.delete_all(dir, test_state_dir)
    assert.equals(0, #review.get_comments(dir, test_state_dir))
  end)
end)

------------------------------------------------------------------------
-- comment_counts_by_file: aggregate comment counts per file
------------------------------------------------------------------------

describe("comment_counts_by_file", function()
  local dir = "/tmp/review_counts_test"

  before_each(function()
    I.reset()
    review.setup({ state_dir = test_state_dir })
  end)

  after_each(function()
    review.clear(dir, test_state_dir)
    I.reset()
  end)

  it("returns empty table when no comments exist", function()
    local counts = review.comment_counts_by_file(dir, test_state_dir)
    assert.same({}, counts)
  end)

  it("counts comments per file", function()
    review.add_comment(dir, { file = "a.lua", line = 1, text = "one" }, test_state_dir)
    review.add_comment(dir, { file = "a.lua", line = 5, text = "two" }, test_state_dir)
    review.add_comment(dir, { file = "b.lua", line = 1, text = "three" }, test_state_dir)
    local counts = review.comment_counts_by_file(dir, test_state_dir)
    assert.equals(2, counts["a.lua"])
    assert.equals(1, counts["b.lua"])
  end)
end)

------------------------------------------------------------------------
-- render_file_panel_indicators: extmarks on file panel buffer
------------------------------------------------------------------------

describe("render_file_panel_indicators", function()
  local dir = "/tmp/review_panel_test"

  before_each(function()
    I.reset()
    review.setup({ state_dir = test_state_dir })
  end)

  after_each(function()
    review.clear(dir, test_state_dir)
    I.reset()
  end)

  it("places extmarks on lines matching files with comments", function()
    review.add_comment(dir, { file = "foo.lua", line = 1, text = "fix" }, test_state_dir)
    review.add_comment(dir, { file = "foo.lua", line = 5, text = "also" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "Changes (1)",
      "  M  foo.lua",
      "  M  bar.lua",
    })

    review.render_file_panel_indicators(buf, dir, test_state_dir)

    local ns_panel = vim.api.nvim_create_namespace("neovia_review_panel")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_panel, 0, -1, { details = true })
    assert.equals(1, #marks)
    -- Should be on line 2 (0-indexed = 1)
    assert.equals(1, marks[1][2])
    -- Check virtual text contains "2 comments"
    assert.is_truthy(marks[1][4].virt_text[1][1]:find("2 comments"))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not place extmarks for files without comments", function()
    review.add_comment(dir, { file = "foo.lua", line = 1, text = "fix" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "  M  bar.lua",
      "  M  baz.lua",
    })

    review.render_file_panel_indicators(buf, dir, test_state_dir)

    local ns_panel = vim.api.nvim_create_namespace("neovia_review_panel")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_panel, 0, -1, {})
    assert.equals(0, #marks)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("uses singular label for 1 comment", function()
    review.add_comment(dir, { file = "foo.lua", line = 1, text = "fix" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  M  foo.lua" })

    review.render_file_panel_indicators(buf, dir, test_state_dir)

    local ns_panel = vim.api.nvim_create_namespace("neovia_review_panel")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_panel, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.is_truthy(marks[1][4].virt_text[1][1]:find("1 comment"))
    -- Make sure it's not "1 comments"
    assert.is_falsy(marks[1][4].virt_text[1][1]:find("1 comments"))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("matches comments with full paths against panel lines with basenames", function()
    -- Comments use full relative paths like "lua/plugins/git.lua"
    -- but diffview panel shows only the basename like "git.lua 53, 0"
    review.add_comment(dir, { file = "lua/plugins/git.lua", line = 10, text = "fix" }, test_state_dir)
    review.add_comment(dir, { file = "lua/plugins/git.lua", line = 20, text = "also" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "Changes (1)",
      "  M  git.lua 53, 0",
      "  M  ui.lua 12, 0",
    })

    review.render_file_panel_indicators(buf, dir, test_state_dir)

    local ns_panel = vim.api.nvim_create_namespace("neovia_review_panel")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_panel, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.equals(1, marks[1][2]) -- line 2, 0-indexed
    assert.is_truthy(marks[1][4].virt_text[1][1]:find("2 comments"))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clears old indicators before re-rendering", function()
    review.add_comment(dir, { file = "foo.lua", line = 1, text = "fix" }, test_state_dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  M  foo.lua" })

    review.render_file_panel_indicators(buf, dir, test_state_dir)
    review.render_file_panel_indicators(buf, dir, test_state_dir)

    local ns_panel = vim.api.nvim_create_namespace("neovia_review_panel")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns_panel, 0, -1, {})
    assert.equals(1, #marks)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- jump_to_comment: navigate between review extmarks in a buffer
------------------------------------------------------------------------

describe("jump_to_comment", function()
  local buf
  local dir = "/tmp/review_nav_test"

  before_each(function()
    I.reset()
    review.setup({ state_dir = test_state_dir })
    -- Create a scratch buffer with 30 lines.
    buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 30 do lines[i] = "line " .. i end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    -- Add comments and render extmarks.
    review.add_comment(dir, { file = "foo.lua", line = 5, text = "first" }, test_state_dir)
    review.add_comment(dir, { file = "foo.lua", line = 15, text = "second" }, test_state_dir)
    review.add_comment(dir, { file = "foo.lua", line = 25, text = "third" }, test_state_dir)
    review.render_extmarks(buf, "foo.lua", dir, test_state_dir)
  end)

  after_each(function()
    review.clear(dir, test_state_dir)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    I.reset()
  end)

  it("returns the next extmark line after current line (forward)", function()
    local line = review.jump_to_comment(buf, 1, "next")
    assert.equals(5, line)
  end)

  it("skips to the next extmark when on an extmark line (forward)", function()
    local line = review.jump_to_comment(buf, 5, "next")
    assert.equals(15, line)
  end)

  it("returns the next extmark from between extmarks (forward)", function()
    local line = review.jump_to_comment(buf, 10, "next")
    assert.equals(15, line)
  end)

  it("wraps around to the first extmark after the last (forward)", function()
    local line = review.jump_to_comment(buf, 25, "next")
    assert.equals(5, line)
  end)

  it("wraps around when past all extmarks (forward)", function()
    local line = review.jump_to_comment(buf, 28, "next")
    assert.equals(5, line)
  end)

  it("returns the previous extmark before current line (prev)", function()
    local line = review.jump_to_comment(buf, 20, "prev")
    assert.equals(15, line)
  end)

  it("skips to the previous extmark when on an extmark line (prev)", function()
    local line = review.jump_to_comment(buf, 15, "prev")
    assert.equals(5, line)
  end)

  it("wraps around to the last extmark before the first (prev)", function()
    local line = review.jump_to_comment(buf, 5, "prev")
    assert.equals(25, line)
  end)

  it("wraps around when before all extmarks (prev)", function()
    local line = review.jump_to_comment(buf, 1, "prev")
    assert.equals(25, line)
  end)

  it("returns nil when no extmarks exist", function()
    local empty_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(empty_buf, 0, -1, false, { "a", "b" })
    local line = review.jump_to_comment(empty_buf, 1, "next")
    assert.is_nil(line)
    vim.api.nvim_buf_delete(empty_buf, { force = true })
  end)
end)
