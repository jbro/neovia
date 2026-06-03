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
      { "<leader>wC", function() require("neovia.worktree").create({ from_current = true }) end, desc = "Create from current" },
      { "<leader>wf", function() require("neovia.worktree").create({ fork = true }) end, desc = "Fork worktree" },
      { "<leader>wd", function() require("neovia.worktree").delete() end, desc = "Delete worktree" },
      { "<leader>wD", function() require("neovia.worktree").delete_current() end, desc = "Delete current worktree" },
      { "<leader>wn", function() require("neovia.worktree").next() end, desc = "Next worktree" },
      { "<leader>wp", function() require("neovia.worktree").prev() end, desc = "Previous worktree" },
      { "<leader>wa", function() require("neovia.worktree").next_attention() end, desc = "Next needs attention" },
      { "<leader>ws", function() require("neovia.worktree").resync() end, desc = "Resync sessions" },
    },
    opts = {
      winopts = {
        border = "rounded",
        preview = {
          border = "rounded",
        },
      },
      fzf_colors = true,
      -- Route all file-opening actions through navigate.open_in_code_win
      -- so files always land in the code panel, not in opencode/sidebar windows.
      actions = {
        files = {
          ["default"] = function(selected, opts)
            require("neovia.navigate").fzf_file_action(selected, opts)
          end,
        },
      },
      files = {
        -- Show gitignored files (--no-ignore) but still hide .git and .worktrees,
        -- matching neo-tree's never_show list.
        fd_opts = "--color=never --type f --hidden --follow --no-ignore"
          .. " --exclude .git --exclude .worktrees",
      },
      grep = {
        rg_opts = "--column --line-number --no-heading --color=always"
          .. " --smart-case --max-columns=4096 --no-ignore"
          .. " -g '!.git/' -g '!.worktrees/' -e",
      },
    },
  },
}
