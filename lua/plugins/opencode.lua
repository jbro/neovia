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
        hooks = {
          on_done_thinking = function()
            require("neovia.worktree").set_status(vim.fn.getcwd(), "idle")
          end,
          on_permission_requested = function()
            require("neovia.worktree").set_status(vim.fn.getcwd(), "needs_attention")
          end,
        },
      })

      -- gf in opencode output: open file in the code window (left pane)
      vim.api.nvim_create_autocmd("FileType", {
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
