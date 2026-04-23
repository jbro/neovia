-- tests/neovia/scratch_spec.lua
-- Unit tests for lua/neovia/scratch.lua

local scratch = require("neovia.scratch")
local I = scratch._internal

-- Use a unique temp dir for each test run to avoid collisions.
local test_state_dir = vim.fn.tempname() .. "_neovia_scratch_test"

local function cleanup_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

------------------------------------------------------------------------
-- storage_path: deterministic mapping from worktree dir to file path
------------------------------------------------------------------------

describe("storage_path", function()
  it("returns a path under state_dir using sha256 of the worktree dir", function()
    local dir = "/Users/me/projects/foo"
    local result = I.storage_path(dir, "/tmp/state")
    local hash = vim.fn.sha256(dir)
    assert.equals("/tmp/state/scratch/" .. hash .. ".md", result)
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
-- save_to_disk / load_from_disk
------------------------------------------------------------------------

describe("save_to_disk", function()
  after_each(function()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("creates parent directories and writes content", function()
    local path = test_state_dir .. "/scratch/test.md"
    I.save_to_disk(path, { "# Notes", "", "hello" })
    local lines = vim.fn.readfile(path)
    assert.same({ "# Notes", "", "hello" }, lines)
  end)

  it("overwrites existing content", function()
    local path = test_state_dir .. "/scratch/test.md"
    I.save_to_disk(path, { "old" })
    I.save_to_disk(path, { "new" })
    local lines = vim.fn.readfile(path)
    assert.same({ "new" }, lines)
  end)

  it("writes empty file for empty lines", function()
    local path = test_state_dir .. "/scratch/empty.md"
    I.save_to_disk(path, {})
    local lines = vim.fn.readfile(path)
    assert.same({}, lines)
  end)
end)

describe("load_from_disk", function()
  after_each(function()
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("reads lines from an existing file", function()
    local path = test_state_dir .. "/scratch/test.md"
    vim.fn.mkdir(test_state_dir .. "/scratch", "p")
    vim.fn.writefile({ "line1", "line2" }, path)
    local lines = I.load_from_disk(path)
    assert.same({ "line1", "line2" }, lines)
  end)

  it("returns nil for a non-existent file", function()
    local lines = I.load_from_disk(test_state_dir .. "/nope.md")
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
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("creates a listed buffer with the [scratch] name", function()
    local buf = scratch.get_or_create("/tmp/wt1", test_state_dir)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.is_true(vim.bo[buf].buflisted)
    local name = vim.api.nvim_buf_get_name(buf)
    assert.is_truthy(name:find("%[scratch%]$"))
    cleanup_buf(buf)
  end)

  it("sets filetype to markdown", function()
    local buf = scratch.get_or_create("/tmp/wt1", test_state_dir)
    assert.equals("markdown", vim.bo[buf].filetype)
    cleanup_buf(buf)
  end)

  it("sets the neovia_scratch buffer variable", function()
    local buf = scratch.get_or_create("/tmp/wt1", test_state_dir)
    assert.is_true(vim.b[buf].neovia_scratch)
    cleanup_buf(buf)
  end)

  it("returns the same buffer on repeated calls for the same dir", function()
    local buf1 = scratch.get_or_create("/tmp/wt1", test_state_dir)
    local buf2 = scratch.get_or_create("/tmp/wt1", test_state_dir)
    assert.equals(buf1, buf2)
    cleanup_buf(buf1)
  end)

  it("returns different buffers for different dirs", function()
    local buf1 = scratch.get_or_create("/tmp/wt1", test_state_dir)
    local buf2 = scratch.get_or_create("/tmp/wt2", test_state_dir)
    assert.are_not.equal(buf1, buf2)
    cleanup_buf(buf1)
    cleanup_buf(buf2)
  end)

  it("loads content from disk if file exists", function()
    -- Pre-populate disk
    local dir = "/tmp/wt_load_test"
    local path = I.storage_path(dir, test_state_dir)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "# Saved notes", "content" }, path)

    local buf = scratch.get_or_create(dir, test_state_dir)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.same({ "# Saved notes", "content" }, lines)
    cleanup_buf(buf)
  end)

  it("creates a buffer for the same dir if previous was wiped", function()
    local buf1 = scratch.get_or_create("/tmp/wt1", test_state_dir)
    vim.api.nvim_buf_delete(buf1, { force = true })
    local buf2 = scratch.get_or_create("/tmp/wt1", test_state_dir)
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
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("writes buffer content to disk", function()
    local buf = scratch.get_or_create("/tmp/wt_save", test_state_dir)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Test", "data" })

    scratch.save("/tmp/wt_save", test_state_dir)

    local path = I.storage_path("/tmp/wt_save", test_state_dir)
    local lines = vim.fn.readfile(path)
    assert.same({ "# Test", "data" }, lines)
    cleanup_buf(buf)
  end)

  it("is a no-op when no buffer exists for the dir", function()
    -- Should not error
    scratch.save("/tmp/nonexistent_wt", test_state_dir)
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
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("wipes the buffer and removes from tracking", function()
    local buf = scratch.get_or_create("/tmp/wt_wipe", test_state_dir)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    scratch.wipe("/tmp/wt_wipe")
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("allows creating a new buffer after wipe", function()
    local buf1 = scratch.get_or_create("/tmp/wt_wipe2", test_state_dir)
    scratch.wipe("/tmp/wt_wipe2")
    local buf2 = scratch.get_or_create("/tmp/wt_wipe2", test_state_dir)
    assert.are_not.equal(buf1, buf2)
    assert.is_true(vim.api.nvim_buf_is_valid(buf2))
    cleanup_buf(buf2)
  end)

  it("is a no-op when no buffer exists for the dir", function()
    scratch.wipe("/tmp/nonexistent_wt")
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
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("deletes the scratch file from disk", function()
    -- Create and save
    local buf = scratch.get_or_create("/tmp/wt_del", test_state_dir)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "doomed" })
    scratch.save("/tmp/wt_del", test_state_dir)

    local path = I.storage_path("/tmp/wt_del", test_state_dir)
    assert.equals(1, vim.fn.filereadable(path))

    scratch.delete_storage("/tmp/wt_del", test_state_dir)
    assert.equals(0, vim.fn.filereadable(path))
    cleanup_buf(buf)
  end)

  it("is a no-op when no file exists", function()
    scratch.delete_storage("/tmp/nonexistent_wt", test_state_dir)
  end)
end)

------------------------------------------------------------------------
-- is_scratch: identify scratch buffers
------------------------------------------------------------------------

describe("is_scratch", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns true for a scratch buffer", function()
    local buf = scratch.get_or_create("/tmp/wt_is", test_state_dir)
    assert.is_true(scratch.is_scratch(buf))
    cleanup_buf(buf)
  end)

  it("returns false for a normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    assert.is_false(scratch.is_scratch(buf))
    cleanup_buf(buf)
  end)

  it("returns false for an invalid buffer", function()
    assert.is_false(scratch.is_scratch(99999))
  end)
end)

------------------------------------------------------------------------
-- reset: reload contract
------------------------------------------------------------------------

describe("reset", function()
  it("clears all tracked buffers", function()
    I.reset()
    local buf = scratch.get_or_create("/tmp/wt_reset", test_state_dir)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))

    I.reset()

    -- After reset, get_or_create should create a new buffer
    local buf2 = scratch.get_or_create("/tmp/wt_reset", test_state_dir)
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
    vim.fn.delete(test_state_dir, "rf")
  end)

  it("creates the neovia_scratch augroup", function()
    scratch.setup({ state_dir = test_state_dir })
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_scratch" })
    assert.is_true(#cmds > 0)
  end)

  it("is idempotent", function()
    scratch.setup({ state_dir = test_state_dir })
    local cmds1 = vim.api.nvim_get_autocmds({ group = "neovia_scratch" })
    scratch.setup({ state_dir = test_state_dir })
    local cmds2 = vim.api.nvim_get_autocmds({ group = "neovia_scratch" })
    assert.equals(#cmds1, #cmds2)
  end)
end)
