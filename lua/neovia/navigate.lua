-- neovia navigate module
-- Open files and folders from opencode_output in the code window.

local M = {}

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

--- Parse a file path string, extracting an optional line number.
--- Handles patterns like "file.lua:42", "file.lua:42:10", "file.lua".
--- @param raw string
--- @return string path, integer? line
local function parse_path(raw)
  -- Strip trailing punctuation that markdown/prose wraps around paths
  raw = raw:gsub("[`'\"%)%]}>,;]+$", "")
  raw = raw:gsub("^[`'\"%(<%[{]+", "")

  -- file:line:col or file:line
  local path, line = raw:match("^(.+):(%d+):%d+$")
  if not path then
    path, line = raw:match("^(.+):(%d+)$")
  end
  if path then
    return path, tonumber(line)
  end
  return raw, nil
end

--- Get the file path under or near the cursor using Vim's built-in <cfile>.
--- @return string?
local function cfile()
  local ok, f = pcall(vim.fn.expand, "<cfile>")
  if ok and f and f ~= "" then return f end
  return nil
end

--- Resolve a potentially relative path to an absolute path.
--- @param path string
--- @return string
local function resolve(path)
  if vim.fn.fnamemodify(path, ":p") == path then return path end
  return vim.fn.fnamemodify(path, ":p")
end

------------------------------------------------------------------------
-- Window helpers
------------------------------------------------------------------------

--- Check whether a window belongs to opencode (output or input).
--- @param win integer
--- @return boolean
local function is_opencode_win(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  return ft == "opencode_output" or ft == "opencode_input"
end

--- Check whether a window is a special sidebar (neo-tree, etc.).
--- @param win integer
--- @return boolean
local function is_sidebar_win(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  local bt = vim.bo[buf].buftype
  return ft == "neo-tree" or bt == "help" or bt == "quickfix"
end

--- Find the best "code" window: a normal, non-opencode, non-sidebar window.
--- Returns nil if none found.
--- @return integer?
local function find_code_win()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win)
      and not is_opencode_win(win)
      and not is_sidebar_win(win)
      and vim.api.nvim_win_get_config(win).relative == "" -- not floating
    then
      return win
    end
  end
  return nil
end

--- Create a code window to the left of the opencode pane.
--- @return integer win  The new window handle.
local function create_code_win()
  -- Open a vertical split to the left; this pushes opencode panes right.
  vim.cmd("topleft vsplit")
  return vim.api.nvim_get_current_win()
end

--- Open a directory in the code window (netrw).
--- @param dir string  Absolute path to the directory.
local function open_dir(dir)
  local win = find_code_win()
  if not win then
    win = create_code_win()
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(dir))
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Open the file under the cursor in the code window.
--- Designed to be called as a buffer-local gf mapping in opencode_output.
function M.open()
  local raw = cfile()
  if not raw then
    vim.notify("gf: no file path under cursor", vim.log.levels.WARN)
    return
  end

  local path, line = parse_path(raw)
  local abs = resolve(path)

  -- Directory: open in code window (netrw)
  if vim.fn.isdirectory(abs) == 1 then
    open_dir(abs)
    return
  end

  -- Verify the file exists
  if vim.fn.filereadable(abs) ~= 1 then
    vim.notify("gf: file not found: " .. path, vim.log.levels.WARN)
    return
  end

  -- Find or create the code window
  local win = find_code_win()
  if not win then
    win = create_code_win()
  end

  -- Focus the code window and open the file
  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(abs))

  -- Jump to line if provided
  if line then
    local total = vim.api.nvim_buf_line_count(0)
    if line > total then line = total end
    vim.api.nvim_win_set_cursor(win, { line, 0 })
  end
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  parse_path = parse_path,
  open_dir = open_dir,
  is_opencode_win = is_opencode_win,
  is_sidebar_win = is_sidebar_win,
  find_code_win = find_code_win,
}

return M
