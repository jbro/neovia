-- neovia worktree module
-- Worktree picker, status tracking via SSE, lualine components.

local M = {}

--- @class neovia.WorktreeEntry
--- @field path string Absolute path to the worktree
--- @field branch string Branch name (or "(detached)")
--- @field head string Short SHA
--- @field bare boolean

--- @class neovia.WorktreeState
--- @field status "unknown"|"idle"|"responding"|"needs_attention"
--- @field branch string
--- @field subscription table|nil  curl job handle from subscribe_to_events
--- @field pending_permissions table<string, boolean>  permission IDs awaiting reply

--- Per-directory state. Keyed by absolute path.
--- @type table<string, neovia.WorktreeState>
local state = {}

--- Tab-to-directory mapping. Keyed by tab page handle.
--- @type table<integer, string>
local tab_map = {}

--- Whether setup() has been called.
local initialised = false

--- Timer handle for DirChanged debounce (nil = no pending call).
--- @type uv_timer_t|nil
local dir_timer = nil

--- The git common dir for the repo we're tracking (nil = not yet resolved).
--- @type string|nil
local git_common_dir = nil

-- Forward declarations
local ensure_subscriptions, list_worktrees, unsubscribe_all

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

--- Resolve the git common dir (shared across all worktrees).
--- Returns nil if not inside a git repo.
--- @return string|nil
local function resolve_git_common_dir()
  local result = vim.system({ "git", "rev-parse", "--git-common-dir" }, { text = true }):wait()
  if result.code ~= 0 then return nil end
  local dir = vim.trim(result.stdout or "")
  if dir == "" then return nil end
  -- Make absolute
  if not vim.startswith(dir, "/") then
    dir = vim.fn.getcwd() .. "/" .. dir
  end
  return vim.fn.fnamemodify(dir, ":p:h")
end

--- Parse `git worktree list --porcelain` output.
--- @param output string
--- @return neovia.WorktreeEntry[]
local function parse_worktree_porcelain(output)
  local entries = {} --- @type neovia.WorktreeEntry[]
  local current = nil --- @type neovia.WorktreeEntry|nil

  for line in output:gmatch("[^\n]+") do
    if line:match("^worktree ") then
      if current then table.insert(entries, current) end
      current = {
        path = line:sub(10),
        branch = "",
        head = "",
        bare = false,
      }
    elseif current then
      if line:match("^HEAD ") then
        current.head = line:sub(6, 12) -- short sha
      elseif line:match("^branch ") then
        current.branch = line:sub(8):gsub("^refs/heads/", "")
      elseif line == "bare" then
        current.bare = true
      elseif line == "detached" then
        current.branch = "(detached)"
      end
    end
  end
  if current then table.insert(entries, current) end
  return entries
end

--- List all git worktrees for the current repo.
--- @return neovia.WorktreeEntry[]
list_worktrees = function()
  local result = vim.system({ "git", "worktree", "list", "--porcelain" }, { text = true }):wait()
  if result.code ~= 0 then return {} end
  local entries = parse_worktree_porcelain(result.stdout or "")
  -- Filter out bare entries
  return vim.tbl_filter(function(e) return not e.bare end, entries)
end

--- ANSI colour codes for status.
--- @type table<string, string>
local status_ansi = {
  idle = "\27[32m",            -- green
  responding = "\27[33m",      -- yellow
  needs_attention = "\27[31m", -- red
  unknown = "\27[90m",         -- dim grey
}
local ansi_reset = "\27[0m"

--- Status icons (text, no emoji per AGENTS.md).
--- @type table<string, string>
local status_icon = {
  idle = "[idle]",
  responding = "[working]",
  needs_attention = "[needs you]",
  unknown = "[idle]",
}

--- Highlight groups used by lualine components.
--- @type table<string, table>
local status_hl = {
  idle = { fg = "#9ece6a" },            -- tokyonight green
  responding = { fg = "#e0af68" },      -- tokyonight yellow
  needs_attention = { fg = "#f7768e" }, -- tokyonight red
  unknown = { fg = "#565f89" },         -- tokyonight comment
}

