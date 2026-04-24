-- neovia mode module
-- Read-only mode: buffers open locked by default, toggle with <leader>bu.

local M = {}

--- Buftypes that should never be locked.
local skip_buftypes = {
  terminal = true,
  help = true,
  quickfix = true,
  nofile = true,
  prompt = true,
  acwrite = true,
}

--- Filetypes that should never be locked.
local skip_filetypes = {
  gitcommit = true,
  fugitive = true,
  ["neo-tree"] = true,
  opencode = true,
  opencode_output = true,
  opencode_footer = true,
  DiffviewFiles = true,
  DiffviewFileHistory = true,
}

--- @class neovia.ModeOpts
--- @field auto_relock? boolean Re-lock buffer on BufLeave (default true)

--- @type neovia.ModeOpts
local opts = { auto_relock = true }

--- Set of buffer numbers currently unlocked by the user.
--- @type table<integer, boolean>
local unlocked = {}

--- Whether setup() has been called.
local initialised = false

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

--- Determine whether a buffer should be locked based on buftype/filetype.
--- @param info { buftype: string, filetype: string, neovia_scratch?: boolean }
--- @return boolean
local function should_lock(info)
  if skip_buftypes[info.buftype] then return false end
  if skip_filetypes[info.filetype] then return false end
  if info.neovia_scratch then return false end
  return true
end

------------------------------------------------------------------------
-- Buffer operations
------------------------------------------------------------------------

--- Lock a buffer (set readonly + nomodifiable).
--- @param buf integer
local function lock_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  unlocked[buf] = nil
end

--- Unlock a buffer (clear readonly + modifiable).
--- @param buf integer
local function unlock_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  unlocked[buf] = true
end

--- Toggle lock state on a buffer. No-op for special buffers.
--- @param buf integer
local function toggle(buf)
  local info = {
    buftype = vim.bo[buf].buftype,
    filetype = vim.bo[buf].filetype,
    neovia_scratch = vim.b[buf].neovia_scratch or false,
  }
  if not should_lock(info) then return end
  if vim.bo[buf].readonly then
    unlock_buf(buf)
  else
    lock_buf(buf)
  end
end

--- Re-lock a buffer if it was previously unlocked (for BufLeave auto-relock).
--- @param buf integer
local function relock_buf(buf)
  if not opts.auto_relock then return end
  if not unlocked[buf] then return end
  lock_buf(buf)
end

------------------------------------------------------------------------
-- Autocmd: lock new buffers
------------------------------------------------------------------------

--- Apply lock to a buffer if it should be locked.
--- Called on BufReadPost, BufNewFile, and FileType.
--- @param buf integer
local function apply_lock(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local info = {
    buftype = vim.bo[buf].buftype,
    filetype = vim.bo[buf].filetype,
    neovia_scratch = vim.b[buf].neovia_scratch or false,
  }
  if should_lock(info) and not unlocked[buf] then
    lock_buf(buf)
  end
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Setup the mode module. Idempotent.
--- @param user_opts? neovia.ModeOpts
function M.setup(user_opts)
  if initialised then return end
  initialised = true

  user_opts = user_opts or {}
  opts.auto_relock = user_opts.auto_relock ~= false -- default true

  local group = vim.api.nvim_create_augroup("neovia_mode", { clear = true })

  -- Lock buffers as they're opened
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(ev) apply_lock(ev.buf) end,
  })

  -- Also lock on FileType in case buftype/filetype changes after load
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev) apply_lock(ev.buf) end,
  })

  -- Auto-relock on BufLeave
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    callback = function(ev) relock_buf(ev.buf) end,
  })

  -- Clean up tracking state when buffers are deleted
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(ev) unlocked[ev.buf] = nil end,
  })
end

