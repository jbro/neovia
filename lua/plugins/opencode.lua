-- opencode.nvim + render-markdown.nvim
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
      require("opencode").setup({
        preferred_picker = "fzf",
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
          },
          input_window = {
            ["<esc>"] = false,
          },
          output_window = {
            ["<esc>"] = false,
          },
        },
        hooks = {
          on_done_thinking = function()
            require("neovia.worktree").set_status(vim.fn.getcwd(-1, 0), "idle")
          end,
          on_permission_requested = function()
            require("neovia.worktree").set_status(vim.fn.getcwd(-1, 0), "needs_attention")
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