------------------------------------------------------------------------
-- Tab tracking
------------------------------------------------------------------------

--- Register a tab as associated with a worktree directory.
--- @param tab_id integer  Tab page handle
--- @param dir string  Absolute worktree path
local function register_tab(tab_id, dir)
  tab_map[tab_id] = dir
end

--- Get the directory associated with a tab.
--- @param tab_id integer
--- @return string|nil
local function get_tab_dir(tab_id)
  return tab_map[tab_id]
end

--- Find the tab associated with a directory.
--- @param dir string
--- @return integer|nil
local function find_tab_for_dir(dir)
  for tab_id, tab_dir in pairs(tab_map) do
    if tab_dir == dir then return tab_id end
  end
  return nil
end

--- Remove a tab from the mapping.
--- @param tab_id integer
local function unregister_tab(tab_id)
  tab_map[tab_id] = nil
end

------------------------------------------------------------------------
-- Worktree path derivation
------------------------------------------------------------------------

--- Derive the path for a new worktree based on existing worktree layout.
--- Pure function: takes parsed worktree entries, returns a path string.
---
--- Convention detection:
--- 1. If all linked worktrees share a common parent dir, use that dir.
--- 2. Otherwise (no linked worktrees, or mixed), use sibling of main.
---
--- @param branch string  Branch name for the new worktree
--- @param worktrees neovia.WorktreeEntry[]  Parsed worktree list (non-bare)
--- @return string path  Absolute path for the new worktree
local function derive_worktree_path(branch, worktrees)
  if #worktrees == 0 then return branch end

  local main_path = worktrees[1].path

  -- Collect linked worktree paths (everything after the first/main entry)
  local linked = {} --- @type string[]
  for i = 2, #worktrees do
    table.insert(linked, worktrees[i].path)
  end

  -- If there are linked worktrees, check if they share a common parent
  if #linked > 0 then
    local common_parent = vim.fn.fnamemodify(linked[1], ":h")
    local all_same = true
    for i = 2, #linked do
      if vim.fn.fnamemodify(linked[i], ":h") ~= common_parent then
        all_same = false
        break
      end
    end
    if all_same then
      return common_parent .. "/" .. branch
    end
  end

  -- Default: sibling of main worktree
  local parent = vim.fn.fnamemodify(main_path, ":h")
  return parent .. "/" .. branch
end

------------------------------------------------------------------------
-- Worktree creation result parsing
------------------------------------------------------------------------

--- @class neovia.CreateResult
--- @field status "ok"|"branch_exists"|"error"
--- @field existing_worktree string|nil  Path if a worktree already exists for the branch
--- @field message string|nil  Error message for "error" status

--- Parse the result of `git worktree add -b`.
--- Pure function: takes exit code, stderr, branch name, and worktree list.
--- @param code integer  Exit code
--- @param stderr string  Standard error output
--- @param branch string  Branch name attempted
--- @param worktrees neovia.WorktreeEntry[]  Current worktree list
--- @return neovia.CreateResult
local function parse_create_result(code, stderr, branch, worktrees)
  if code == 0 then
    return { status = "ok" }
  end

  -- Check for "branch already exists" error
  if stderr:match("already exists") then
    -- Check if a worktree already exists for this branch
    local existing = nil
    for _, wt in ipairs(worktrees) do
      if wt.branch == branch then
        existing = wt.path
        break
      end
    end
    return { status = "branch_exists", existing_worktree = existing }
  end

  return { status = "error", message = stderr }
end

------------------------------------------------------------------------
-- Worktree deletion result parsing
------------------------------------------------------------------------

--- @class neovia.DeleteResult
--- @field status "ok"|"dirty"|"error"
--- @field message string|nil

--- Parse the result of `git worktree remove`.
--- @param code integer
--- @param stderr string
--- @return neovia.DeleteResult
local function parse_delete_result(code, stderr)
  if code == 0 then return { status = "ok" } end
  if stderr:match("modified or untracked") or stderr:match("use %-%-force") then
    return { status = "dirty" }
  end
  return { status = "error", message = stderr }
end

