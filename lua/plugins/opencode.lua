-- opencode.nvim + render-markdown.nvim

--- Resolve the external server port.
--- Reads from vim.g.neovia_server_port (set by init.lua before
--- lazy.setup) with a fallback to the server module's on-disk state.
--- Returns nil when no external server is available (plugin will spawn).
local function resolve_server_port()
  local g_port = tonumber(vim.g.neovia_server_port)
  if g_port then return g_port end
  local ok, srv = pcall(require, "neovia.server")
  if ok then return srv.read_port() end
  return nil
end

--- Build system prompt constraining table width to output window columns.
--- Uses caveman compression: strip grammar, keep facts, save tokens.
--- @param columns integer  Usable text columns in the output window.
--- @return string
local function table_width_prompt(columns)
  return string.format("Tables: max %d columns wide.", columns)
end

--- Compute usable text columns in the opencode output window.
--- Accounts for signcolumn offset when the window exists, otherwise
--- estimates from layout constants (ratio + sidebar).
--- @return integer
local function output_text_columns()
  local ok_state, state = pcall(require, "opencode.state")
  if ok_state and state.windows and state.windows.output_win
    and vim.api.nvim_win_is_valid(state.windows.output_win) then
    local info = vim.fn.getwininfo(state.windows.output_win)
    local textoff = info and info[1] and info[1].textoff or 0
    return vim.api.nvim_win_get_width(state.windows.output_win) - textoff
  end
  -- Fallback: estimate from layout constants.
  local ok_layout, layout = pcall(require, "neovia.layout")
  if ok_layout then
    local cols = math.floor(vim.o.columns * layout.opencode_width_ratio())
    return cols - 2 -- signcolumn ≈ 2
  end
  return 80
end

--- Update opencode's default_system_prompt with current window width.
local function refresh_table_width_prompt()
  local ok_cfg, cfg = pcall(require, "opencode.config")
  if ok_cfg then
    cfg.default_system_prompt = table_width_prompt(output_text_columns())
  end
end

-- Guard so the child-permission recovery is subscribed at most once even if
-- the plugin config runs again (defensive; lazy.nvim runs config once).
local child_permission_recovery_installed = false

--- Recover child/subagent-session permission dialogs that upstream's
--- session-scoped event gate drops.
---
--- opencode.nvim scopes permission.asked/updated to the active session via
--- event_scope.scoped_callback -> session_scope.belongs_to_active_session.
--- A child-session permission only passes that gate once the parent's `task`
--- tool part (carrying state.metadata.sessionId) has been indexed in
--- render_state. When the permission event arrives before that part is
--- indexed, the gate returns false, on_permission_updated is never called,
--- and the dialog is silently dropped (it stays pending server-side, which
--- is why <leader>oS recovers it manually).
---
--- This installs an extra, *unscoped* subscription that detects the dropped
--- case and re-drives upstream's own recovery (restore_pending_permissions)
--- on a short defer, by which point the task part is usually indexed. The
--- restore queries the server and re-filters via belongs_to_session, so
--- foreign-worktree permissions are correctly ignored and already-shown
--- permissions are deduped by id.
local function install_child_permission_recovery()
  if child_permission_recovery_installed then
    return
  end

  local ok_state, oc_state = pcall(require, "opencode.state")
  if not ok_state or not oc_state.event_manager then
    return
  end

  local ok_scope, event_scope = pcall(require, "opencode.ui.event_scope")
  if not ok_scope then
    return
  end

  local function on_permission(event_name, properties)
    if not properties or not properties.id then
      return
    end

    -- Upstream's scoped callback already handles this one; do nothing.
    if event_scope.should_handle(event_name, properties) then
      return
    end

    local active = oc_state.active_session
    if not active or not active.id then
      return
    end

    -- A permission with no sessionID is handled by upstream's fallback;
    -- only act on cross-session (potential child) permissions.
    local sid = properties.sessionID
    if not sid or sid == "" or sid == active.id then
      return
    end

    -- Defer so the parent's task-tool part (which links child -> parent
    -- session) has a chance to be indexed before we re-query the server.
    vim.defer_fn(function()
      local cur = oc_state.active_session
      if not cur or not cur.id then
        return
      end
      local ok_pw, permission_window = pcall(require, "opencode.ui.permission_window")
      if ok_pw then
        pcall(permission_window.restore_pending_permissions, cur.id)
      end
    end, 200)
  end

  for _, name in ipairs({ "permission.asked", "permission.updated" }) do
    oc_state.event_manager:subscribe(name, function(properties)
      on_permission(name, properties)
    end)
  end

  child_permission_recovery_installed = true
end

