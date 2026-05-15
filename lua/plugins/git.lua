-- Git: gitsigns + diffview + fugitive

--- Get the worktree directory for the current tab.
--- @return string
local function current_dir()
  return vim.fn.getcwd(-1, 0)
end

return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    keys = {
      { "<leader>gb", function() require("gitsigns").blame_line() end, desc = "Blame line" },
    },
    opts = {},
  },
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>dd", function() require("neovia.diffview").toggle_diff(current_dir()) end, desc = "Toggle diff" },
      { "<leader>dh", function() require("neovia.diffview").toggle_history(current_dir()) end, desc = "Toggle file history" },
    },
    opts = {},
  },
  {
    "tpope/vim-fugitive",
    cmd = "Git",
    keys = {
      { "<leader>gs", "<cmd>Git<cr>", desc = "Git status" },
    },
  },
}