--- @class neovia.BranchDeleteResult
--- @field status "ok"|"not_merged"|"error"
--- @field message string|nil

--- Parse the result of `git branch -d`.
--- @param code integer
--- @param stderr string
--- @return neovia.BranchDeleteResult
local function parse_branch_delete_result(code, stderr)
  if code == 0 then return { status = "ok" } end
  if stderr:match("not fully merged") then
    return { status = "not_merged" }
  end
  return { status = "error", message = stderr }
end

------------------------------------------------------------------------
-- SSE event processing
------------------------------------------------------------------------

--- Process a single SSE event and update a state entry.
--- Pure-ish: mutates `entry` in place, returns true if status changed.
--- Separated from side effects (redrawstatus) for testability.
--- @param entry neovia.WorktreeState
--- @param event table  decoded JSON event {type, properties}
--- @return boolean changed
local function apply_event(entry, event)
  local prev = entry.status
  local t = event.type
  local props = event.properties or {}

  if t == "session.idle" then
    entry.status = "idle"
    entry.pending_permissions = {}

  elseif t == "message.updated" then
    local info = props.info or props
    if info.role == "assistant" then
      if info.time and info.time.completed then
        entry.status = "idle"
      else
        entry.status = "responding"
      end
    end

  elseif t == "permission.asked" then
    entry.status = "needs_attention"
    local id = props.id or props.requestID
    if id then entry.pending_permissions[id] = true end

  elseif t == "permission.replied" then
    local id = props.requestID or props.id
    if id then entry.pending_permissions[id] = nil end
    -- If no more pending permissions, revert to responding or idle
    if vim.tbl_isempty(entry.pending_permissions) then
      -- We don't have direct job_count info; assume responding if we were
      -- needs_attention, it will settle via session.idle later.
      entry.status = "responding"
    end

  elseif t == "session.error" then
    entry.status = "idle"
    entry.pending_permissions = {}

  elseif t == "server.connected" then
    -- Connection established; default to idle if still unknown
    if entry.status == "unknown" then
      entry.status = "idle"
    end
  end

  return entry.status ~= prev
end

--- Process a single SSE event and update state for the given directory.
--- @param dir string
--- @param event table  decoded JSON event {type, properties}
local function process_event(dir, event)
  local entry = state[dir]
  if not entry then return end

  if apply_event(entry, event) then
    vim.cmd.redrawstatus()
  end
end

--- Subscribe to SSE events for a single worktree directory.
--- @param dir string
local function subscribe_one(dir)
  local oc_state = package.loaded["opencode.state"]
  if not oc_state then return end

  local api_client = oc_state.api_client
  if not api_client then return end

  local handle = api_client:subscribe_to_events(dir, function(event)
    vim.schedule(function()
      process_event(dir, event)
    end)
  end)

  if state[dir] then
    state[dir].subscription = handle
  end
end

--- Ensure every known worktree has an active SSE subscription.
--- Called on pick() open, DirChanged, and initial setup.
ensure_subscriptions = function()
  local worktrees = list_worktrees()
  if #worktrees == 0 then return end

  -- Track which dirs are still valid
  local valid = {} --- @type table<string, boolean>

  for _, wt in ipairs(worktrees) do
    valid[wt.path] = true

    if not state[wt.path] then
      state[wt.path] = {
        status = "unknown",
        branch = wt.branch,
        pending_permissions = {},
      }
    else
      -- Update branch in case it changed
      state[wt.path].branch = wt.branch
    end

    -- Subscribe if not already subscribed (or if subscription died)
    local entry = state[wt.path]
    local alive = entry.subscription
      and type(entry.subscription.is_running) == "function"
      and entry.subscription.is_running()
    if not alive then
      -- Clean up dead handle
      if entry.subscription and type(entry.subscription.shutdown) == "function" then
        pcall(entry.subscription.shutdown)
      end
      entry.subscription = nil
      subscribe_one(wt.path)
    end
  end

  -- Remove state for worktrees that no longer exist
  for dir, entry in pairs(state) do
    if not valid[dir] then
      if entry.subscription and type(entry.subscription.shutdown) == "function" then
        pcall(entry.subscription.shutdown)
      end
      state[dir] = nil
    end
  end
