-- neo-tree: read-only directory tree sidebar
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      "MunifTanjim/nui.nvim",
    },
    cmd = "Neotree",
    keys = {
      { "<leader>e", "<cmd>Neotree toggle<CR>", desc = "File tree" },
    },
    opts = {
      filesystem = {
        follow_current_file = { enabled = true },
        use_libuv_file_watcher = true,
      },
      window = {
        width = 35,
        mappings = {
          -- Read-only: disable file-editing actions
          ["a"] = "none",
          ["d"] = "none",
          ["r"] = "none",
          ["m"] = "none",
          ["c"] = "none",
          ["x"] = "none",
          ["p"] = "none",
        },
      },
    },
  },
}
