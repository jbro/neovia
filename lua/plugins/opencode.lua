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
    end,
  },
}