end

--- Shut down all SSE subscriptions.
unsubscribe_all = function()
  for dir, entry in pairs(state) do
    if entry.subscription and type(entry.subscription.shutdown) == "function" then
      pcall(entry.subscription.shutdown)
    end
    entry.subscription = nil
  end
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- Initialise the module. Idempotent.
function M.setup()
  if initialised then return end
  initialised = true

  git_common_dir = resolve_git_common_dir()
  if not git_common_dir then return end

  -- Register the initial tab for the current worktree
  local initial_tab = vim.api.nvim_get_current_tabpage()
  register_tab(initial_tab, vim.fn.getcwd())

  -- Set custom tabline showing branch names
  vim.o.showtabline = 2  -- always show tabline
  vim.o.tabline = "%!v:lua.require('neovia.worktree').tabline()"

  local group = vim.api.nvim_create_augroup("neovia_worktree", { clear = true })

  -- Clean up tab mapping when tabs are closed
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      -- Remove stale tab entries (tabs that no longer exist)
      local valid_tabs = {} --- @type table<integer, boolean>
      for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
        valid_tabs[tp] = true
      end
      for tab_id in pairs(tab_map) do
        if not valid_tabs[tab_id] then
          unregister_tab(tab_id)
        end
      end
    end,
    desc = "neovia: clean up tab map on tab close",
  })

  -- Clean up subscriptions on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() unsubscribe_all() end,
    desc = "neovia: clean up worktree SSE subscriptions",
  })

  -- Refresh worktree list on directory change (debounced)
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      if dir_timer then
        dir_timer:stop()
        dir_timer:close()
      end
      dir_timer = vim.uv.new_timer()
      dir_timer:start(500, 0, vim.schedule_wrap(function()
        dir_timer:close()
        dir_timer = nil
        ensure_subscriptions()
      end))
    end,
    desc = "neovia: refresh worktree subscriptions on tcd",
  })

  -- Defer initial subscription until opencode server is ready.
  -- Listen for the server_ready custom event.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OpencodeEvent:server.connected",
    once = true,
    callback = function()
      vim.defer_fn(function() ensure_subscriptions() end, 1000)
    end,
    desc = "neovia: subscribe to worktree SSE on server ready",
  })

  -- Also try immediately in case the server is already running
  vim.defer_fn(function()
    local oc_state = package.loaded["opencode.state"]
    if oc_state and oc_state.api_client then
      ensure_subscriptions()
    end
  end, 2000)
end

------------------------------------------------------------------------
-- Public API: status mutation (for hooks)
------------------------------------------------------------------------

--- Directly set the status for a directory. Used by opencode hooks as
--- belt-and-suspenders alongside SSE events.
--- @param dir string
--- @param new_status "idle"|"responding"|"needs_attention"
function M.set_status(dir, new_status)
  if not state[dir] then return end
  state[dir].status = new_status
  if new_status == "idle" then
    state[dir].pending_permissions = {}
  end
  vim.cmd.redrawstatus()
end

------------------------------------------------------------------------
-- Tab + session helpers
------------------------------------------------------------------------

--- Open a worktree directory in a new tab with opencode.
--- @param dir string  Absolute worktree path
local function open_in_new_tab(dir)
  vim.cmd.tabnew()
  vim.cmd.tcd(dir)
  local tab_id = vim.api.nvim_get_current_tabpage()
  register_tab(tab_id, dir)

  -- Auto-open opencode input in the new tab (deferred to let tcd settle)
  vim.defer_fn(function()
    local ok, opencode = pcall(require, "opencode")
    if ok and opencode.api then
      opencode.api.open_input()
    end
  end, 100)
end

