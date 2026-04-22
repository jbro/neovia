-- UI: colorscheme, statusline, tabline, which-key, indent guides
--
-- Lualine renders both statusline and tabline. The worktree module
-- exposes data only; all rendering logic lives here (decision 0009).

--- Define highlight groups used by the worktree tabline.
--- Called on setup and on ColorScheme change.
local function define_wt_highlights()
  vim.api.nvim_set_hl(0, "NeoviaWt_idle", { fg = "#9ece6a" })
  vim.api.nvim_set_hl(0, "NeoviaWt_responding", { fg = "#e0af68" })
  vim.api.nvim_set_hl(0, "NeoviaWt_needs_attention", { fg = "#f7768e" })
  vim.api.nvim_set_hl(0, "NeoviaWt_unknown", { fg = "#565f89" })
  vim.api.nvim_set_hl(0, "NeoviaWtClosed", { fg = "#565f89", italic = true })
end

--- Spinner frames for "responding" status in the tabline.
local spinner_frames = { "|", "/", "-", "\\" }
local spinner_idx = 0

--- Return a single-character status indicator for the tabline.
--- @param s string  One of "idle", "responding", "needs_attention", "unknown".
--- @return string
local function status_char(s)
  if s == "needs_attention" then return "!" end
  if s == "responding" then
    spinner_idx = (spinner_idx % #spinner_frames) + 1
    return spinner_frames[spinner_idx]
  end
  if s == "unknown" then return "?" end
  return "" -- idle: no indicator
end

--- Build the worktree tabline component string.
--- Uses statusline highlight groups for per-entry colouring.
--- Returns "" when there are 0 or 1 entries (tabline not useful).
--- @return string
local function worktree_tabline()
  local ok, wt = pcall(require, "neovia.worktree")
  if not ok then return "" end

  local entries = wt.get_entries()
  if #entries <= 1 then return "" end

  local parts = {}
  for _, e in ipairs(entries) do
    local char = status_char(e.status)
    local suffix = char ~= "" and (" " .. char) or ""

    if e.current then
      table.insert(parts, "%#TabLineSel# " .. e.branch .. suffix .. " ")
    elseif not e.open then
      table.insert(parts, "%#NeoviaWtClosed# " .. e.branch .. suffix .. " ")
    else
      local hl = "TabLine"
      if e.status == "needs_attention" then
        hl = "NeoviaWt_needs_attention"
      elseif e.status == "responding" then
        hl = "NeoviaWt_responding"
      end
      if char ~= "" then
        table.insert(parts, "%#TabLine# " .. e.branch .. " %#" .. hl .. "#" .. char .. " ")
      else
        table.insert(parts, "%#TabLine# " .. e.branch .. " ")
      end
    end
  end

  return table.concat(parts) .. "%#TabLineFill#"
end

--- Build the opencode status component string for the statusline.
--- Shows the current worktree's opencode session status.
--- @return string
local function opencode_status()
  local ok, wt = pcall(require, "neovia.worktree")
  if not ok then return "" end

  local info = wt.get_current_status()
  if not info then return "" end

  return info.icon
end

--- Return the highlight colour for the opencode status component.
--- @return table
local function opencode_status_color()
  local ok, wt = pcall(require, "neovia.worktree")
  if not ok then return {} end

  local info = wt.get_current_status()
  if not info then return {} end

  return info.hl
end

return {
  -- Colorscheme
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("tokyonight")
    end,
  },

  -- Statusline + tabline
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    config = function(_, opts)
      define_wt_highlights()
      local hl_group = vim.api.nvim_create_augroup("neovia_wt_hl", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = hl_group,
        callback = define_wt_highlights,
        desc = "neovia: reapply worktree status highlights",
      })
      require("lualine").setup(opts)
    end,
    opts = {
      options = {
        globalstatus = true,
      },
      tabline = {
        lualine_a = {
          { worktree_tabline, separator = "", padding = 0 },
        },
        lualine_b = {},
        lualine_c = {},
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      },
      sections = {
        lualine_a = {
          { function() return require("neovia.mode").lualine_mode() end },
        },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { "filename" },
        lualine_x = {
          { opencode_status, color = opencode_status_color },
          "filetype",
        },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
    },
  },

  -- Keybinding discovery
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      triggers = {
        { "<leader>", mode = { "n", "v" } },
      },
      spec = {
        { "<leader>f", group = "Find" },
        { "<leader>s", group = "Search" },
        { "<leader>g", group = "Git" },
        { "<leader>o", group = "OpenCode" },
        { "<leader>p", group = "Plugins" },
        { "<leader>w", group = "Worktree" },
      },
    },
  },

  -- Completion
  {
    "saghen/blink.cmp",
    version = "*",
    event = { "InsertEnter", "CmdlineEnter" },
    opts = {},
  },

  -- Indent guides
  {
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
  },
}
