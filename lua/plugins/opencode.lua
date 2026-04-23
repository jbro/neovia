-- opencode.nvim + render-markdown.nvim

--- Resolve the external server port.
--- Prefers the NEOVIA_SERVER_PORT env var (set by neovia.zsh) but
--- falls back to reading the port file on disk via the server module.
--- Returns nil when no external server is available (plugin will spawn).
local function resolve_server_port()
  local env_port = tonumber(vim.env.NEOVIA_SERVER_PORT)
  if env_port then return env_port end
  local ok, srv = pcall(require, "neovia.server")
  if ok then return srv.read_port() end
  return nil
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
      require("opencode").setup({
        preferred_picker = "fzf",
        server = port and {
          url = "http://127.0.0.1",
          port = port,
          auto_kill = false,
        } or {},
        ui = {
          window_width = 0.50,
          input = {
            text = { wrap = true },
          },
        },
        keymap = {
          editor = {
            -- Disable close; toggle_focus is sufficient for switching panes
            ["<leader>oq"] = false,
            ["<leader>og"] = { "toggle_focus", desc = "Toggle OpenCode focus" },
            ["<leader>on"] = { "open_input_new_session", desc = "New session" },
          },
          input_window = {
            ["<esc>"] = false,
          },
          output_window = {
            ["<esc>"] = false,
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
          on_session_loaded = function()
            -- Re-subscribe the event manager's SSE so the server re-emits
            -- pending permission/question state.  renderer.reset() (called
            -- at the start of _render_full_session_data) clears all
            -- permissions and questions.  By re-subscribing here -- after
            -- the session is fully loaded -- we guarantee that re-delivered
            -- events are not wiped by a subsequent reset.
            local ok, oc_state = pcall(require, "opencode.state")
            if ok and oc_state.event_manager
              and oc_state.event_manager._subscribe_to_server_events
              and oc_state.opencode_server then
              oc_state.event_manager:_subscribe_to_server_events(oc_state.opencode_server)
            end
          end,
        },
      })

      -- gf in opencode output: open file in the code window (left pane)
      local gf_group = vim.api.nvim_create_augroup("neovia_opencode_gf", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = gf_group,
        pattern = "opencode_output",
        callback = function(ev)
          vim.keymap.set("n", "gf", function()
            require("neovia.navigate").open()
          end, { buffer = ev.buf, desc = "Open file in code window" })
        end,
      })
    end,
  },
}