--- Prompt user to fork or create blank session, then open a worktree
--- in a new tab with opencode.
--- @param dir string  Absolute worktree path
local function prompt_session_and_open_tab(dir)
  local fzf = require("fzf-lua")

  -- Check if there's a current active session worth forking
  local oc_state = package.loaded["opencode.state"]
  local active_session = oc_state and oc_state.session and oc_state.session.get_active()

  if not active_session then
    -- No active session to fork -- go straight to new tab
    open_in_new_tab(dir)
    return
  end

  fzf.fzf_exec({ "Blank session", "Fork current session" }, {
    prompt = "Session> ",
    fzf_opts = {
      ["--no-multi"] = "",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local choice = selected[1]

        if choice == "Fork current session" then
          local api_client = oc_state.api_client
          if api_client then
            api_client:fork_session(active_session.id, nil, dir):next(function(forked)
              vim.schedule(function()
                open_in_new_tab(dir)
              end)
            end, function(err)
              vim.schedule(function()
                vim.notify("Fork failed: " .. tostring(err) .. " -- opening blank session", vim.log.levels.WARN)
                open_in_new_tab(dir)
              end)
            end)
          else
            open_in_new_tab(dir)
          end
        else
          open_in_new_tab(dir)
        end
      end,
    },
  })
end

------------------------------------------------------------------------
-- Worktree creation
------------------------------------------------------------------------

--- Create a new worktree and open it in a new tab.
--- Prompts for branch name, derives path, runs git worktree add,
--- handles errors, and offers session fork/blank choice.
function M.create()
  M.setup()

  local worktrees = list_worktrees()

  vim.ui.input({ prompt = "Branch name: " }, function(branch)
    if not branch or branch == "" then return end

    local path = derive_worktree_path(branch, worktrees)

    -- Try creating with -b (new branch)
    local result = vim.system(
      { "git", "worktree", "add", "-b", branch, path },
      { text = true }
    ):wait()

    local parsed = parse_create_result(result.code, result.stderr or "", branch, worktrees)

    if parsed.status == "ok" then
      vim.notify("Created worktree: " .. path, vim.log.levels.INFO)
      prompt_session_and_open_tab(path)

    elseif parsed.status == "branch_exists" then
      if parsed.existing_worktree then
        -- Worktree already exists for this branch -- offer to switch
        vim.notify("Worktree already exists for '" .. branch .. "' -- switching", vim.log.levels.INFO)
        local existing_tab = find_tab_for_dir(parsed.existing_worktree)
        if existing_tab then
          vim.api.nvim_set_current_tabpage(existing_tab)
        else
          prompt_session_and_open_tab(parsed.existing_worktree)
        end
      else
        -- Branch exists but no worktree -- create worktree without -b
        local retry = vim.system(
          { "git", "worktree", "add", path, branch },
          { text = true }
        ):wait()
        if retry.code == 0 then
          vim.notify("Created worktree from existing branch: " .. path, vim.log.levels.INFO)
          prompt_session_and_open_tab(path)
        else
          vim.notify("Failed to create worktree: " .. (retry.stderr or ""), vim.log.levels.ERROR)
        end
      end

    else
      vim.notify("Failed to create worktree: " .. (parsed.message or "unknown error"), vim.log.levels.ERROR)
    end
  end)
end

------------------------------------------------------------------------
-- Worktree deletion
------------------------------------------------------------------------

--- Clean up tab and state for a deleted worktree directory.
--- @param dir string
local function cleanup_deleted_worktree(dir)
  -- Close the tab if one exists
  local tab_id = find_tab_for_dir(dir)
  if tab_id then
    -- Switch away first if we're on the tab being closed
    local current_tab = vim.api.nvim_get_current_tabpage()
    if tab_id == current_tab then
      local tabs = vim.api.nvim_list_tabpages()
      for _, tp in ipairs(tabs) do
        if tp ~= tab_id then
          vim.api.nvim_set_current_tabpage(tp)
          break
        end
      end
    end
    pcall(vim.api.nvim_command, "tabclose " .. vim.fn.tabpagenr("#"))
    -- Use a more reliable approach: find the tab's window and close it
    local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, tab_id)
    if ok then
      for _, win in ipairs(wins) do
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    unregister_tab(tab_id)
  end

  -- Clean up SSE subscription and state
  local entry = state[dir]
  if entry then
    if entry.subscription and type(entry.subscription.shutdown) == "function" then
      pcall(entry.subscription.shutdown)
    end
    state[dir] = nil
  end
