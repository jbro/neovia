-- fzf-lua: fuzzy finder (files, grep, buffers, etc.)
return {
  {
    "ibhagwan/fzf-lua",
    cmd = "FzfLua",
    keys = {
      { "<leader>ff", function() require("fzf-lua").files() end, desc = "Find files" },
      { "<leader>fg", function() require("fzf-lua").live_grep() end, desc = "Live grep" },
      { "<leader>fb", function() require("fzf-lua").buffers() end, desc = "Buffers" },
      { "<leader>fr", function() require("fzf-lua").oldfiles() end, desc = "Recent files" },
      { "<leader>sd", function() require("fzf-lua").diagnostics_document() end, desc = "Diagnostics" },
      { "<leader>ss", function() require("fzf-lua").lsp_document_symbols() end, desc = "Document symbols" },
      { "<leader>sw", function() require("fzf-lua").lsp_workspace_symbols() end, desc = "Workspace symbols" },
      { "<leader>sh", function() require("fzf-lua").helptags() end, desc = "Help tags" },
      { "<leader>ww", function() require("neovia.worktree").pick() end, desc = "Worktrees" },
      { "<leader>wc", function() require("neovia.worktree").create() end, desc = "Create worktree" },
      { "<leader>wd", function() require("neovia.worktree").delete() end, desc = "Delete worktree" },
      { "<leader>wq", function() require("neovia.worktree").close(vim.fn.getcwd()) end, desc = "Close worktree" },
    },
    opts = {},
  },
}