--- Toggle read-only mode on the current buffer.
--- When called from a floating or special-buftype window (e.g. which-key
--- popup), falls back to the code window's buffer so the toggle reaches
--- the file the user is looking at.
function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  local info = {
    buftype = vim.bo[buf].buftype,
    filetype = vim.bo[buf].filetype,
    neovia_scratch = vim.b[buf].neovia_scratch or false,
  }
  if not should_lock(info) then
    -- Current buffer is special (float, nofile, etc.).  Try the code window.
    local ok, nav = pcall(require, "neovia.navigate")
    if ok then
      local code_win = nav.find_code_win()
      if code_win then
        buf = vim.api.nvim_win_get_buf(code_win)
      end
    end
  end
  toggle(buf)
end

--- Check whether a buffer is currently locked.
--- Returns false for special buffers (they are never considered locked).
--- @param buf integer
--- @return boolean
function M.is_locked(buf)
  local info = {
    buftype = vim.bo[buf].buftype,
    filetype = vim.bo[buf].filetype,
    neovia_scratch = vim.b[buf].neovia_scratch or false,
  }
  if not should_lock(info) then return false end
  return vim.bo[buf].readonly
end

--- Vim mode map (same labels as lualine's built-in mode component).
local vim_mode_map = {
  n = "NORMAL", no = "O-PENDING", nov = "O-PENDING", noV = "O-PENDING",
  ["no\22"] = "O-PENDING", niI = "NORMAL", niR = "NORMAL", niV = "NORMAL",
  nt = "NORMAL", ntT = "NORMAL",
  v = "VISUAL", vs = "VISUAL", V = "V-LINE", Vs = "V-LINE",
  ["\22"] = "V-BLOCK", ["\22s"] = "V-BLOCK",
  s = "SELECT", S = "S-LINE", ["\19"] = "S-BLOCK",
  i = "INSERT", ic = "INSERT", ix = "INSERT",
  R = "REPLACE", Rc = "REPLACE", Rx = "REPLACE", Rv = "V-REPLACE",
  Rvc = "V-REPLACE", Rvx = "V-REPLACE",
  c = "COMMAND", cv = "EX", ce = "EX",
  r = "REPLACE", rm = "MORE", ["r?"] = "CONFIRM",
  ["!"] = "SHELL", t = "TERMINAL",
}

--- Lualine mode component: shows READ-ONLY when buffer is read-only,
--- otherwise falls back to the standard vim mode label.
--- Replaces lualine's built-in "mode" in lualine_a.
--- @param buf? integer  Buffer handle (defaults to current buffer).
--- @return string
function M.lualine_mode(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local info = {
    buftype = vim.bo[buf].buftype,
    filetype = vim.bo[buf].filetype,
    neovia_scratch = vim.b[buf].neovia_scratch or false,
  }
  if should_lock(info) and vim.bo[buf].readonly then
    return "READ-ONLY"
  end
  local m = vim.api.nvim_get_mode().mode
  return vim_mode_map[m] or m:upper()
end

--- Set the auto_relock option at runtime.
--- @param value boolean
function M.set_auto_relock(value)
  opts.auto_relock = value
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  should_lock = should_lock,

  --- Toggle with explicit buffer (for testing).
  --- @param buf integer
  toggle = toggle,

  --- Check if buffer is tracked as unlocked.
  --- @param buf integer
  --- @return boolean
  is_unlocked = function(buf) return unlocked[buf] == true end,

  --- Get auto_relock setting.
  --- @return boolean
  get_auto_relock = function() return opts.auto_relock end,

  --- Relock a buffer (for testing BufLeave behavior).
  --- @param buf integer
  relock_buf = relock_buf,

  --- Apply lock to a buffer (for testing BufReadPost/FileType behavior).
  --- @param buf integer
  apply_lock = apply_lock,

  --- Setup with reset support (for tests).
  --- @param user_opts? neovia.ModeOpts
  setup = function(user_opts)
    user_opts = user_opts or {}
    opts.auto_relock = user_opts.auto_relock ~= false
  end,

  --- Reset module state (for test isolation).
  reset = function()
    unlocked = {}
    initialised = false
    opts = { auto_relock = true }
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_mode")
  end,
}

return M
