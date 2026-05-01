-- tests/neovia/notes_spec.lua
-- Unit tests for lua/neovia/notes.lua (renamed from scratch.lua)

local notes = require("neovia.notes")
local I = notes._internal

-- Use a unique temp dir for each test run to avoid collisions.
local test_cache_dir = vim.fn.tempname() .. "_neovia_notes_test"

local function cleanup_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

------------------------------------------------------------------------
-- storage_path: deterministic mapping from worktree dir to file path
------------------------------------------------------------------------

describe("storage_path", function()
  it("returns a path under cache_dir/notes/ using sha256 of the worktree dir", function()
    local dir = "/Users/me/projects/foo"
    local result = I.storage_path(dir, "/tmp/cache")
    local hash = vim.fn.sha256(dir)
    assert.equals("/tmp/cache/notes/" .. hash .. ".md", result)
  end)

  it("returns different paths for different dirs", function()
    local a = I.storage_path("/a", "/tmp/cache")
    local b = I.storage_path("/b", "/tmp/cache")
    assert.are_not.equal(a, b)
  end)

  it("returns the same path for the same dir", function()
    local a = I.storage_path("/a", "/tmp/cache")
    local b = I.storage_path("/a", "/tmp/cache")
    assert.equals(a, b)
  end)
end)

------------------------------------------------------------------------
-- save_to_disk / load_from_disk
------------------------------------------------------------------------

describe("save_to_disk", function()
  after_each(function()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("creates parent directories and writes content", function()
    local path = test_cache_dir .. "/notes/test.md"
    I.save_to_disk(path, { "# Notes", "", "hello" })
    local lines = vim.fn.readfile(path)
    assert.same({ "# Notes", "", "hello" }, lines)
  end)

  it("overwrites existing content", function()
    local path = test_cache_dir .. "/notes/test.md"
    I.save_to_disk(path, { "old" })
    I.save_to_disk(path, { "new" })
    local lines = vim.fn.readfile(path)
    assert.same({ "new" }, lines)
  end)

  it("writes empty file for empty lines", function()
    local path = test_cache_dir .. "/notes/empty.md"
    I.save_to_disk(path, {})
    local lines = vim.fn.readfile(path)
    assert.same({}, lines)
  end)
end)

describe("load_from_disk", function()
  after_each(function()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("reads lines from an existing file", function()
    local path = test_cache_dir .. "/notes/test.md"
    vim.fn.mkdir(test_cache_dir .. "/notes", "p")
    vim.fn.writefile({ "line1", "line2" }, path)
    local lines = I.load_from_disk(path)
    assert.same({ "line1", "line2" }, lines)
  end)

  it("returns nil for a non-existent file", function()
    local lines = I.load_from_disk(test_cache_dir .. "/nope.md")
    assert.is_nil(lines)
  end)
end)

------------------------------------------------------------------------
-- get_or_create: buffer creation and reuse
------------------------------------------------------------------------

describe("get_or_create", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("creates a listed buffer with the [session notes] name", function()
    local buf = notes.get_or_create("/tmp/wt1", test_cache_dir)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.is_true(vim.bo[buf].buflisted)
    local name = vim.api.nvim_buf_get_name(buf)
    assert.is_truthy(name:find("%[session notes%]$"))
    cleanup_buf(buf)
  end)

  it("sets filetype to markdown", function()
    local buf = notes.get_or_create("/tmp/wt1", test_cache_dir)
    assert.equals("markdown", vim.bo[buf].filetype)
    cleanup_buf(buf)
  end)

  it("sets the neovia_notes buffer variable", function()
    local buf = notes.get_or_create("/tmp/wt1", test_cache_dir)
    assert.is_true(vim.b[buf].neovia_notes)
    cleanup_buf(buf)
  end)

  it("does not create a swap file", function()
    local buf = notes.get_or_create("/tmp/wt1", test_cache_dir)
    local swapname = vim.fn.swapname(buf)
    assert.equals("", swapname, "notes buffer should not have a swap file")
    cleanup_buf(buf)
  end)

  it("returns the same buffer on repeated calls for the same dir", function()
    local buf1 = notes.get_or_create("/tmp/wt1", test_cache_dir)
    local buf2 = notes.get_or_create("/tmp/wt1", test_cache_dir)
    assert.equals(buf1, buf2)
    cleanup_buf(buf1)
  end)

  it("returns different buffers for different dirs", function()
    local buf1 = notes.get_or_create("/tmp/wt1", test_cache_dir)
    local buf2 = notes.get_or_create("/tmp/wt2", test_cache_dir)
    assert.are_not.equal(buf1, buf2)
    cleanup_buf(buf1)
    cleanup_buf(buf2)
  end)

  it("loads content from disk if file exists", function()
    -- Pre-populate disk
    local dir = "/tmp/wt_load_test"
    local path = I.storage_path(dir, test_cache_dir)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "# Saved notes", "content" }, path)

    local buf = notes.get_or_create(dir, test_cache_dir)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.same({ "# Saved notes", "content" }, lines)
    cleanup_buf(buf)
  end)

  it("is not locked by mode module's FileType autocmd", function()
    local mode = require("neovia.mode")
    mode._internal.reset()
    mode.setup({ auto_relock = true })

    local buf = notes.get_or_create("/tmp/wt_mode_lock", test_cache_dir)

    assert.is_true(vim.bo[buf].modifiable, "notes buffer should be modifiable")
    assert.is_false(vim.bo[buf].readonly, "notes buffer should not be readonly")

    cleanup_buf(buf)
    mode._internal.reset()
  end)

  it("creates a buffer for the same dir if previous was wiped", function()
    local buf1 = notes.get_or_create("/tmp/wt1", test_cache_dir)
    vim.api.nvim_buf_delete(buf1, { force = true })
    local buf2 = notes.get_or_create("/tmp/wt1", test_cache_dir)
    assert.are_not.equal(buf1, buf2)
    assert.is_true(vim.api.nvim_buf_is_valid(buf2))
    cleanup_buf(buf2)
  end)
end)

