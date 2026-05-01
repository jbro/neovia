-- neovia diffview module
-- Manages diffview tab pages per worktree.
-- Each worktree can have at most one diffview tab (created lazily).
-- <leader>dd toggles working-tree diff, <leader>dh toggles file history.

local M = {}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local initialised = false

--- Maps worktree dir -> tab page handle.
--- @type table<string, integer>
local dir_to_tab = {}

--- Reverse map: tab page handle -> worktree dir.
--- @type table<integer, string>
local tab_to_dir = {}

------------------------------------------------------------------------
-- Tab registry (pure, no side effects beyond state mutation)
------------------------------------------------------------------------

--- Return the diffview tab for a worktree, or nil.
--- Invalidates stale entries (tab was closed externally).
--- @param dir string
--- @return integer|nil
local function tab_for_worktree(dir)
  local tab = dir_to_tab[dir]
  if tab == nil then return nil end
  -- Validate: is this tab still alive?
  local ok = pcall(vim.api.nvim_tabpage_get_number, tab)
  if not ok then
    -- Stale entry; clean up
    dir_to_tab[dir] = nil
    tab_to_dir[tab] = nil
    return nil
  end
  return tab
end

--- Register a tab page as the diffview tab for a worktree.
--- @param dir string
--- @param tab integer
local function register(dir, tab)
  dir_to_tab[dir] = tab
  tab_to_dir[tab] = dir
end

--- Unregister the diffview tab for a worktree.
--- @param dir string
local function unregister(dir)
  local tab = dir_to_tab[dir]
  if tab then
    tab_to_dir[tab] = nil
  end
  dir_to_tab[dir] = nil
end

--- Check whether a tab page is a registered diffview tab.
--- @param tab integer
--- @return boolean
local function is_diffview_tab(tab)
  return tab_to_dir[tab] ~= nil
end

--- Return the worktree dir associated with a diffview tab, or nil.
--- @param tab integer
--- @return string|nil
local function worktree_for_tab(tab)
  return tab_to_dir[tab]
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Check whether a tab page is a diffview tab.
--- @param tab integer
--- @return boolean
function M.is_diffview_tab(tab)
  return is_diffview_tab(tab)
end

--- Check whether a worktree has an open diffview tab.
--- @param dir string
--- @return boolean
function M.has_diffview_tab(dir)
  return tab_for_worktree(dir) ~= nil
end

--- Return the diffview tab handle for a worktree, or nil.
--- Invalidates stale entries for closed tabs.
--- @param dir string
--- @return integer|nil
function M.tab_for_worktree(dir)
  return tab_for_worktree(dir)
end

--- Close the diffview tab for a worktree (if any).
--- @param dir string
function M.close_for_worktree(dir)
  local tab = tab_for_worktree(dir)
  if not tab then return end

  -- Close the tab page
  local ok = pcall(vim.api.nvim_tabpage_get_number, tab)
  if ok then
    local tabnr = vim.api.nvim_tabpage_get_number(tab)
    vim.cmd("tabclose " .. tabnr)
  end

  unregister(dir)
end

--- Close the current diffview tab, return to the code tab, and unregister.
--- Used when toggling off from within a diffview tab.
--- @param dir string
local function close_current_and_return(dir)
  vim.cmd("DiffviewClose")
  vim.cmd("tabprevious")
  local tab = dir_to_tab[dir]
  if tab then
    local ok = pcall(vim.api.nvim_tabpage_get_number, tab)
    if ok then
      local tabnr = vim.api.nvim_tabpage_get_number(tab)
      vim.cmd("tabclose " .. tabnr)
    end
  end
  unregister(dir)
end

--- Open a diffview command, register the resulting tab.
--- @param cmd string  Vim command to run (e.g. "DiffviewOpen").
--- @param dir string  Worktree directory.
--- @param origin_tab integer  Tab we were on before opening.
local function open_and_register(cmd, dir, origin_tab)
  vim.cmd(cmd)
  local new_tab = vim.api.nvim_get_current_tabpage()
  if new_tab ~= origin_tab then
    register(dir, new_tab)
  end
end

--- Toggle the working-tree diff view for a worktree.
--- If on the diffview tab, close it and return to the code tab.
--- If on the code tab, open (or focus) the diffview tab.
--- @param dir string  Worktree directory.
function M.toggle_diff(dir)
  local current_tab = vim.api.nvim_get_current_tabpage()

  -- If we're on the diffview tab for this worktree, close it
  if tab_to_dir[current_tab] == dir then
    close_current_and_return(dir)
    return
  end

  -- If a diffview tab exists for this worktree, focus it
  local existing = tab_for_worktree(dir)
  if existing then
    local tabnr = vim.api.nvim_tabpage_get_number(existing)
    vim.cmd("tabnext " .. tabnr)
    return
  end

  -- Create a new diffview tab: DiffviewOpen creates its own tab
  open_and_register("DiffviewOpen", dir, current_tab)
end

--- Toggle file history view for a worktree.
--- If on the diffview tab, close it and return to the code tab.
--- If on the code tab, open (or replace) with file history.
--- @param dir string  Worktree directory.
function M.toggle_history(dir)
  local current_tab = vim.api.nvim_get_current_tabpage()

  -- If we're on the diffview tab for this worktree, close it
  if tab_to_dir[current_tab] == dir then
    close_current_and_return(dir)
    return
  end

  -- If a diffview tab exists, close it first (replace with history)
  local existing = tab_for_worktree(dir)
  if existing then
    M.close_for_worktree(dir)
  end

  -- Open file history (creates a new tab)
  open_and_register("DiffviewFileHistory", dir, current_tab)
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- Initialise the module. Idempotent.
function M.setup()
  if initialised then return end
  initialised = true

  local group = vim.api.nvim_create_augroup("neovia_diffview", { clear = true })

  -- Clean up stale registrations when tabs are closed externally
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      -- Scan for stale entries
      for dir, tab in pairs(dir_to_tab) do
        local ok = pcall(vim.api.nvim_tabpage_get_number, tab)
        if not ok then
          tab_to_dir[tab] = nil
          dir_to_tab[dir] = nil
        end
      end
    end,
    desc = "neovia: clean up stale diffview tab registrations",
  })
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  tab_for_worktree = tab_for_worktree,
  register = register,
  unregister = unregister,
  is_diffview_tab = is_diffview_tab,
  worktree_for_tab = worktree_for_tab,

  --- Reset all state (reload contract).
  reset = function()
    dir_to_tab = {}
    tab_to_dir = {}
    initialised = false
    pcall(vim.api.nvim_create_augroup, "neovia_diffview", { clear = true })
  end,
}

return M
