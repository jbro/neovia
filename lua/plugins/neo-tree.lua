-- neo-tree: read-only directory tree sidebar (always visible, far left)
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
        -- Disable gitignore hiding: worktree directories live under
        -- .worktrees/ which is gitignored in the main repo. Neo-tree's
        -- mark_gitignored checks ALL known worktree roots, so files
        -- inside a child worktree inherit the parent's "!" status and
        -- get hidden. Dotfiles (.gitignore) should also be visible.
        filtered_items = {
          hide_dotfiles = false,
          hide_gitignored = false,
          never_show = {
            ".git",
            ".worktrees",
          },
        },
      },
      window = {
        position = "left",
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
