-- Treesitter: syntax highlighting, indentation, textobjects
--
-- On Neovim 0.11+ highlight and indent are built-in; nvim-treesitter just
-- manages parser installation. Textobjects has its own setup.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter-textobjects",
    },
    config = function()
      require("nvim-treesitter").setup()

      -- Install parsers (async, idempotent)
      local ensure = {
        "bash", "c", "css", "go", "gomod", "html", "javascript",
        "json", "lua", "markdown", "markdown_inline", "python",
        "tsx", "typescript", "vim", "vimdoc", "yaml",
      }
      local installed = require("nvim-treesitter").get_installed()
      local installed_set = {}
      for _, p in ipairs(installed) do installed_set[p] = true end
      local to_install = {}
      for _, p in ipairs(ensure) do
        if not installed_set[p] then to_install[#to_install + 1] = p end
      end
      if #to_install > 0 then
        require("nvim-treesitter").install(to_install)
      end

      -- Textobjects: select and move by function, class, argument
      require("nvim-treesitter-textobjects").setup({
        select = {
          enable = true,
          lookahead = true,
          keymaps = {
            ["af"] = "@function.outer",
            ["if"] = "@function.inner",
            ["ac"] = "@class.outer",
            ["ic"] = "@class.inner",
            ["aa"] = "@parameter.outer",
            ["ia"] = "@parameter.inner",
          },
        },
        move = {
          enable = true,
          set_jumps = true,
          goto_next_start = {
            ["]f"] = "@function.outer",
            ["]c"] = "@class.outer",
            ["]a"] = "@parameter.inner",
          },
          goto_previous_start = {
            ["[f"] = "@function.outer",
            ["[c"] = "@class.outer",
            ["[a"] = "@parameter.inner",
          },
        },
      })
    end,
  },
}
