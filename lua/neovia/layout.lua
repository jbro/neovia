-- neovia layout module
-- Enforce the four-panel layout:
--   neo-tree (left) | code (centre top)    | opencode (right)
--                   | session notes (bot)  |
-- Restores missing panels on WinClosed and opens opencode on VimEnter.

local M = {}

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------

--- Neo-tree sidebar width in columns.
M.sidebar_width = 35

--- Opencode's share of the available space (after sidebar) as a fraction.
M.opencode_ratio = 0.50

--- Session notes window height in lines.
M.notes_height = 15

--- Compute the opencode window_width ratio relative to total editor columns.
--- opencode.nvim interprets window_width as a fraction of vim.o.columns,
--- so we convert: opencode gets opencode_ratio of (columns - sidebar_width).
--- @param columns? integer  Total editor columns (defaults to vim.o.columns).
--- @return number  Ratio suitable for opencode's window_width config.
function M.opencode_width_ratio(columns)
  columns = columns or vim.o.columns
  return M.opencode_ratio * (columns - M.sidebar_width) / columns
end

------------------------------------------------------------------------

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

--- Find the neo-tree sidebar window. Returns nil if none found.
--- @return integer?
local function find_neo_tree_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ""
    then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "neo-tree" then return win end
    end
  end
  return nil
end

--- Check whether a neo-tree sidebar window exists.
--- @return boolean
local function has_neo_tree_win()
  return find_neo_tree_win() ~= nil
end

--- Create a code window with a noname buffer between neo-tree and opencode.
--- Uses nvim_open_win with split to avoid focus changes and race conditions.
--- @return integer win  The new window handle.
local function create_code_win()
  local buf = vim.api.nvim_create_buf(false, true)
  local tree_win = find_neo_tree_win()
  if tree_win then
    return vim.api.nvim_open_win(buf, false, { split = "right", win = tree_win })
  end
  -- No neo-tree: split at the far left (least likely in practice).
  return vim.api.nvim_open_win(buf, false, { split = "left", win = 0 })
end

--- Set the notes window to the canonical height and lock it.
--- Safe to call at any time; no-op if no notes window exists.
function M.enforce_notes_height()
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  local notes_win = navigate.find_notes_win()
  if not notes_win then return end

  vim.api.nvim_win_set_height(notes_win, M.notes_height)
  vim.wo[notes_win].winfixheight = true
end

--- Open the session notes buffer in a horizontal split below the code window.
--- Creates the split if no notes window exists. Re-enforces height if one does.
--- @param code_win integer  The code window to split below.
local function open_notes_split(code_win)
  local ok_notes, notes = pcall(require, "neovia.notes")
  if not ok_notes then return end
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  -- Already have a notes window? Re-enforce height and return.
  local existing = navigate.find_notes_win()
  if existing then
    M.enforce_notes_height()
    return
  end

  local nbuf = notes.get_or_create(vim.fn.getcwd())

  -- Split below the code window.
  local prev_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(code_win)
  vim.cmd("belowright split")
  local notes_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(notes_win, nbuf)
  M.enforce_notes_height()

  -- Restore focus.
  vim.api.nvim_set_current_win(prev_win)
end

--- Check the window layout and restore any missing panel.
--- If neo-tree is missing, reopen it.
--- If no code window exists, create one with a noname buffer.
--- If no notes window exists, create the notes split.
--- If no opencode window exists, reopen it.
--- Skips entirely on diffview tabs (they manage their own layout).
local function ensure_layout()
  -- Skip on diffview tabs -- they manage their own window layout.
  local ok_dv, dv = pcall(require, "neovia.diffview")
  if ok_dv and dv.is_diffview_tab(vim.api.nvim_get_current_tabpage()) then
    return
  end

  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  if not has_neo_tree_win() then
    pcall(vim.cmd, "Neotree show")
  end
  if not navigate.find_code_win() then
    local ok, err = pcall(create_code_win)
    if not ok then
      vim.notify("layout: failed to restore code window: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  -- Notes split below the code window.
  local code_win = navigate.find_code_win()
  if code_win and not navigate.find_notes_win() then
    pcall(open_notes_split, code_win)
  end
  if not find_opencode_win() then
    local ok, err = pcall(open_opencode)
    if not ok then
      vim.notify("layout: failed to restore opencode: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  -- Re-enforce notes height after all panels are in place (opening new
  -- panels may cause equalalways to redistribute window sizes).
  M.enforce_notes_height()
end

------------------------------------------------------------------------
-- Restore layout
------------------------------------------------------------------------

--- Nuke all windows and rebuild the canonical layout.
--- Remembers the buffer that was in the code window and restores it.
--- Falls back to a noname buffer if no code buffer was showing.
function M.restore_layout()
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  -- Remember the buffer in the code window (if any)
  local code_win = navigate.find_code_win()
  local code_buf = nil
  if code_win then
    code_buf = vim.api.nvim_win_get_buf(code_win)
  end

  -- Tear down opencode windows cleanly before collapsing so
  -- opencode.nvim does not hold stale window references.
  local ok_oc_ui, oc_ui = pcall(require, "opencode.ui.ui")
  local ok_oc_state, oc_state = pcall(require, "opencode.state")
  if ok_oc_ui and ok_oc_state and oc_state.windows then
    pcall(oc_ui.teardown_visible_windows, oc_state.windows)
  end

  -- Collapse to one window then rebuild all panels.
  vim.cmd("only")

  -- After "only" the surviving window may show an opencode or neo-tree
  -- buffer.  Replace it with the code buffer (or a noname buffer) so
  -- the window order comes out correct: neo-tree inserts to its left,
  -- opencode opens to its right.
  if code_buf and vim.api.nvim_buf_is_valid(code_buf) then
    vim.api.nvim_win_set_buf(0, code_buf)
  else
    -- Create a fresh noname buffer for the code window.
    local noname = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, noname)
  end

  pcall(vim.cmd, "Neotree show")

  -- Create the notes split below the code window before opening opencode
  -- so opencode's vertical split ends up to the right of both.
  local new_code_win = navigate.find_code_win()
  if new_code_win then
    pcall(open_notes_split, new_code_win)
  end

  open_opencode()

  -- Re-enforce notes height after opencode opens (equalalways may drift it).
  M.enforce_notes_height()

  -- Ensure focus lands on the code window.
  new_code_win = navigate.find_code_win()
  if new_code_win then
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
--- - VimEnter: open the opencode panel and notes split on startup.
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

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      M.enforce_notes_height()
    end,
  })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        -- Open neo-tree sidebar (far left)
        pcall(vim.cmd, "Neotree show")
        -- Create notes split before opencode so the vertical split is correct
        local ok_nav, navigate = pcall(require, "neovia.navigate")
        if ok_nav then
          local code_win = navigate.find_code_win()
          if code_win then
            pcall(open_notes_split, code_win)
          end
        end
        open_opencode()
        -- Re-enforce notes height after opencode opens.
        M.enforce_notes_height()
        -- Ensure focus lands on the code window, not neo-tree or opencode.
        if ok_nav then
          local code_win = navigate.find_code_win()
          if code_win then vim.api.nvim_set_current_win(code_win) end
        end
      end)
    end,
  })
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  find_opencode_win = find_opencode_win,
  has_neo_tree_win = has_neo_tree_win,
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
