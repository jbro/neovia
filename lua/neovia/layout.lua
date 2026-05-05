-- neovia layout module
-- Enforce the four-panel layout:
--   neo-tree (left) | code (centre top)    | opencode (right)
--                   | session notes (bot)  |
-- A single apply() function handles all layout enforcement: both
-- WinClosed recovery and explicit <leader>l restores use the same path.

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
local applying = false
local apply_epoch = 0

------------------------------------------------------------------------
-- Window detection (delegates to navigate for shared helpers)
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

------------------------------------------------------------------------
-- Layout check (pure: no side effects)
------------------------------------------------------------------------

--- Check whether the current tab has a correct layout.
--- Returns true when code and opencode windows exist and are correctly
--- positioned (code column < opencode column; neo-tree column < code
--- column when neo-tree exists).
--- @return boolean
local function is_layout_ok()
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return false end

  local code_win = navigate.find_code_win()
  local oc_win = find_opencode_win()

  -- Must have both code and opencode windows.
  if not code_win or not oc_win then return false end

  -- Check column ordering.
  local code_col = vim.api.nvim_win_get_position(code_win)[2]
  local oc_col = vim.api.nvim_win_get_position(oc_win)[2]
  if oc_col <= code_col then return false end

  -- If neo-tree exists, it must be to the left of code.
  local tree_win = find_neo_tree_win()
  if tree_win then
    local tree_col = vim.api.nvim_win_get_position(tree_win)[2]
    if tree_col >= code_col then return false end
  end

  return true
end

------------------------------------------------------------------------
-- Panel helpers
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

------------------------------------------------------------------------
-- Nuke-and-rebuild
------------------------------------------------------------------------

--- Rebuild the canonical layout from scratch.
--- Saves the code buffer, tears down everything, then reconstructs
--- panels in the correct order: neo-tree (left), code+notes (centre),
--- opencode (right).
--- @param code_buf integer?  Buffer to show in the code window (nil = noname).
local function rebuild(code_buf)
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if not ok_nav then return end

  -- Tear down opencode windows cleanly before collapsing so
  -- opencode.nvim does not hold stale window references.
  local ok_oc_ui, oc_ui = pcall(require, "opencode.ui.ui")
  local ok_oc_state, oc_state = pcall(require, "opencode.state")
  if ok_oc_ui and ok_oc_state and oc_state.windows then
    pcall(oc_ui.teardown_visible_windows, oc_state.windows)
  end

  -- Collapse to one window. Close extra windows one by one; when only
  -- one window remains, stop. `only!` can hang when terminal buffers
  -- are running, so we avoid it.
  local function close_extras()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    while #wins > 1 do
      -- Pick a window that is NOT the current one.
      for _, w in ipairs(wins) do
        if w ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_is_valid(w) then
          pcall(vim.api.nvim_win_close, w, true)
          break
        end
      end
      wins = vim.api.nvim_tabpage_list_wins(0)
    end
  end
  close_extras()

  -- After "only" the surviving window may show an opencode or neo-tree
  -- buffer.  Replace it with the code buffer (or a noname buffer) so
  -- the window order comes out correct: neo-tree inserts to its left,
  -- opencode opens to its right.
  if code_buf and vim.api.nvim_buf_is_valid(code_buf) then
    vim.api.nvim_win_set_buf(0, code_buf)
  else
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

  -- Clean up any stray [No Name] listed buffers left behind.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
      and vim.api.nvim_buf_get_name(b) == ""
      and vim.api.nvim_buf_line_count(b) <= 1
    then
      local lines = vim.api.nvim_buf_get_lines(b, 0, 1, false)
      if #lines == 0 or lines[1] == "" then
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
-- Unified apply
------------------------------------------------------------------------

--- Enforce the canonical layout. This is the single entry point for all
--- layout enforcement: WinClosed recovery, VimEnter setup, <leader>l,
--- server restart, worktree switch, etc.
---
--- If all panels exist and are correctly ordered, just enforce notes
--- height and return (no-op). Otherwise, nuke and rebuild.
---
--- Skips entirely on diffview tabs.
function M.apply()
  -- Guard against re-entrant calls (rebuild closes windows which fires
  -- WinClosed which schedules another apply).
  if applying then return end

  -- Skip on diffview tabs -- they manage their own window layout.
  local ok_dv, dv = pcall(require, "neovia.diffview")
  if ok_dv and dv.is_diffview_tab(vim.api.nvim_get_current_tabpage()) then
    return
  end

  -- If layout is already correct, just enforce notes height and return.
  if is_layout_ok() then
    M.enforce_notes_height()
    return
  end

  -- Layout is broken: remember the code buffer and rebuild.
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  local code_buf = nil
  if ok_nav then
    local code_win = navigate.find_code_win()
    if code_win then
      code_buf = vim.api.nvim_win_get_buf(code_win)
    end
  end

  applying = true
  apply_epoch = apply_epoch + 1
  local ok, err = pcall(rebuild, code_buf)
  -- Increment again so any WinClosed callbacks scheduled during rebuild()
  -- (which captured the pre-increment epoch) see a stale epoch and bail.
  apply_epoch = apply_epoch + 1
  applying = false
  if not ok then
    vim.notify("layout: rebuild failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- Initialise the layout module. Registers autocmds for:
--- - WinClosed: apply layout when a panel is missing.
--- - VimEnter: build the initial layout on startup.
--- - VimResized: re-enforce notes height.
function M.setup()
  if initialised then return end
  initialised = true

  local group = vim.api.nvim_create_augroup("neovia_layout", { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      -- Capture the epoch before scheduling. If apply() already ran
      -- (e.g. a rebuild that closed windows), the epoch will have
      -- changed and we skip the stale callback.
      local epoch = apply_epoch
      vim.schedule(function()
        if apply_epoch ~= epoch then return end
        M.apply()
      end)
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
        M.apply()
      end)
    end,
  })
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  find_opencode_win = find_opencode_win,
  is_layout_ok = is_layout_ok,

  --- Set a custom opencode opener (for testing). Pass nil to clear.
  --- @param fn function?
  set_opencode_opener = function(fn)
    opencode_opener = fn
  end,

  --- Reset all state: clear augroup, reset initialised flag.
  reset = function()
    initialised = false
    opencode_opener = nil
    applying = false
    apply_epoch = apply_epoch + 1
    pcall(vim.api.nvim_create_augroup, "neovia_layout", { clear = true })
  end,
}

return M
