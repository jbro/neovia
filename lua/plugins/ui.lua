-- UI: colorscheme, statusline, which-key, indent guides
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

  -- Statusline
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    opts = {
      options = {
        globalstatus = true,
      },
      sections = {
        lualine_a = {
          { function() return require("neovia.mode").lualine_mode() end },
        },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { "filename" },
        lualine_x = {
          {
            function() return require("neovia.worktree").lualine_current() end,
            color = function() return require("neovia.worktree").lualine_current_color() end,
            cond = function() return require("neovia.worktree").lualine_current() ~= "" end,
          },
          "filetype",
        },
        lualine_y = {
          {
            function() return require("neovia.worktree").lualine_aggregate() end,
            color = function() return require("neovia.worktree").lualine_aggregate_color() end,
            cond = function() return require("neovia.worktree").lualine_aggregate() ~= "" end,
          },
          "progress",
        },
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
        { "<leader>w", group = "Worktree" },
      },
    },
  },

  -- Indent guides
  {
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    event = { "BufReadPost", "BufNewFile" },
    opts = {},
  },
}
