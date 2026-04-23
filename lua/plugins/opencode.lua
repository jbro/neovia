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
