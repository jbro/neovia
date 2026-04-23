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
  return ft == "opencode_output"
    or ft == "opencode"
    or ft == "opencode_footer"
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
  -- Create a full-height vertical split at the far left. We use an
  -- unlisted scratch buffer to avoid inheriting a terminal buffer
  -- from the current window. Callers replace this buffer immediately
  -- (open_dir, open_in_code_win), so it never appears in :ls or :bn.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win
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
-- Buffer list helpers
------------------------------------------------------------------------

--- Collect listed, named, normal-buftype buffers with relative paths.
--- @return table[]  Each entry has {name = string, bufnr = integer}.
local function buffer_list()
  local bufs = vim.api.nvim_list_bufs()
  local cwd = vim.fn.getcwd() .. "/"
  local result = {}
  for _, b in ipairs(bufs) do
    if vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
    then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        -- Make path relative to cwd if possible
        if vim.startswith(name, cwd) then
          name = name:sub(#cwd + 1)
        end
        table.insert(result, { name = name, bufnr = b })
      end
    end
  end
  return result
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Check whether a window belongs to opencode (output or input).
--- @param win integer
--- @return boolean
function M.is_opencode_win(win)
  return is_opencode_win(win)
end

--- Find the best "code" window (non-opencode, non-sidebar, non-floating).
--- Returns nil if none found.
--- @return integer?
function M.find_code_win()
  return find_code_win()
end

--- Open a directory in the code window (netrw).
--- @param dir string  Absolute path to the directory.
function M.open_dir(dir)
  open_dir(dir)
end

--- Open a file in the code window. Creates the window if needed.
--- @param path string  Absolute path to the file.
--- @param line? integer  Optional line number to jump to.
--- @return boolean success
function M.open_in_code_win(path, line)
  local abs = resolve(path)

  if vim.fn.filereadable(abs) ~= 1 then
    vim.notify("open_in_code_win: file not found: " .. path, vim.log.levels.WARN)
    return false
  end

  local win = find_code_win()
  if not win then
    win = create_code_win()
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(abs))

  if line then
    local total = vim.api.nvim_buf_line_count(0)
    if line > total then line = total end
    vim.api.nvim_win_set_cursor(win, { line, 0 })
  end

  return true
end

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

  if not M.open_in_code_win(abs, line) then
    vim.notify("gf: file not found: " .. path, vim.log.levels.WARN)
  end
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

--- Open the buffer picker via fzf-lua fzf_exec.
--- Shows a plain list of buffer names, no preview, no status indicators.
function M.pick_buffer()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("pick_buffer: fzf-lua not available", vim.log.levels.WARN)
    return
  end

  local entries = buffer_list()
  if #entries == 0 then
    vim.notify("No buffers to pick", vim.log.levels.INFO)
    return
  end

  -- Build lookup from display name -> bufnr
  local lookup = {}
  local lines = {}
  for _, e in ipairs(entries) do
    table.insert(lines, e.name)
    lookup[e.name] = e.bufnr
  end

  fzf.fzf_exec(lines, {
    prompt = "Buffer> ",
    winopts = { height = 0.4, width = 0.5 },
    previewer = false,
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local bufnr = lookup[selected[1]]
        if bufnr then
          local win = find_code_win()
          if win then
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_buf(win, bufnr)
          else
            vim.cmd("buffer " .. bufnr)
          end
        end
      end,
    },
  })
end

M._internal = {
  parse_path = parse_path,
  is_sidebar_win = is_sidebar_win,
  find_code_win = find_code_win,
  cfile = cfile,
  resolve = resolve,
  buffer_list = buffer_list,

  --- No-op reset (stateless module, satisfies reload contract).
  reset = function() end,
}

return M
