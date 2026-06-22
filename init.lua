-- neovia init.lua
-- Bootstrap lazy.nvim, set options, load plugins.

------------------------------------------------------------------------
-- Leader (must be set before lazy.nvim loads plugins)
------------------------------------------------------------------------
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Disable netrw (neo-tree replaces it; netrw's lcd and mouse handling
-- conflict with tcd-based worktree switching and the tabline).
vim.g.loaded_netrwPlugin = 1
vim.g.loaded_netrw = 1

------------------------------------------------------------------------
-- Bootstrap lazy.nvim
------------------------------------------------------------------------
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

------------------------------------------------------------------------
-- Core options
------------------------------------------------------------------------

-- Clear shell fzf colors so fzf-lua can derive them from the colorscheme.
vim.env.FZF_DEFAULT_OPTS = nil

-- Indentation (fallback; vim-sleuth auto-detects per buffer)
vim.o.expandtab = true
vim.o.shiftwidth = 2
vim.o.tabstop = 2

-- Search
vim.o.ignorecase = true
vim.o.smartcase = true

-- Display
vim.o.number = true
vim.o.relativenumber = true
vim.o.signcolumn = "yes"
vim.o.list = true
vim.opt.listchars = { tab = "→ ", trail = "·", nbsp = "␣" }
vim.o.wrap = false
vim.o.belloff = ""
vim.o.visualbell = true

-- Undo
vim.o.undofile = true

-- Folds (treesitter-based, not auto-collapsed)
vim.o.foldmethod = "expr"
vim.o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.o.foldenable = false

-- Diff
vim.opt.diffopt:append("vertical")

-- Completion
vim.o.completeopt = "menuone,noselect"
vim.o.wildmode = "longest,full"

-- Spell (treesitter-aware: only checks strings/comments, not code)
vim.o.spell = true
vim.o.spelllang = "en_gb,da"
vim.o.spelloptions = "camel"

------------------------------------------------------------------------
-- Core keymaps
------------------------------------------------------------------------

-- F1 fat finger protection
vim.keymap.set({ "n", "i" }, "<F1>", "<Nop>")

-- Clear search highlights on Esc
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

------------------------------------------------------------------------
-- Environment (must run before plugins so subprocesses inherit the env)
-- Machine-specific config lives in .env.lua (gitignored).
-- Guarded: env vars persist in the process, skip on re-source.
------------------------------------------------------------------------
if not vim.g.neovia_env_loaded then
  vim.g.neovia_env_loaded = true
  local env_specs = loadfile(vim.fn.stdpath("config") .. "/.env.lua")
  if env_specs then
    require("neovia.env").setup(env_specs())
  end
end

------------------------------------------------------------------------
-- Server (start opencode serve before plugins so the port is available)
-- Guarded: the server survives Neovim restarts, skip on re-source.
------------------------------------------------------------------------
if not vim.g.neovia_server_started then
  vim.g.neovia_server_started = true
  require("neovia.server").setup()
  local port, err = require("neovia.server").ensure_running()
  if port then
    vim.g.neovia_server_port = port
  elseif err then
    vim.notify("neovia: server start failed: " .. err, vim.log.levels.WARN)
  end
end

------------------------------------------------------------------------
-- Load plugins (skip on re-source; use :Lazy sync to update plugins)
------------------------------------------------------------------------
if not vim.g.neovia_lazy_loaded then
  vim.g.neovia_lazy_loaded = true
  require("lazy").setup("plugins", {
    change_detection = { notify = false },
  })
end

------------------------------------------------------------------------
-- Version tracking (server vs system binary, statusline display)
------------------------------------------------------------------------
require("neovia.version").setup()

------------------------------------------------------------------------
-- Layout (enforce code + opencode panels, open opencode on launch)
------------------------------------------------------------------------
require("neovia.layout").setup()

------------------------------------------------------------------------
-- Worktree (SSE subscriptions, tabline status tracking)
------------------------------------------------------------------------
require("neovia.worktree").setup()

------------------------------------------------------------------------
-- Diffview (per-worktree diffview tab management)
------------------------------------------------------------------------
require("neovia.diffview").setup()

------------------------------------------------------------------------
-- PR status (GitHub PR polling for tabline/statusline)
------------------------------------------------------------------------
require("neovia.pr").setup()

------------------------------------------------------------------------
-- Theme (persist light/dark across restarts)
------------------------------------------------------------------------
require("neovia.theme").setup()
require("neovia.theme").apply()