end

--- Delete a git branch, offering force if not fully merged.
--- @param branch string
local function delete_branch(branch)
  local result = vim.system(
    { "git", "branch", "-d", branch },
    { text = true }
  ):wait()

  local parsed = parse_branch_delete_result(result.code, result.stderr or "")

  if parsed.status == "ok" then
    vim.notify("Deleted worktree and branch '" .. branch .. "'", vim.log.levels.INFO)
    ensure_subscriptions()
  elseif parsed.status == "not_merged" then
    vim.ui.input({
      prompt = "Branch '" .. branch .. "' is not fully merged. Force delete? [y/N]: ",
    }, function(answer)
      if not answer or answer:lower() ~= "y" then
        vim.notify("Worktree removed, branch kept", vim.log.levels.INFO)
        ensure_subscriptions()
        return
      end
      local force_result = vim.system(
        { "git", "branch", "-D", branch },
        { text = true }
      ):wait()
      if force_result.code == 0 then
        vim.notify("Deleted worktree and branch '" .. branch .. "' (force)", vim.log.levels.INFO)
      else
        vim.notify("Failed to delete branch: " .. (force_result.stderr or ""), vim.log.levels.ERROR)
      end
      ensure_subscriptions()
    end)
  else
    vim.notify("Worktree removed. Branch delete failed: " .. (parsed.message or ""), vim.log.levels.WARN)
    ensure_subscriptions()
  end
end

--- Delete a worktree and its branch.
--- Opens a picker to select the worktree, then removes it and the branch.
--- Offers force options if the worktree is dirty or the branch is not merged.
function M.delete()
  M.setup()

  local fzf = require("fzf-lua")
  local worktrees = list_worktrees()
  local cwd = vim.fn.getcwd()

  -- Filter out the current worktree (can't delete what you're standing on)
  local deletable = {} --- @type neovia.WorktreeEntry[]
  for _, wt in ipairs(worktrees) do
    if wt.path ~= cwd then
      table.insert(deletable, wt)
    end
  end

  if #deletable == 0 then
    vim.notify("No worktrees to delete (can't delete the current one)", vim.log.levels.WARN)
    return
  end

  -- Build entries and lookup
  local entries = {} --- @type string[]
  local line_to_entry = {} --- @type table<string, neovia.WorktreeEntry>
  for _, wt in ipairs(deletable) do
    local display_path = wt.path:gsub("^" .. vim.pesc(vim.env.HOME), "~")
    local line = string.format("%-20s  %s", wt.branch, display_path)
    table.insert(entries, line)
    line_to_entry[line] = wt
  end

  fzf.fzf_exec(entries, {
    prompt = "Delete worktree> ",
    fzf_opts = {
      ["--no-multi"] = "",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local wt = line_to_entry[selected[1]]
        if not wt then return end

        -- Step 1: Remove the worktree
        local rm_result = vim.system(
          { "git", "worktree", "remove", wt.path },
          { text = true }
        ):wait()

        local rm_parsed = parse_delete_result(rm_result.code, rm_result.stderr or "")

        if rm_parsed.status == "dirty" then
          -- Offer force
          vim.ui.input({
            prompt = "Worktree has modifications. Force delete? [y/N]: ",
          }, function(answer)
            if not answer or answer:lower() ~= "y" then
              vim.notify("Aborted", vim.log.levels.INFO)
              return
            end
            local force_result = vim.system(
              { "git", "worktree", "remove", "--force", wt.path },
              { text = true }
            ):wait()
            if force_result.code ~= 0 then
              vim.notify("Force delete failed: " .. (force_result.stderr or ""), vim.log.levels.ERROR)
              return
            end
            cleanup_deleted_worktree(wt.path)
            delete_branch(wt.branch)
          end)
          return
        elseif rm_parsed.status == "error" then
          vim.notify("Failed to remove worktree: " .. (rm_parsed.message or ""), vim.log.levels.ERROR)
          return
        end

        -- Worktree removed successfully
        cleanup_deleted_worktree(wt.path)

        -- Step 2: Delete the branch
        delete_branch(wt.branch)
      end,
    },
  })
