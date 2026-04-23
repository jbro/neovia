-- neovia theme module
-- Persists background (light/dark) to stdpath("state") so it survives restarts.

local M = {}

--- @class neovia.ThemeOpts
--- @field state_path? string  Override the state file path (mainly for tests).

--- @type neovia.ThemeOpts
local opts = {}

--- Whether setup() has been called.
local initialised = false

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

--- Return the path to the state file.
--- @return string
local function state_path()
  return opts.state_path or (vim.fn.stdpath("state") .. "/theme.lua")
end

--- Save current background to the state file.
local function save()
  local path = state_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local content = string.format("return { background = %q }\n", vim.o.background)
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
end

--- Load saved state from disk.
--- @return { background: string }|nil
local function load()
  local path = state_path()
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" then return result end
  return nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Setup the theme module. Idempotent.
--- @param user_opts? neovia.ThemeOpts
function M.setup(user_opts)
  if initialised then return end
  initialised = true
  opts = user_opts or {}
end

--- Toggle between light and dark, persisting the choice.
function M.toggle()
  vim.o.background = vim.o.background == "dark" and "light" or "dark"
  save()
end

--- Apply the persisted background. No-op if no state file exists.
function M.apply()
  local state = load()
  if state and state.background then
    vim.o.background = state.background
  end
end

------------------------------------------------------------------------
-- Highlight helpers
------------------------------------------------------------------------

--- Extract bg color from a highlight group.
--- @param name string
--- @return integer|nil
local function hl_bg(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl and hl.bg
end

--- Extract fg color from a highlight group.
--- @param name string
--- @return integer|nil
local function hl_fg(name)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl and hl.fg
end

------------------------------------------------------------------------
-- Worktree highlight definitions
------------------------------------------------------------------------

--- Define highlight groups used by the worktree tabline.
--- Derives tab backgrounds from lualine's theme groups so colors follow
--- the colorscheme. Creates transitional groups for powerline separators.
local function define_worktree_highlights()
  -- Status indicator colors (used inline in tabline for the icon)
  vim.api.nvim_set_hl(0, "NeoviaWt_idle", { fg = "#9ece6a" })
  vim.api.nvim_set_hl(0, "NeoviaWt_responding", { fg = "#e0af68" })
  vim.api.nvim_set_hl(0, "NeoviaWt_needs_attention", { fg = "#f7768e" })
  vim.api.nvim_set_hl(0, "NeoviaWt_unknown", { fg = "#565f89" })

  -- Tab background groups: selected = lualine_a style, non-selected = lualine_b style.
  local a_bg = hl_bg("lualine_a_normal")
  local a_fg = hl_fg("lualine_a_normal")
  local b_bg = hl_bg("lualine_b_normal")
  local b_fg = hl_fg("lualine_b_normal")
  local fill_bg = hl_bg("TabLineFill") or hl_bg("lualine_c_normal")

  if a_bg then
    vim.api.nvim_set_hl(0, "NeoviaWtSel", { bg = a_bg, fg = a_fg, bold = true })
  end
  if b_bg then
    vim.api.nvim_set_hl(0, "NeoviaWt", { bg = b_bg, fg = b_fg })
  end

  -- Transitional highlights for powerline separators (fg = left bg, bg = right bg).
  if a_bg and b_bg then
    vim.api.nvim_set_hl(0, "NeoviaWtSel_to_wt", { fg = a_bg, bg = b_bg })
    vim.api.nvim_set_hl(0, "NeoviaWt_to_sel", { fg = b_bg, bg = a_bg })
  end
  if a_bg and fill_bg then
    vim.api.nvim_set_hl(0, "NeoviaWtSel_to_fill", { fg = a_bg, bg = fill_bg })
  end
  if b_bg and fill_bg then
    vim.api.nvim_set_hl(0, "NeoviaWt_to_fill", { fg = b_bg, bg = fill_bg })
  end
  if b_bg and a_bg then
    vim.api.nvim_set_hl(0, "NeoviaWt_to_wt", { fg = b_bg, bg = b_bg })
  end
  if fill_bg and a_bg then
    vim.api.nvim_set_hl(0, "Neovia_fill_to_sel", { fg = fill_bg, bg = a_bg })
  end
  if fill_bg and b_bg then
    vim.api.nvim_set_hl(0, "Neovia_fill_to_wt", { fg = fill_bg, bg = b_bg })
  end
end

--- Public: define worktree highlights (called by ui.lua after lualine loads).
M.define_worktree_highlights = define_worktree_highlights

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  state_path = state_path,
  save = save,
  load = load,
  hl_bg = hl_bg,
  hl_fg = hl_fg,
  define_worktree_highlights = define_worktree_highlights,

  --- Reset module state (for test isolation).
  reset = function()
    initialised = false
    opts = {}
  end,
}

return M