------------------------------------------------------------------------
-- Server keymaps (lifecycle management)
------------------------------------------------------------------------
vim.keymap.set("n", "<leader>oEs", function()
  local s = require("neovia.server").status()
  local lines
  if s.state == "running" then
    lines = {
      "opencode server: running",
      ("  port: %d"):format(s.port),
      ("  pid:  %d"):format(s.pid),
    }
  else
    lines = { "opencode server: stopped" }
  end

  local profile = require("neovia.env").active_profile()
  if profile then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("env profile: %s"):format(profile)
  end

  -- Pad each line and add blank top/bottom rows for breathing room.
  local padded = { "" }
  for _, l in ipairs(lines) do
    padded[#padded + 1] = "  " .. l
  end
  padded[#padded + 1] = ""
  lines = padded

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.max(width + 4, 32)
  local height = #lines

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " opencode server (q to close) ",
    title_pos = "center",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
end, { desc = "Server status" })

vim.keymap.set("n", "<leader>oEr", function()
  vim.notify("opencode server: restarting...", vim.log.levels.INFO)
  -- Adopt the latest global env-profile selection (possibly chosen in
  -- another neovia instance) before the new server inherits the env.
  require("neovia.env").apply_active()
  local srv = require("neovia.server")
  srv.restart(function(err, port)
    vim.schedule(function()
      if err then
        vim.notify("opencode server: restart failed: " .. err, vim.log.levels.ERROR)
      else
        srv.reconnect_plugin(port)
        vim.notify(("opencode server: restarted on port %d"):format(port), vim.log.levels.INFO)
        require("neovia.layout").apply()
      end
    end)
  end)
end, { desc = "Restart server" })

vim.keymap.set("n", "<leader>oEq", function()
  local srv = require("neovia.server")
  srv.disconnect_plugin()
  local stopped = srv.stop()
  if stopped then
    vim.notify("opencode server: stopped", vim.log.levels.INFO)
  else
    vim.notify("opencode server: was not running", vim.log.levels.WARN)
  end
end, { desc = "Shutdown server" })

-- Switch the active env profile (API key / base URL set), then restart the
-- opencode server so it inherits the new environment.
vim.keymap.set("n", "<leader>oEp", function()
  local env = require("neovia.env")
  local profiles = env.profiles()
  if #profiles == 0 then
    vim.notify("env: no profiles configured (see .env.lua)", vim.log.levels.WARN)
    return
  end

  local active = env.active_profile()
  local function restart_with(name)
    local ok, err = env.select_profile(name)
    if not ok then
      vim.notify("env: " .. (err or "failed to select profile"), vim.log.levels.ERROR)
      return
    end
    vim.notify(("env: profile '%s' selected, restarting server..."):format(name), vim.log.levels.INFO)
    local srv = require("neovia.server")
    srv.restart(function(rerr, port)
      vim.schedule(function()
        if rerr then
          vim.notify("opencode server: restart failed: " .. rerr, vim.log.levels.ERROR)
        else
          srv.reconnect_plugin(port)
          vim.notify(("env: profile '%s' active (server port %d)"):format(name, port), vim.log.levels.INFO)
          require("neovia.layout").apply()
        end
      end)
    end)
  end

  local labels = {}
  for _, name in ipairs(profiles) do
    labels[#labels + 1] = name == active and (name .. " (active)") or name
  end

  local ok_fzf, fzf = pcall(require, "fzf-lua")
  if ok_fzf then
    fzf.fzf_exec(labels, {
      prompt = "Env profile> ",
      winopts = { height = 0.3, width = 0.4 },
      previewer = false,
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then return end
          restart_with((selected[1]:gsub(" %(active%)$", "")))
        end,
      },
    })
  else
    vim.ui.select(profiles, { prompt = "Env profile" }, function(choice)
      if choice then restart_with(choice) end
    end)
  end
end, { desc = "Switch env profile" })

------------------------------------------------------------------------
-- Magic Context integration (context/memory status from RPC)
------------------------------------------------------------------------
require("neovia.magic_context").setup()
vim.keymap.set("n", "<leader>oc", function() require("neovia.magic_context").show_popup() end, { desc = "Context status" })

------------------------------------------------------------------------
-- Session notes (per-worktree persistent notes)
------------------------------------------------------------------------
require("neovia.notes").setup()

------------------------------------------------------------------------
-- Read-only mode
------------------------------------------------------------------------
require("neovia.mode").setup({ auto_relock = true })
vim.keymap.set("n", "<leader>bu", function() require("neovia.mode").toggle() end, { desc = "Unlock/lock buffer" })
vim.keymap.set("n", "<leader>bw", function() vim.wo.wrap = not vim.wo.wrap end, { desc = "Toggle wrap" })
vim.keymap.set("n", "<leader>pp", function()
  local view = require("lazy.view")
  if view.visible() then
    view.view:close()
  else
    view.show()
  end
end, { desc = "Lazy" })
vim.keymap.set("n", "<leader>pr", function() require("neovia.reload").reload() end, { desc = "Reload config" })
vim.keymap.set("n", "<leader>l", function() require("neovia.layout").apply() end, { desc = "Restore layout" })
vim.keymap.set("n", "<leader>tl", function() require("neovia.theme").set_flavour("latte") end, { desc = "Latte (light)" })
vim.keymap.set("n", "<leader>tf", function() require("neovia.theme").set_flavour("frappe") end, { desc = "Frappe" })
vim.keymap.set("n", "<leader>tm", function() require("neovia.theme").set_flavour("macchiato") end, { desc = "Macchiato" })
vim.keymap.set("n", "<leader>td", function() require("neovia.theme").set_flavour("mocha") end, { desc = "Mocha (darkest)" })
vim.keymap.set("n", "<leader>tn", function() require("neovia.theme").toggle() end, { desc = "Next flavour" })
vim.keymap.set("n", "<leader>q", "<cmd>qa<cr>", { desc = "Quit all" })

------------------------------------------------------------------------
-- LSP configuration (native 0.11+)
------------------------------------------------------------------------
vim.lsp.config("ts_ls", {
  cmd = { "typescript-language-server", "--stdio" },
  filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
  root_markers = { "tsconfig.json", "jsconfig.json", "package.json", ".git" },
})

vim.lsp.config("gopls", {
  cmd = { "gopls" },
  filetypes = { "go", "gomod", "gowork", "gotmpl" },
  root_markers = { "go.mod", "go.work", ".git" },
})

vim.lsp.enable({ "ts_ls", "gopls" })