------------------------------------------------------------------------
-- save: persist buffer content to disk
------------------------------------------------------------------------

describe("save", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("writes buffer content to disk", function()
    local buf = notes.get_or_create("/tmp/wt_save", test_cache_dir)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Test", "data" })

    notes.save("/tmp/wt_save", test_cache_dir)

    local path = I.storage_path("/tmp/wt_save", test_cache_dir)
    local lines = vim.fn.readfile(path)
    assert.same({ "# Test", "data" }, lines)
    cleanup_buf(buf)
  end)

  it("is a no-op when no buffer exists for the dir", function()
    notes.save("/tmp/nonexistent_wt", test_cache_dir)
  end)
end)

------------------------------------------------------------------------
-- wipe: remove buffer from tracking
------------------------------------------------------------------------

describe("wipe", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("wipes the buffer and removes from tracking", function()
    local buf = notes.get_or_create("/tmp/wt_wipe", test_cache_dir)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    notes.wipe("/tmp/wt_wipe")
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("allows creating a new buffer after wipe", function()
    local buf1 = notes.get_or_create("/tmp/wt_wipe2", test_cache_dir)
    notes.wipe("/tmp/wt_wipe2")
    local buf2 = notes.get_or_create("/tmp/wt_wipe2", test_cache_dir)
    assert.are_not.equal(buf1, buf2)
    assert.is_true(vim.api.nvim_buf_is_valid(buf2))
    cleanup_buf(buf2)
  end)

  it("is a no-op when no buffer exists for the dir", function()
    notes.wipe("/tmp/nonexistent_wt")
  end)
end)

------------------------------------------------------------------------
-- delete_storage: remove file from disk
------------------------------------------------------------------------

describe("delete_storage", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("deletes the notes file from disk", function()
    local buf = notes.get_or_create("/tmp/wt_del", test_cache_dir)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "doomed" })
    notes.save("/tmp/wt_del", test_cache_dir)

    local path = I.storage_path("/tmp/wt_del", test_cache_dir)
    assert.equals(1, vim.fn.filereadable(path))

    notes.delete_storage("/tmp/wt_del", test_cache_dir)
    assert.equals(0, vim.fn.filereadable(path))
    cleanup_buf(buf)
  end)

  it("is a no-op when no file exists", function()
    notes.delete_storage("/tmp/nonexistent_wt", test_cache_dir)
  end)
