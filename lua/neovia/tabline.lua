-- neovia tabline module
-- Renders the worktree tabline from TablineEntry data.
-- Dependency flows one way: worktree -> tabline.

local M = {}

------------------------------------------------------------------------
-- Status colours (derived from catppuccin palette when available)
------------------------------------------------------------------------

--- Semantic mapping from status name to catppuccin palette key.
--- @type table<string, string>
local status_palette_keys = {
  idle = "green",
  responding = "yellow",
  needs_attention = "red",
  unknown = "overlay0",
}

--- Fallback hex values (catppuccin mocha) used when the palette is not loaded.
--- @type table<string, string>
local fallback_colors = {
  green = "#a6e3a1",
  yellow = "#f9e2af",
  red = "#f38ba8",
  overlay0 = "#6c7086",
}

--- Resolve status colours from catppuccin palette, falling back to mocha defaults.
--- @return table<string, string>
local function resolve_status_colors()
  local ok, palettes = pcall(require, "catppuccin.palettes")
  local palette = ok and palettes.get_palette() or nil
  local colors = {}
  for status, key in pairs(status_palette_keys) do
    colors[status] = (palette and palette[key]) or fallback_colors[key]
  end
  return colors
end

--- @type table<string, string>
local status_colors = resolve_status_colors()

M.status_colors = status_colors

--- ANSI colour codes for status (used by picker entries).
--- @type table<string, string>
local status_ansi = {
  idle = "\27[32m",            -- green
  responding = "\27[33m",      -- yellow
  needs_attention = "\27[31m", -- red
  unknown = "\27[90m",         -- dim grey
}
local ansi_reset = "\27[0m"

--- Status icons (text, no emoji per AGENTS.md).
--- @type table<string, string>
local status_icon = {
  idle = "[idle]",
  responding = "[working]",
  needs_attention = "[needs you]",
  unknown = "[idle]",
}

--- Build a lualine-compatible color table from status_colors.
--- @param status string
--- @return table
local function status_hl_for(status)
  return { fg = status_colors[status] or status_colors.unknown }
end

--- Return display info (icon + highlight) for a status string.
--- Public API for consumers like worktree.get_current_status().
--- @param status string
--- @return { icon: string, hl: table }
function M.status_display(status)
  return {
    icon = status_icon[status] or status_icon.unknown,
    hl = status_hl_for(status),
  }
end

------------------------------------------------------------------------
-- Spinner / status character
------------------------------------------------------------------------

local spinner_frames = { "⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾" }
local spinner_idx = 0

