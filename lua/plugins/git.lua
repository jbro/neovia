-- Git: gitsigns + diffview + fugitive + review

--- Get the relative file path for the current diffview entry.
--- Returns nil if not in a diffview or no file is selected.
--- @return string|nil
local function diffview_current_file()
  local ok, dv = pcall(require, "neovia.diffview")
  if not ok then return nil end
  return dv.current_file()
end

--- Get the worktree directory for the current tab.
--- @return string
local function current_dir()
  return vim.fn.getcwd(-1, 0)
end

return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    keys = {
      { "<leader>gb", function() require("gitsigns").blame_line() end, desc = "Blame line" },
    },
    opts = {},
  },
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
      { "<leader>dd", function() require("neovia.diffview").toggle_diff(current_dir()) end, desc = "Toggle diff" },
      { "<leader>dh", function() require("neovia.diffview").toggle_history(current_dir()) end, desc = "Toggle file history" },

      -- Review keymaps
      {
        "<leader>rc",
        function()
          local file = diffview_current_file()
          if not file then
            vim.notify("No file selected in diffview", vim.log.levels.WARN)
            return
          end
          local dir = current_dir()
          local line = vim.fn.line(".")
          local end_line = nil

          -- Visual mode: get range
          local mode = vim.fn.mode()
          if mode == "v" or mode == "V" or mode == "\22" then
            vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
            local start_line = vim.fn.line("'<")
            end_line = vim.fn.line("'>")
            line = start_line
          end

          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          review.open_comment_input({
            title = " Add Review Comment ",
            on_submit = function(text)
              review.add_comment(dir, {
                file = file,
                line = line,
                end_line = end_line,
                text = text,
              })
              review.render_extmarks(vim.api.nvim_get_current_buf(), file, dir)
            end,
          })
        end,
        mode = { "n", "v" },
        desc = "Add review comment",
      },
      {
        "<leader>re",
        function()
          local file = diffview_current_file()
          if not file then return end
          local dir = current_dir()
          local line = vim.fn.line(".")

          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local comment = review.find_comment_at_line(dir, file, line)
          if not comment then
            vim.notify("No review comment at this line", vim.log.levels.INFO)
            return
          end
          review.open_comment_input({
            title = " Edit Review Comment ",
            default = comment.text,
            on_submit = function(text)
              review.edit_comment(dir, comment.id, text)
              review.render_extmarks(vim.api.nvim_get_current_buf(), file, dir)
            end,
          })
        end,
        desc = "Edit review comment",
      },
      {
        "<leader>rd",
        function()
          local file = diffview_current_file()
          if not file then return end
          local dir = current_dir()
          local line = vim.fn.line(".")

          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local comment = review.find_comment_at_line(dir, file, line)
          if not comment then
            vim.notify("No review comment at this line", vim.log.levels.INFO)
            return
          end
          review.delete_comment(dir, comment.id)
          review.render_extmarks(vim.api.nvim_get_current_buf(), file, dir)
        end,
        desc = "Delete review comment",
      },
      {
        "<leader>rx",
        function()
          local file = diffview_current_file()
          if not file then return end
          local dir = current_dir()
          local line = vim.fn.line(".")

          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local comment = review.find_comment_at_line(dir, file, line)
          if not comment then
            vim.notify("No review comment at this line", vim.log.levels.INFO)
            return
          end
          if comment.state ~= "resolved" then
            vim.notify("Comment is not resolved", vim.log.levels.INFO)
            return
          end
          review.set_state(dir, comment.id, "rereview")
          review.render_extmarks(vim.api.nvim_get_current_buf(), file, dir)
        end,
        desc = "Reject resolved comment",
      },
      {
        "<leader>rS",
        function()
          local dir = current_dir()
          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local ok = review.submit(dir)
          if not ok then
            vim.notify("No actionable review comments", vim.log.levels.INFO)
          end
        end,
        desc = "Submit review to OpenCode",
      },
      {
        "<leader>rn",
        function()
          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local buf = vim.api.nvim_get_current_buf()
          local line = review.jump_to_comment(buf, vim.fn.line("."), "next")
          if line then
            vim.api.nvim_win_set_cursor(0, { line, 0 })
          else
            vim.notify("No review comments in this file", vim.log.levels.INFO)
          end
        end,
        desc = "Next review comment",
      },
      {
        "<leader>rp",
        function()
          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local buf = vim.api.nvim_get_current_buf()
          local line = review.jump_to_comment(buf, vim.fn.line("."), "prev")
          if line then
            vim.api.nvim_win_set_cursor(0, { line, 0 })
          else
            vim.notify("No review comments in this file", vim.log.levels.INFO)
          end
        end,
        desc = "Previous review comment",
      },
      {
        "<leader>rD",
        function()
          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          local dir = current_dir()
          local comments = review.get_comments(dir)
          if #comments == 0 then
            vim.notify("No review comments", vim.log.levels.INFO)
            return
          end
          vim.ui.select({ "Yes", "No" }, {
            prompt = "Delete all " .. #comments .. " review comments?",
          }, function(choice)
            if choice == "Yes" then
              review.delete_all(dir)
              vim.notify("Deleted all review comments", vim.log.levels.INFO)
            end
          end)
        end,
        desc = "Delete all review comments",
      },
    },
    opts = {
      hooks = {
        diff_buf_win_enter = function(bufnr, _winid, ctx)
          -- Render review extmarks on the new (right/working tree) side
          -- every time a diff buffer is displayed (file switch, tab enter, etc.).
          if ctx.symbol ~= "b" then return end
          local file = diffview_current_file()
          if not file then return end
          local dir = current_dir()
          local ok_rev, review = pcall(require, "neovia.review")
          if not ok_rev then return end
          review.render_extmarks(bufnr, file, dir)

          -- Also refresh file panel indicators (panel is rendered by now).
          local ok_lib, lib = pcall(require, "diffview.lib")
          if ok_lib then
            local view = lib.get_current_view()
            if view and view.panel and view.panel.bufnr then
              review.render_file_panel_indicators(view.panel.bufnr, dir)
            end
          end
        end,
      },
    },
  },
  {
    "tpope/vim-fugitive",
    cmd = "Git",
    keys = {
      { "<leader>gs", "<cmd>Git<cr>", desc = "Git status" },
    },
  },
}
