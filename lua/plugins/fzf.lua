-- fzf-lua: fuzzy finder (files, grep, buffers, etc.)
return {
  {
    "ibhagwan/fzf-lua",
    cmd = "FzfLua",
    keys = {
      { "<leader>ff", function() require("fzf-lua").files() end, desc = "Find files" },
      { "<leader>fg", function() require("fzf-lua").live_grep() end, desc = "Live grep" },
      { "<leader>bb", function() require("neovia.navigate").pick_buffer() end, desc = "Buffer picker" },
      { "<leader>fr", function() require("fzf-lua").oldfiles() end, desc = "Recent files" },
      { "<leader>sd", function() require("fzf-lua").diagnostics_document() end, desc = "Diagnostics" },
      { "<leader>ss", function() require("fzf-lua").lsp_document_symbols() end, desc = "Document symbols" },
      { "<leader>sw", function() require("fzf-lua").lsp_workspace_symbols() end, desc = "Workspace symbols" },
      { "<leader>sh", function() require("fzf-lua").helptags() end, desc = "Help tags" },
      { "<leader>ww", function() require("neovia.worktree").pick() end, desc = "Switch worktree" },
      { "<leader>wc", function() require("neovia.worktree").create() end, desc = "Create worktree" },
      { "<leader>wf", function() require("neovia.worktree").create({ fork = true }) end, desc = "Fork worktree" },
      { "<leader>wC", function() require("neovia.worktree").create_from() end, desc = "Create worktree from" },
      { "<leader>wF", function() require("neovia.worktree").create_from({ fork = true }) end, desc = "Fork worktree from" },
      { "<leader>wq", function() require("neovia.worktree").close_picker() end, desc = "Close worktree" },
      { "<leader>wQ", function() require("neovia.worktree").close() end, desc = "Close current worktree" },
      { "<leader>wd", function() require("neovia.worktree").delete() end, desc = "Delete worktree" },
      { "<leader>wD", function() require("neovia.worktree").delete_current() end, desc = "Delete current worktree" },
      { "<leader>wn", function() require("neovia.worktree").next() end, desc = "Next worktree" },
      { "<leader>wp", function() require("neovia.worktree").prev() end, desc = "Previous worktree" },
      { "<leader>wa", function() require("neovia.worktree").next_attention() end, desc = "Next needs attention" },
    },
    opts = {
      winopts = {
        border = "rounded",
        preview = {
          border = "rounded",
        },
      },
      fzf_colors = true,
    },
  },
}