--- Return a single-character status indicator.
--- @param s string
--- @return string
local function status_char(s)
  if s == "needs_attention" then return "󰀦" end
  if s == "responding" then
    spinner_idx = (spinner_idx % #spinner_frames) + 1
    return spinner_frames[spinner_idx]
  end
  if s == "unknown" then return "󰇘" end
  return "󰒲" -- idle: sleep/zzz
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

--- Define highlight groups used by the worktree tabline.
--- Derives tab backgrounds from lualine's theme groups so colors follow
--- the colorscheme. Creates transitional groups for powerline separators.
local function define_worktree_highlights()
  -- Refresh status colours from the active catppuccin palette.
  local fresh = resolve_status_colors()
  for k, v in pairs(fresh) do status_colors[k] = v end

  -- Status indicator colors
  vim.api.nvim_set_hl(0, "NeoviaWt_idle", { fg = status_colors.idle })
  vim.api.nvim_set_hl(0, "NeoviaWt_responding", { fg = status_colors.responding })
  vim.api.nvim_set_hl(0, "NeoviaWt_needs_attention", { fg = status_colors.needs_attention })
  vim.api.nvim_set_hl(0, "NeoviaWt_unknown", { fg = status_colors.unknown })

  -- Tab backgrounds: selected = lualine_a, non-selected = lualine_b
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

  -- Transitional highlights for powerline separators
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
end

M.define_worktree_highlights = define_worktree_highlights

------------------------------------------------------------------------
-- Click handling
------------------------------------------------------------------------

--- Worktree paths indexed by tabline click ID.
--- @type table<integer, string>
local tabline_click_paths = {}
local tabline_click_next_id = 0

--- Callback for click handling (set by worktree module via set_click_handler).
--- @type fun(path: string)|nil
local click_handler = nil

--- Set the click handler callback.
--- @param handler fun(path: string)|nil
function M.set_click_handler(handler)
  click_handler = handler
end

--- Lua-side click handler; called from the VimScript shim.
--- @param id integer
local function handle_tabline_click(id)
  local path = tabline_click_paths[id]
  if not path then return end
  if click_handler then
    click_handler(path)
  end
end

------------------------------------------------------------------------
-- Tabline builder
------------------------------------------------------------------------

--- @class neovia.TablineEntry
--- @field branch string
--- @field path string
--- @field status string
--- @field current boolean
--- @field pr neovia.PrInfo|nil
--- @field view "code"|"diff"|nil  Active view tab ("diff" when on diffview tab)

--- Transitional highlight group name for a powerline separator.
--- @param from string  "sel", "wt", or "fill"
--- @param to string    "sel", "wt", or "fill"
--- @return string
local function trans_hl(from, to)
  if from == "sel" and to == "wt"   then return "NeoviaWtSel_to_wt" end
  if from == "sel" and to == "fill" then return "NeoviaWtSel_to_fill" end
  if from == "wt"  and to == "sel"  then return "NeoviaWt_to_sel" end
  if from == "wt"  and to == "wt"   then return "NeoviaWt_to_wt" end
  if from == "wt"  and to == "fill" then return "NeoviaWt_to_fill" end
  return "TabLineFill"
end

--- Build the worktree tabline statusline string.
--- @param entries neovia.TablineEntry[]
--- @return string
function M.build(entries)
  if #entries == 0 then return "" end

  -- Reset click ID table each render cycle.
  tabline_click_paths = {}
  tabline_click_next_id = 0

  local parts = {}
  for i, e in ipairs(entries) do
    local char = status_char(e.status)
    local kind = e.current and "sel" or "wt"
    local bg_hl = e.current and "NeoviaWtSel" or "NeoviaWt"

    -- PR icon prefix
    local pr_prefix = ""
    if e.pr then
      local ok_pr, pr_mod = pcall(require, "neovia.pr")
      if ok_pr then
        local icon = pr_mod.icon(e.pr.state)
        if icon ~= "" then
          pr_prefix = icon .. " "
        end
      end
    end
    local view_icon = e.view == "diff" and "\u{f440}" or "\u{f121}"
    local content = "%#" .. bg_hl .. "# " .. pr_prefix .. e.branch .. " " .. view_icon .. " " .. char .. " "

    -- Wrap non-current entries with click handler.
    if not e.current then
      tabline_click_next_id = tabline_click_next_id + 1
      local click_id = tabline_click_next_id
      tabline_click_paths[click_id] = e.path
      content = "%" .. click_id .. "@NeoviaWorktreeSwitch@" .. content .. "%T"
    end

    -- Powerline separator after this entry.
    local next_kind = "fill"
    if i < #entries then
      next_kind = entries[i + 1].current and "sel" or "wt"
    end
    local sep = "%#" .. trans_hl(kind, next_kind) .. "#\u{e0b0}"

    table.insert(parts, content .. sep)
  end

  return table.concat(parts) .. "%#TabLineFill#"
end

------------------------------------------------------------------------
-- Picker helpers
------------------------------------------------------------------------

--- Build parallel arrays of display entries and paths for fzf-lua picker.
--- @param worktrees table[]
--- @param cwd string
--- @param state table<string, table>  Per-dir state (status).
--- @return string[] entries  ANSI-coloured display strings.
--- @return string[] paths    Parallel array of absolute worktree paths.
function M.build_picker_entries(worktrees, cwd, state)
  local entries = {} --- @type string[]
  local paths = {} --- @type string[]
  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path] or { status = "unknown" }
    local colour = status_ansi[entry.status] or status_ansi.unknown
    local icon = status_icon[entry.status] or ""
    local marker = wt.path == cwd and " *" or ""

    local display_path = wt.path:gsub("^" .. vim.pesc(vim.env.HOME), "~")

    local line = string.format(
      "%s%-20s%s  %s%s%s",
      colour, wt.branch, ansi_reset,
      display_path,
      marker,
      icon ~= "" and ("  " .. colour .. icon .. ansi_reset) or ""
    )
    table.insert(entries, line)
    table.insert(paths, wt.path)
  end

  return entries, paths
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  status_palette_keys = status_palette_keys,
  resolve_status_colors = resolve_status_colors,
  status_ansi = status_ansi,
  status_icon = status_icon,
  status_hl_for = status_hl_for,
  status_char = status_char,
  handle_tabline_click = handle_tabline_click,

  --- Get the current click path lookup table.
  --- @return table<integer, string>
  get_click_paths = function() return tabline_click_paths end,

  --- Reset module state (reload contract).
  reset = function()
    tabline_click_paths = {}
    tabline_click_next_id = 0
    spinner_idx = 0
    click_handler = nil
  end,
}

return M
