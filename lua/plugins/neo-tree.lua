-- neo-tree: read-only directory tree sidebar (always visible, far left)
local layout = require("neovia.layout")

return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-tree/nvim-web-devicons",
      "MunifTanjim/nui.nvim",
    },
    lazy = false,
    opts = {
      filesystem = {
        follow_current_file = { enabled = true },
        use_libuv_file_watcher = true,
        -- One-way binding: neo-tree follows tcd (via explicit Neotree dir=
        -- in worktree.switch_to), but does not set cwd itself. This prevents
        -- neo-tree's navigate_up/set_root from interfering with tcd-based
        -- worktree switching.
        bind_to_cwd = false,
        filtered_items = {
          hide_dotfiles = false,
          hide_gitignored = false,
          never_show = {
            ".git",
            ".worktrees",
          },
        },
      },
      -- Strip .worktrees/ from the parent repo's git status so child
      -- worktrees don't inherit the "ignored" marker. Without this,
      -- the parent's .gitignore entry for .worktrees/ causes neo-tree
      -- to mark every file in a child worktree as gitignored (dimmed
      -- icons and names). Child worktrees still get their own correct
      -- git status via their own status_async call.
      event_handlers = {
        {
          event = "git_status_changed",
          handler = function(args)
            if not args.git_status then return end
            local ok, wt = pcall(require, "neovia.worktree")
            if ok then wt.strip_worktrees_ignored(args.git_status, args.git_root) end
          end,
        },
      },
      window = {
        position = "left",
        width = layout.sidebar_width,
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