end

------------------------------------------------------------------------
-- Picker
------------------------------------------------------------------------

--- Open the worktree picker.
function M.pick()
  M.setup()

  -- Refresh worktree list and subscriptions
  ensure_subscriptions()

  local fzf = require("fzf-lua")
  local worktrees = list_worktrees()

  if #worktrees == 0 then
    vim.notify("No git worktrees found", vim.log.levels.WARN)
    return
  end

  local cwd = vim.fn.getcwd()

  -- Build entries and a lookup from display line to worktree path
  local entries = {} --- @type string[]
  local line_to_path = {} --- @type table<string, string>
  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path] or { status = "unknown" }
    local colour = status_ansi[entry.status] or status_ansi.unknown
    local icon = status_icon[entry.status] or ""
    local marker = wt.path == cwd and " *" or ""

    -- Show path relative to home for readability
    local display_path = wt.path:gsub("^" .. vim.pesc(vim.env.HOME), "~")

    local line = string.format(
      "%s%-20s%s  %s%s%s%s",
      colour, wt.branch, ansi_reset,
      display_path, marker,
      icon ~= "" and ("  " .. colour .. icon .. ansi_reset) or "",
      ""
    )
    table.insert(entries, line)
    line_to_path[line] = wt.path
  end

  fzf.fzf_exec(entries, {
    prompt = "Worktrees> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--no-multi"] = "",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end

        local match = selected[1]
        local target = match and line_to_path[match] or nil
        if not target then return end

        -- Check if a tab already exists for this worktree
        local existing_tab = find_tab_for_dir(target)
        if existing_tab then
          vim.api.nvim_set_current_tabpage(existing_tab)
          vim.notify("Switched to tab: " .. target, vim.log.levels.INFO)
        else
          -- Open in new tab; prompt for session fork/blank if no session exists
          prompt_session_and_open_tab(target)
        end
      end,
    },
  })
end

------------------------------------------------------------------------
-- Lualine components
------------------------------------------------------------------------

--- Define highlight groups.
local function define_highlights()
  for name, hl in pairs(status_hl) do
    vim.api.nvim_set_hl(0, "NeoviaWt_" .. name, hl)
  end
end

--- Set up highlights lazily, re-apply on colorscheme change.
local hl_initialised = false
local function ensure_highlights()
  if hl_initialised then return end
  hl_initialised = true
  define_highlights()
  local hl_group = vim.api.nvim_create_augroup("neovia_worktree_hl", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = hl_group,
    callback = define_highlights,
    desc = "neovia: reapply worktree status highlights",
  })
end

--- Lualine component: current worktree status.
--- Returns a table suitable for use as a lualine component function.
--- @return string
function M.lualine_current()
  ensure_highlights()
  M.setup()

  local dir = vim.fn.getcwd()
  local entry = state[dir]
  if not entry then return "" end

  local s = entry.status
  return status_icon[s] or status_icon.idle
end

--- Colour callback for lualine_current.
--- @return table|nil
function M.lualine_current_color()
  local dir = vim.fn.getcwd()
  local entry = state[dir]
  if not entry then return nil end
  return { fg = (status_hl[entry.status] or {}).fg }
end

--- Compute the worst status across all worktrees.
--- Priority: needs_attention > responding > idle.
--- @return string worst  One of "idle", "responding", "needs_attention".
--- @return integer count  Number of tracked worktrees.
local function get_worst_status()
  local worst = "idle"
  local count = 0
  for _, entry in pairs(state) do
    count = count + 1
    if entry.status == "needs_attention" then
      worst = "needs_attention"
    elseif entry.status == "responding" and worst ~= "needs_attention" then
      worst = "responding"
    end
  end
  return worst, count
end

--- Lualine component: aggregate status across all worktrees.
--- @return string
function M.lualine_aggregate()
  ensure_highlights()
  M.setup()

  local worst, count = get_worst_status()

  -- Don't show anything if there's only one worktree or all idle
  if count <= 1 or worst == "idle" then return "" end

  if worst == "needs_attention" then
    return "[wt: needs you]"
  elseif worst == "responding" then
    return "[wt: working]"
  end

  return ""
