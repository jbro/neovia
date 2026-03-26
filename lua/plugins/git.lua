-- Git: gitsigns + diffview + fugitive
return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
  },
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    opts = {},
  },
  {
    "tpope/vim-fugitive",
    cmd = "Git",
  },
}
