-- neovia scratch module
-- Per-worktree scratch buffer: persistent markdown notes in the code window.

local M = {}

local initialised = false

--- Tracked scratch buffers, keyed by worktree dir.
--- @type table<string, integer>
local buffers = {}

--- Reverse lookup: buffer handle -> worktree dir.
--- @type table<integer, string>
local buf_to_dir = {}

--- Configured state directory (set via setup()).
--- @type string
local state_dir = ""

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

local ok_fs, fs = pcall(require, "neovia.fs")

--- Compute the on-disk storage path for a worktree's scratch file.
--- @param dir string  Absolute worktree path.
--- @param sdir string  State directory root.
--- @return string
local function storage_path(dir, sdir)
  local hash = vim.fn.sha256(dir)
  return sdir .. "/scratch/" .. hash .. ".md"
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

--- Get or create a scratch buffer for a worktree directory.
--- Loads persisted content from disk if available.
--- @param dir string  Absolute worktree path.
--- @param sdir? string  Override state directory (for testing).
--- @return integer buf  Buffer handle.
function M.get_or_create(dir, sdir)
  sdir = sdir or state_dir

  -- Return existing buffer if still valid.
  local existing = buffers[dir]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  -- Create a new listed buffer.
  local buf = vim.api.nvim_create_buf(true, false)

  -- Set buftype and disable swap BEFORE setting the name.
  -- If the name is set first, Neovim creates a swap file for it;
  -- a stale swap from a previous session then triggers E325.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false

  -- Set a virtual name so lualine and :ls show [scratch].
  vim.api.nvim_buf_set_name(buf, dir .. "/[scratch]")

  -- Load content from disk.
  local path = storage_path(dir, sdir)
  local lines = load_from_disk(path)
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  -- Configure buffer.
  -- Set scratch flag BEFORE filetype: setting filetype fires the FileType
  -- autocmd, and mode.apply_lock() must see this exemption to avoid locking
  -- the scratch buffer.
  vim.b[buf].neovia_scratch = true
  vim.bo[buf].filetype = "markdown"

  -- Mark as not modified (content matches disk or is empty).
  vim.bo[buf].modified = false

  -- Handle :w on this scratch buffer (buftype=acwrite requires BufWriteCmd).
  -- Registered per-buffer so normal file writes are not intercepted.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = vim.api.nvim_create_augroup("neovia_scratch", { clear = false }),
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

--- Save a scratch buffer's content to disk.
--- No-op if no buffer exists for the directory.
--- @param dir string  Absolute worktree path.
--- @param sdir? string  Override state directory (for testing).
function M.save(dir, sdir)
  sdir = sdir or state_dir

  local buf = buffers[dir]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local path = storage_path(dir, sdir)
  save_to_disk(path, lines)
  vim.bo[buf].modified = false
end

--- Wipe a scratch buffer and remove from tracking.
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

--- Delete the scratch file from disk for a worktree.
--- @param dir string  Absolute worktree path.
--- @param sdir? string  Override state directory (for testing).
function M.delete_storage(dir, sdir)
  sdir = sdir or state_dir
  local path = storage_path(dir, sdir)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

--- Check whether a buffer is a scratch buffer.
--- @param buf integer
--- @return boolean
function M.is_scratch(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  return vim.b[buf].neovia_scratch == true
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- @class neovia.ScratchOpts
--- @field state_dir? string  Override state directory (default: stdpath("state")).

--- Initialise the scratch module. Registers BufLeave autocmd for auto-save.
--- @param opts? neovia.ScratchOpts
function M.setup(opts)
  if initialised then return end
  initialised = true

  opts = opts or {}
  state_dir = opts.state_dir or vim.fn.stdpath("state")

  local group = vim.api.nvim_create_augroup("neovia_scratch", { clear = true })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function(ev)
      local dir = buf_to_dir[ev.buf]
      if dir then M.save(dir) end
    end,
  })

  -- NOTE: BufWriteCmd for scratch buffers is registered per-buffer in
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
    state_dir = ""
    pcall(vim.api.nvim_create_augroup, "neovia_scratch", { clear = true })
  end,
}

return M