return {
  {
    "sudo-tee/opencode.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "MeanderingProgrammer/render-markdown.nvim",
        opts = {
          anti_conceal = { enabled = false },
          file_types = { "markdown", "opencode_output" },
        },
        ft = { "markdown", "opencode_output" },
      },
      -- fzf-lua is loaded separately; opencode.nvim will discover it
      "ibhagwan/fzf-lua",
    },
    config = function()
      local port = resolve_server_port()
      local layout = require("neovia.layout")
      require("opencode").setup({
        preferred_picker = "fzf",
        -- Pin opencode to the active session across DirChanged so
        -- handle_directory_change never auto-selects.  neovia drives all
        -- session selection per worktree (see worktree.lua
        -- select_or_create_session, decision 0015).
        lock_session_to_directory = true,
        default_system_prompt = table_width_prompt(output_text_columns()),
        server = port and {
          url = "http://127.0.0.1",
          port = port,
          auto_kill = false,
        } or {},
        ui = {
          window_width = layout.opencode_width_ratio(),
          input = {
            text = { wrap = true },
          },
        },
        keymap = {
          editor = {
            -- Disable actions that conflict with neovia's fixed layout
            ["<leader>oq"] = false,  -- close (always visible)
            ["<leader>oi"] = false,  -- open input (use og to toggle focus)
            ["<leader>oI"] = false,  -- open input new session (use on)
            ["<leader>oo"] = false,  -- open output (always visible)
            ["<leader>ot"] = false,  -- toggle focus (use og)
            ["<leader>oz"] = false,  -- zoom (breaks fixed layout)
            ["<leader>ox"] = false,  -- swap position (breaks fixed layout)
            ["<leader>od"] = false,  -- diff open (use git)
            ["<leader>o]"] = false,  -- diff next (use git)
            ["<leader>o["] = false,  -- diff prev (use git)
            ["<leader>oc"] = false,  -- diff close (use git)
            ["<leader>ora"] = false, -- revert all last prompt (use git)
            ["<leader>ort"] = false, -- revert this last prompt (use git)
            ["<leader>orA"] = false, -- revert all (use git)
            ["<leader>orT"] = false, -- revert this (use git)
            ["<leader>orr"] = false, -- restore file snapshot (use git)
            ["<leader>orR"] = false, -- restore all snapshots (use git)
            ["<leader>oy"] = false,  -- custom override below (diffview-aware)
            ["<leader>oY"] = false,  -- inline paste (use oy for structured context)
            ["<leader>og"] = { "toggle_focus", desc = "Toggle OpenCode focus" },
            ["<leader>on"] = { "open_input_new_session", desc = "New session" },
          },
          input_window = {
            ["<esc>"] = false,
          },
          output_window = {
            ["<esc>"] = false,
            -- Open file under cursor in the code window (left pane) instead
            -- of upstream's jump_to_file, which targets the wrong window
            -- under neovia's fixed layout.
            ["gf"] = {
              function() require("neovia.navigate").open() end,
              desc = "Open file in code window",
            },
          },
        },
        hooks = {
          on_done_thinking = function(session)
            local dir = session and session.directory or vim.fn.getcwd(-1, 0)
            require("neovia.worktree").set_status(dir, "idle")
          end,
          on_permission_requested = function(session)
            local dir = session and session.directory or vim.fn.getcwd(-1, 0)
            require("neovia.worktree").set_status(dir, "needs_attention")
          end,

        },
      })

      -- Visual selection keymaps: skip open_input on diffview tabs
      -- so the opencode window doesn't invade the diffview layout.
      local function on_diffview_tab()
        local ok_dv, dv = pcall(require, "neovia.diffview")
        return ok_dv and dv.is_diffview_tab(vim.api.nvim_get_current_tabpage())
      end

      vim.keymap.set("v", "<leader>oy", function()
        local api = require("opencode.api")
        local range = { start = vim.fn.line("'<"), stop = vim.fn.line("'>") }
        api.add_visual_selection(on_diffview_tab() and { open_input = false } or nil, range)
      end, { desc = "Add visual selection to context" })

      -- Override reference picker to open files in the code window
      -- instead of tabedit (which creates a new tab, breaking layout).
      local ok_rp, rp = pcall(require, "opencode.ui.reference_picker")
      if ok_rp then
        rp.navigate_to = function(ref)
          local file_path = ref.file_path
          if not vim.startswith(file_path, "/") then
            file_path = vim.fn.getcwd() .. "/" .. file_path
          end
          if vim.fn.filereadable(file_path) ~= 1 then
            vim.notify("File not found: " .. file_path, vim.log.levels.WARN)
            return
          end
          local navigate = require("neovia.navigate")
          navigate.open_in_code_win(file_path, ref.line)
        end
      end

      -- Recover child-session permission dialogs the upstream session-scoped
      -- event gate drops when the permission arrives before the parent task
      -- part is indexed.  event_manager is created during setup() above.
      install_child_permission_recovery()

      -- Keep table-width system prompt in sync with window size.
      local resize_group = vim.api.nvim_create_augroup("neovia_opencode_table_width", { clear = true })
      vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = resize_group,
        callback = refresh_table_width_prompt,
      })
    end,
  },
}
