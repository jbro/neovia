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

      -- Keep table-width system prompt in sync with window size.
      local resize_group = vim.api.nvim_create_augroup("neovia_opencode_table_width", { clear = true })
      vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = resize_group,
        callback = refresh_table_width_prompt,
      })
    end,
  },
}
