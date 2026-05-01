-- neo-tree: read-only directory tree sidebar (always visible, far left)
local layout = require("neovia.layout")

--- Custom open command: always opens files in the code window.
--- Directories use the filesystem source's toggle_directory so that
--- unloaded directories are scanned and expanded (not just toggled).
local function open_in_code_win(state)
  local tree = state.tree
  local ok, node = pcall(tree.get_node, tree)
  if not (ok and node) then return end

  if node.type == "directory" then
    local fs_ok, fs = pcall(require, "neo-tree.sources.filesystem")
    if fs_ok then fs.toggle_directory(state, node) end
    return
  end

  local path = node.path or node:get_id()
  if not path then return end

  local nav_ok, navigate = pcall(require, "neovia.navigate")
  if nav_ok then
    navigate.open_in_code_win(path)
  end
end

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
      -- Fix git status in worktrees. Two problems:
      -- 1. The parent repo's .gitignore lists .worktrees/, so neo-tree
      --    marks everything under it as ignored ("!"). We strip those
      --    entries from ALL registered worktrees on every status update.
      -- 2. Neo-tree's find_existing_worktree uses pairs() (unordered).
      --    When both parent and child are registered, the wrong one can
      --    match. We patch it to prefer the deepest (most specific) root.
      -- The handler runs before neo-tree's own git_status_changed handler
      -- (registered later via manager.subscribe), so the redraw sees
      -- clean data.
      event_handlers = {
        {
          event = "git_status_changed",
          handler = function()
            local ok, wt = pcall(require, "neovia.worktree")
            if ok then wt.on_git_status_changed() end
          end,
        },
      },
      commands = {
        open_in_code_win = open_in_code_win,
      },
      window = {
        position = "left",
        width = layout.sidebar_width,
        mappings = {
          -- All opens target the code window explicitly.
          ["<cr>"] = "open_in_code_win",
          ["<2-LeftMouse>"] = "open_in_code_win",
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