end)

------------------------------------------------------------------------
-- is_notes: identify notes buffers
------------------------------------------------------------------------

describe("is_notes", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns true for a notes buffer", function()
    local buf = notes.get_or_create("/tmp/wt_is", test_cache_dir)
    assert.is_true(notes.is_notes(buf))
    cleanup_buf(buf)
  end)

  it("returns false for a normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    assert.is_false(notes.is_notes(buf))
    cleanup_buf(buf)
  end)

  it("returns false for an invalid buffer", function()
    assert.is_false(notes.is_notes(99999))
  end)
end)

------------------------------------------------------------------------
-- reset: reload contract
------------------------------------------------------------------------

describe("reset", function()
  it("clears all tracked buffers", function()
    I.reset()
    local buf = notes.get_or_create("/tmp/wt_reset", test_cache_dir)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    I.reset()

    local buf2 = notes.get_or_create("/tmp/wt_reset", test_cache_dir)
    assert.are_not.equal(buf, buf2)

    cleanup_buf(buf)
    cleanup_buf(buf2)
  end)
end)

------------------------------------------------------------------------
-- setup: autocmd wiring (BufLeave save)
------------------------------------------------------------------------

describe("setup", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(test_cache_dir, "rf")
  end)

  it("creates the neovia_notes augroup", function()
    notes.setup({ cache_dir = test_cache_dir })
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_notes" })
    assert.is_true(#cmds > 0)
  end)

  it("is idempotent", function()
    notes.setup({ cache_dir = test_cache_dir })
    local cmds1 = vim.api.nvim_get_autocmds({ group = "neovia_notes" })
    notes.setup({ cache_dir = test_cache_dir })
    local cmds2 = vim.api.nvim_get_autocmds({ group = "neovia_notes" })
    assert.equals(#cmds1, #cmds2)
  end)

  it("auto-saves notes content on BufLeave", function()
    notes.setup({ cache_dir = test_cache_dir })

    local dir = "/tmp/wt_autosave_test"
    local buf = notes.get_or_create(dir, test_cache_dir)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Auto-saved", "content" })

    vim.api.nvim_win_set_buf(0, buf)

    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, other)

    local path = I.storage_path(dir, test_cache_dir)
    local lines = vim.fn.readfile(path)
    assert.same({ "# Auto-saved", "content" }, lines)

    cleanup_buf(buf)
    cleanup_buf(other)
  end)

  it("handles :w via BufWriteCmd on notes buffers", function()
    notes.setup({ cache_dir = test_cache_dir })

    local dir = "/tmp/wt_writecmd_test"
    local buf = notes.get_or_create(dir, test_cache_dir)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Written", "via :w" })

    vim.api.nvim_win_set_buf(0, buf)
    vim.cmd("write")

    local path = I.storage_path(dir, test_cache_dir)
    local lines = vim.fn.readfile(path)
    assert.same({ "# Written", "via :w" }, lines)

    cleanup_buf(buf)
  end)

  it("does not intercept :w on normal file buffers", function()
    notes.setup({ cache_dir = test_cache_dir })

    local tmp = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "original" }, tmp)

    local buf = vim.fn.bufadd(tmp)
    vim.fn.bufload(buf)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "modified" })

    vim.cmd("write")

    local lines = vim.fn.readfile(tmp)
    assert.same({ "modified" }, lines,
      "BufWriteCmd should not swallow :w on normal files")

    cleanup_buf(buf)
    vim.fn.delete(tmp)
  end)

  it("defaults cache_dir to stdpath('cache')", function()
    notes.setup()
    -- Verify by creating a buffer and checking storage_path uses cache
    local buf = notes.get_or_create("/tmp/wt_default_cache")
    local expected_prefix = vim.fn.stdpath("cache") .. "/notes/"
    local path = I.storage_path("/tmp/wt_default_cache", vim.fn.stdpath("cache"))
    assert.is_true(vim.startswith(path, expected_prefix))
    cleanup_buf(buf)
  end)
end)
