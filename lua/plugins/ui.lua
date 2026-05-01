-- UI: colorscheme, statusline, tabline, which-key, indent guides
--
-- Lualine renders both statusline and tabline. The worktree module
-- builds the tabline string (including click handlers); this file
-- wires it into lualine config and defines highlight groups.

--- Define worktree highlights, delegating to the tabline module.
local function define_wt_highlights()
  local ok, t = pcall(require, "neovia.tabline")
  if ok then t.define_worktree_highlights() end
end

--- Lualine component: delegates to worktree.build_tabline().
--- @return string
local function worktree_tabline()
  local ok, wt = pcall(require, "neovia.worktree")
  if not ok then return "" end
  return wt.build_tabline()
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

--- Build the PR string for the statusline (e.g. "#42 Fix login bug").
--- Title is truncated to 30 characters. Returns empty string when
--- the current branch has no PR.
--- @return string
local function pr_number()
  local ok, pr = pcall(require, "neovia.pr")
  if not ok then return "" end

  local info = pr.get_current()
  if not info then return "" end

  local s = "#" .. info.number
  local title = pr.truncate_title(info.title)
  if title ~= "" then
    s = s .. " " .. title
  end
  return s
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
      require("lualine").setup(opts)
      define_wt_highlights()
      local hl_group = vim.api.nvim_create_augroup("neovia_wt_hl", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = hl_group,
        callback = function()
          -- Defer so lualine's own ColorScheme handler runs first and
          -- recreates lualine_a_normal / lualine_b_normal.
          vim.schedule(define_wt_highlights)
        end,
        desc = "neovia: reapply worktree status highlights",
      })
    end,
    opts = {
      options = {
        globalstatus = true,
        refresh = {
          tabline = 200,  -- spinner animation
        },
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
        lualine_b = {
          "branch",
          {
            pr_number,
            on_click = function()
              local ok, pr = pcall(require, "neovia.pr")
              if not ok then return end
              local info = pr.get_current()
              if info and info.url ~= "" then
                vim.ui.open(info.url)
              end
            end,
          },
          "diff",
          "diagnostics",
        },
        lualine_c = {
          {
            "filename",
            cond = function()
              return vim.bo.filetype ~= "neo-tree"
            end,
          },
        },
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
      sort = { "local", "order", "alphanum", "group", "mod" },
      triggers = {
        { "<leader>", mode = { "n", "v" } },
      },
      spec = {
        { "<leader>b", group = "Buffer" },
        { "<leader>f", group = "Find" },
        { "<leader>s", group = "Search" },
        { "<leader>d", group = "Diff" },
        { "<leader>g", group = "Git" },
        { "<leader>o", group = "OpenCode" },
        { "<leader>oE", group = "Engine" },
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

  -- Floating vim.ui.input and vim.ui.select via dressing builtin
  {
    "stevearc/dressing.nvim",
    event = "VeryLazy",
    opts = {
      input = {
        enabled = true,
        relative = "editor",
      },
      select = {
        enabled = true,
        backend = { "builtin" },
        builtin = {
          relative = "editor",
        },
      },
    },
  },
}