end

--- Colour callback for lualine_aggregate.
--- @return table|nil
function M.lualine_aggregate_color()
  local worst, count = get_worst_status()
  if count <= 1 or worst == "idle" then return nil end
  return { fg = (status_hl[worst] or {}).fg }
end

------------------------------------------------------------------------
-- Tabline
------------------------------------------------------------------------

--- Status indicator characters for tabline.
--- @type table<string, string>
local status_char = {
  idle = "",
  responding = "~",
  needs_attention = "!",
  unknown = "?",
}

--- Build a tabline string showing branch names and status for each tab.
--- Uses tab_map for tracked tabs, falls back to directory basename.
--- Status is shown on all tabs via colored indicator characters.
--- @return string
function M.tabline()
  ensure_highlights()
  local parts = {} --- @type string[]
  local current_tab = vim.api.nvim_get_current_tabpage()

  for i, tp in ipairs(vim.api.nvim_list_tabpages()) do
    local is_current = (tp == current_tab)
    local hl = is_current and "%#TabLineSel#" or "%#TabLine#"

    -- Get branch name from tab_map, or fall back to directory basename
    local label
    local dir = tab_map[tp]
    if dir then
      local entry = state[dir]
      if entry and entry.branch and entry.branch ~= "" then
        label = entry.branch
      else
        label = vim.fn.fnamemodify(dir, ":t")
      end
    else
      local tab_cwd = vim.fn.getcwd(-1, i)
      label = vim.fn.fnamemodify(tab_cwd, ":t")
    end

    -- Status indicator with highlight color on all tabs
    local indicator = ""
    if dir and state[dir] then
      local s = state[dir].status
      local ch = status_char[s] or ""
      if ch ~= "" then
        local hl_name = "NeoviaWt_" .. s
        indicator = " %#" .. hl_name .. "#" .. ch .. hl
      end
    end

    table.insert(parts, hl .. " " .. label .. indicator .. " ")
  end

  table.insert(parts, "%#TabLineFill#")
  return table.concat(parts)
end

------------------------------------------------------------------------
-- Test internals (exposed for unit tests only)
------------------------------------------------------------------------

--- @class neovia.WorktreeInternals
M._internal = {
  parse_worktree_porcelain = parse_worktree_porcelain,
  apply_event = apply_event,
  derive_worktree_path = derive_worktree_path,
  parse_create_result = parse_create_result,
  parse_delete_result = parse_delete_result,
  parse_branch_delete_result = parse_branch_delete_result,
  delete_branch = delete_branch,
  register_tab = register_tab,
  get_tab_dir = get_tab_dir,
  find_tab_for_dir = find_tab_for_dir,
  unregister_tab = unregister_tab,
  open_in_new_tab = open_in_new_tab,
  get_worst_status = get_worst_status,
  status_icon = status_icon,
  status_hl = status_hl,

  --- Get the raw state table (for assertions).
  --- @return table<string, neovia.WorktreeState>
  get_state = function() return state end,

  --- Replace the state table (for test setup).
  --- @param new_state table<string, neovia.WorktreeState>
  set_state = function(new_state) state = new_state end,

  --- Reset module to uninitialised state (for test isolation).
  reset = function()
    unsubscribe_all()
    state = {}
    tab_map = {}
    initialised = false
    hl_initialised = false
    git_common_dir = nil
    if dir_timer then
      dir_timer:stop()
      dir_timer:close()
      dir_timer = nil
    end
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_worktree")
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_worktree_hl")
    vim.o.showtabline = 1  -- restore default
    vim.o.tabline = ""
  end,

  --- Create a fresh WorktreeState entry.
  --- @param overrides? table
  --- @return neovia.WorktreeState
  make_entry = function(overrides)
    return vim.tbl_extend("force", {
      status = "unknown",
      branch = "main",
      pending_permissions = {},
    }, overrides or {})
  end,
}

return M
