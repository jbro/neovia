-- neovia layout module
-- Enforce the two-panel layout: code window (left) + opencode (right).
-- Restores missing panels on WinClosed and opens opencode on VimEnter.

local M = {}

local initialised = false
local opencode_opener = nil

------------------------------------------------------------------------
-- Window detection
------------------------------------------------------------------------

--- Find a non-floating opencode window. Returns nil if none found.
--- @return integer?
local function find_opencode_win()
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return nil end

  local wins = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win)
      and navigate.is_opencode_win(win)
      and vim.api.nvim_win_get_config(win).relative == ""
    then
      return win
    end
  end
  return nil
end

------------------------------------------------------------------------
-- Layout enforcement
------------------------------------------------------------------------

--- Open opencode using the configured opener or the real API.
local function open_opencode()
  if opencode_opener then
    opencode_opener()
  else
    local ok, api = pcall(require, "opencode.api")
    if ok then api.toggle() end
  end
end

--- Check the window layout and restore any missing panel.
--- If no code window exists, create one with netrw for cwd.
--- If no opencode window exists, reopen it.
local function ensure_layout()
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  if not navigate.find_code_win() then
    local ok, err = pcall(navigate.open_dir, vim.fn.getcwd())
    if not ok then
      vim.notify("layout: failed to restore code window: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  if not find_opencode_win() then
    local ok, err = pcall(open_opencode)
    if not ok then
      vim.notify("layout: failed to restore opencode: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

------------------------------------------------------------------------
-- Restore layout
------------------------------------------------------------------------

--- Nuke all windows and rebuild the canonical two-panel layout.
--- Remembers the buffer that was in the code window and restores it.
--- Falls back to netrw (cwd) if no code buffer was showing.
function M.restore_layout()
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  -- Remember the buffer in the code window (if any)
  local code_win = navigate.find_code_win()
  local code_buf = nil
  if code_win then
    code_buf = vim.api.nvim_win_get_buf(code_win)
  end

  -- Collapse to one window, then let opencode set up its panels.
  -- open_opencode may clobber the current buffer, so we restore
  -- the code buffer *after* it finishes.
  vim.cmd("only")
  open_opencode()

  -- Find or create the code window, then put the remembered buffer in it.
  local new_code_win = navigate.find_code_win()
  if not new_code_win then
    navigate.open_dir(vim.fn.getcwd())
    new_code_win = navigate.find_code_win()
  end
  if new_code_win then
    if code_buf and vim.api.nvim_buf_is_valid(code_buf) then
      vim.api.nvim_win_set_buf(new_code_win, code_buf)
    end
    vim.api.nvim_set_current_win(new_code_win)
  end

  -- Clean up any stray [No Name] listed buffers left behind
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
      and vim.api.nvim_buf_get_name(b) == ""
      and vim.api.nvim_buf_line_count(b) <= 1
    then
      local lines = vim.api.nvim_buf_get_lines(b, 0, 1, false)
      if #lines == 0 or lines[1] == "" then
        -- Not shown in any window -- safe to wipe
        local in_use = false
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(w) == b then
            in_use = true
            break
          end
        end
        if not in_use then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
  end
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- Initialise the layout module. Registers autocmds for:
--- - WinClosed: restore missing panels after any window closes.
--- - VimEnter: open the opencode panel on startup.
function M.setup()
  if initialised then return end
  initialised = true

  local group = vim.api.nvim_create_augroup("neovia_layout", { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      vim.schedule(ensure_layout)
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        open_opencode()
      end)
    end,
  })
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  find_opencode_win = find_opencode_win,
  ensure_layout = ensure_layout,

  --- Set a custom opencode opener (for testing). Pass nil to clear.
  --- @param fn function?
  set_opencode_opener = function(fn)
    opencode_opener = fn
  end,

  --- Reset all state: clear augroup, reset initialised flag.
  reset = function()
    initialised = false
    opencode_opener = nil
    pcall(vim.api.nvim_create_augroup, "neovia_layout", { clear = true })
  end,
}

return M
