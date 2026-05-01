-- neovia notes module
-- Per-worktree session notes buffer: persistent markdown notes.

local M = {}

local initialised = false

--- Tracked notes buffers, keyed by worktree dir.
--- @type table<string, integer>
local buffers = {}

--- Reverse lookup: buffer handle -> worktree dir.
--- @type table<integer, string>
local buf_to_dir = {}

--- Configured cache directory (set via setup()).
--- @type string
local cache_dir = ""

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

local ok_fs, fs = pcall(require, "neovia.fs")

--- Compute the on-disk storage path for a worktree's notes file.
--- @param dir string  Absolute worktree path.
--- @param cdir string  Cache directory root.
--- @return string
local function storage_path(dir, cdir)
  local hash = vim.fn.sha256(dir)
  return cdir .. "/notes/" .. hash .. ".md"
end

--- Write lines to a file, creating parent directories.
--- @param path string
--- @param lines string[]
local function save_to_disk(path, lines)
  local parent = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(parent, "p")
  if ok_fs then
    fs.write_file(path, table.concat(lines, "\n"))
  else
    vim.fn.writefile(lines, path)
  end
end

--- Read lines from a file. Returns nil if the file does not exist.
--- @param path string
--- @return string[]?
local function load_from_disk(path)
  if ok_fs then
    local raw = fs.read_file(path)
    if not raw then return nil end
    return vim.split(raw, "\n", { plain = true })
  end
  if vim.fn.filereadable(path) ~= 1 then return nil end
  return vim.fn.readfile(path)
end

------------------------------------------------------------------------
-- Buffer management
------------------------------------------------------------------------

--- Get or create a notes buffer for a worktree directory.
--- Loads persisted content from disk if available.
--- @param dir string  Absolute worktree path.
--- @param cdir? string  Override cache directory (for testing).
--- @return integer buf  Buffer handle.
function M.get_or_create(dir, cdir)
  cdir = cdir or cache_dir

  -- Return existing buffer if still valid.
  local existing = buffers[dir]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  -- Create a new unlisted buffer. Unlisted keeps notes out of :bn/:bp/:ls
  -- so they cannot accidentally be cycled to in other windows.
  local buf = vim.api.nvim_create_buf(false, false)

  -- Set buftype and disable swap BEFORE setting the name.
  -- If the name is set first, Neovim creates a swap file for it;
  -- a stale swap from a previous session then triggers E325.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false

  -- Set a virtual name so lualine and :ls show [session notes].
  vim.api.nvim_buf_set_name(buf, dir .. "/[session notes]")

  -- Load content from disk.
  local path = storage_path(dir, cdir)
  local lines = load_from_disk(path)
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  -- Configure buffer.
  -- Set notes flag BEFORE filetype: setting filetype fires the FileType
  -- autocmd, and mode.apply_lock() must see this exemption to avoid locking
  -- the notes buffer.
  vim.b[buf].neovia_notes = true
  vim.bo[buf].filetype = "markdown"

  -- Mark as not modified (content matches disk or is empty).
  vim.bo[buf].modified = false

  -- Handle :w on this notes buffer (buftype=acwrite requires BufWriteCmd).
  -- Registered per-buffer so normal file writes are not intercepted.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = vim.api.nvim_create_augroup("neovia_notes", { clear = false }),
    buffer = buf,
    callback = function()
      local d = buf_to_dir[buf]
      if d then M.save(d) end
    end,
  })

  buffers[dir] = buf
  buf_to_dir[buf] = dir
  return buf
end

--- Save a notes buffer's content to disk.
--- No-op if no buffer exists for the directory.
--- @param dir string  Absolute worktree path.
--- @param cdir? string  Override cache directory (for testing).
function M.save(dir, cdir)
  cdir = cdir or cache_dir

  local buf = buffers[dir]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local path = storage_path(dir, cdir)
  save_to_disk(path, lines)
  vim.bo[buf].modified = false
end

--- Wipe a notes buffer and remove from tracking.
--- No-op if no buffer exists for the directory.
--- @param dir string  Absolute worktree path.
function M.wipe(dir)
  local buf = buffers[dir]
  buffers[dir] = nil
  if buf then
    buf_to_dir[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

--- Delete the notes file from disk for a worktree.
--- @param dir string  Absolute worktree path.
--- @param cdir? string  Override cache directory (for testing).
function M.delete_storage(dir, cdir)
  cdir = cdir or cache_dir
  local path = storage_path(dir, cdir)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

--- Check whether a buffer is a notes buffer.
--- @param buf integer
--- @return boolean
function M.is_notes(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  return vim.b[buf].neovia_notes == true
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- @class neovia.NotesOpts
--- @field cache_dir? string  Override cache directory (default: stdpath("cache")).

--- Initialise the notes module. Registers BufLeave autocmd for auto-save.
--- @param opts? neovia.NotesOpts
function M.setup(opts)
  if initialised then return end
  initialised = true

  opts = opts or {}
  cache_dir = opts.cache_dir or vim.fn.stdpath("cache")

  local group = vim.api.nvim_create_augroup("neovia_notes", { clear = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function(ev)
      local dir = buf_to_dir[ev.buf]
      if dir then M.save(dir) end
    end,
  })

  -- Mark windows that display a notes buffer so the BufEnter guard
  -- knows which windows are notes windows.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].neovia_notes then
        local win = vim.api.nvim_get_current_win()
        vim.w[win].neovia_notes_buf = ev.buf
      end
    end,
  })

  -- Guard: eject non-notes buffers from the notes window.
  -- When a buffer enters a window marked as a notes window
  -- (via vim.w.neovia_notes_buf, set by BufWinEnter above),
  -- move the intruder to the code window and restore the notes buffer.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].neovia_notes then return end

      local win = vim.api.nvim_get_current_win()
      if not vim.api.nvim_win_is_valid(win) then return end

      local expected = vim.w[win].neovia_notes_buf
      if not expected then return end
      if not vim.api.nvim_buf_is_valid(expected) then
        vim.w[win].neovia_notes_buf = nil
        return
      end

      -- Eject: move the intruder to the code window.
      local ok_nav, navigate = pcall(require, "neovia.navigate")
      if ok_nav then
        local code_win = navigate.find_code_win()
        if code_win and code_win ~= win then
          vim.api.nvim_win_set_buf(code_win, ev.buf)
        end
      end

      -- Restore the notes buffer in this window.
      vim.api.nvim_win_set_buf(win, expected)
    end,
  })

  -- NOTE: BufWriteCmd for notes buffers is registered per-buffer in
  -- get_or_create(), not globally.  A global BufWriteCmd would swallow
  -- :w on every buffer, preventing normal file writes.
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  storage_path = storage_path,
  save_to_disk = save_to_disk,
  load_from_disk = load_from_disk,

  --- Reset all state: clear tracked buffers, augroup, initialised flag.
  reset = function()
    -- Wipe all tracked buffers.
    for dir, buf in pairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      buffers[dir] = nil
    end
    buffers = {}
    buf_to_dir = {}
    initialised = false
    cache_dir = ""
    pcall(vim.api.nvim_create_augroup, "neovia_notes", { clear = true })
  end,
}

return M
