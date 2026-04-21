-- neovia worktree module
-- Worktree lifecycle (create/switch/close/delete), status tracking via SSE,
-- tabline rendering, and picker.

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
--- @field buffer_paths string[]  saved file paths (for switch restore)
--- @field open boolean  whether this worktree is actively tracked (vs closed)

--- Per-directory state. Keyed by absolute path.
--- @type table<string, neovia.WorktreeState>
local state = {}

--- Whether setup() has been called.
local initialised = false

--- Timer handle for DirChanged debounce (nil = no pending call).
--- @type uv_timer_t|nil
local dir_timer = nil

--- Whether we've confirmed we're inside a git repo.
local in_git_repo = false

-- Forward declarations
local ensure_subscriptions, list_worktrees, unsubscribe_all, start_spinner, ensure_highlights

------------------------------------------------------------------------
-- Buffer helpers
------------------------------------------------------------------------

--- Collect file paths of all listed, normal file buffers.
--- @return string[]
local function collect_file_buffers()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
    then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        table.insert(paths, name)
      end
    end
  end
  return paths
end

--- Unlist all listed file buffers (buftype="" and buflisted).
local function unlist_file_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
    then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        vim.bo[buf].buflisted = false
      end
    end
  end
end

--- Re-list buffers by path. If a buffer for the path already exists
--- (unlisted), re-list it. Otherwise create a new buffer.
--- @param paths string[]
--- @return integer[] bufs  Buffer handles of restored buffers.
local function relist_buffers(paths)
  local bufs = {}
  for _, path in ipairs(paths) do
    -- Check if a buffer with this name already exists
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
      vim.bo[existing].buflisted = true
      table.insert(bufs, existing)
    else
      -- Create a new buffer for this path
      local buf = vim.fn.bufadd(path)
      vim.bo[buf].buflisted = true
      table.insert(bufs, buf)
    end
  end
  return bufs
end

--- Wipeout all unlisted buffers matching saved paths for a directory.
--- Also clears buffer_paths from state.
--- @param dir string
local function wipeout_buffers_for_dir(dir)
  local entry = state[dir]
  if not entry then return end

  for _, path in ipairs(entry.buffer_paths) do
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  entry.buffer_paths = {}
end

------------------------------------------------------------------------
-- Git helpers
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

--- Derive the worktree directory path for a new branch.
--- Convention:
---   - If all linked worktrees are siblings of the main worktree → sibling.
---   - Otherwise (or no linked worktrees) → <main>/.worktrees/<branch>.
--- Branch slashes are replaced with dashes.
--- @param worktrees neovia.WorktreeEntry[]  Output of list_worktrees()
--- @param branch string  The new branch name
--- @return string path  Absolute path for the new worktree
local function derive_worktree_path(worktrees, branch)
  local safe_branch = branch:gsub("/", "-")

  -- Find the main worktree (first non-bare entry)
  local main_path = nil
  for _, wt in ipairs(worktrees) do
    if not wt.bare then
      main_path = wt.path
      break
    end
  end
  if not main_path then return ".worktrees/" .. safe_branch end

  -- Normalise: strip trailing slash
  main_path = main_path:gsub("/$", "")

  -- Collect linked worktrees (all non-bare entries after the first)
  local linked = {}
  for i = 2, #worktrees do
    if not worktrees[i].bare then
      table.insert(linked, worktrees[i].path)
    end
  end

  -- If no linked worktrees, default to .worktrees/
  if #linked == 0 then
    return main_path .. "/.worktrees/" .. safe_branch
  end

  -- Check if all linked worktrees are siblings (same parent dir as main)
  local main_parent = vim.fn.fnamemodify(main_path, ":h")
  local all_siblings = true
  for _, p in ipairs(linked) do
    local parent = vim.fn.fnamemodify(p, ":h")
    if parent ~= main_parent then
      all_siblings = false
      break
    end
  end

  if all_siblings then
    return main_parent .. "/" .. safe_branch
  end

  -- Mixed or nested: fall back to .worktrees/
  return main_path .. "/.worktrees/" .. safe_branch
end

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
    vim.cmd.redrawtabline()
    -- Start spinner if any worktree just entered responding
    if entry.status == "responding" then
      start_spinner()
    end
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
        buffer_paths = {},
        open = true,
      }
    else
      -- Update branch in case it changed
      state[wt.path].branch = wt.branch
    end

    -- Subscribe if open and not already subscribed (or if subscription died)
    local entry = state[wt.path]
    if entry.open then
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
  end

  -- Remove state for worktrees that no longer exist on disk
  -- (but keep closed worktrees -- they are intentionally retained)
  for dir, entry in pairs(state) do
    if not valid[dir] and entry.open then
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

  if not resolve_git_common_dir() then return end
  in_git_repo = true

  -- Set up tabline and highlights
  ensure_highlights()
  _G.neovia_tabline = function()
    return render_tabline(build_tabline_entries())
  end
  vim.o.showtabline = 2 -- always show
  vim.o.tabline = "%!v:lua.neovia_tabline()"

  local group = vim.api.nvim_create_augroup("neovia_worktree", { clear = true })

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
        vim.cmd.redrawtabline()
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
  vim.cmd.redrawtabline()
  if new_status == "responding" then
    start_spinner()
  end
end

------------------------------------------------------------------------
-- Public API: worktree lifecycle
------------------------------------------------------------------------

--- Switch to a worktree directory.
--- Saves current file buffer paths (unlist), tcd to target,
--- restores saved buffers (relist) or opens netrw on first visit.
--- If the target is closed, reopens it (re-subscribes SSE).
--- @param dir string  Absolute path to the target worktree.
function M.switch_to(dir)
  M.setup()

  local cwd = vim.fn.getcwd()
  if cwd == dir then return end

  -- Save current buffers
  local current_entry = state[cwd]
  if current_entry then
    current_entry.buffer_paths = collect_file_buffers()
  end

  -- Unlist current file buffers
  unlist_file_buffers()

  -- tcd to target
  vim.cmd.tcd(dir)

  -- Ensure target has a state entry
  if not state[dir] then
    state[dir] = {
      status = "unknown",
      branch = "",
      pending_permissions = {},
      buffer_paths = {},
      open = true,
    }
  end

  local target = state[dir]

  -- Reopen if closed
  if not target.open then
    target.open = true
    subscribe_one(dir)
  end

  -- Restore saved buffers or open netrw
  if #target.buffer_paths > 0 then
    local bufs = relist_buffers(target.buffer_paths)
    -- Open the first restored buffer in the code window
    if #bufs > 0 then
      local navigate = require("neovia.navigate")
      local win = navigate.find_code_win()
      if win then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_buf(win, bufs[1])
      end
    end
  else
    -- First visit: open netrw in the code window
    local navigate = require("neovia.navigate")
    navigate.open_dir(dir)
  end

  vim.notify("Switched to " .. dir, vim.log.levels.INFO)
end

--- Close a worktree: wipeout its buffers, tear down SSE, mark closed.
--- The git worktree stays on disk. Sessions are untouched.
--- @param dir string  Absolute path to the worktree.
function M.close(dir)
  M.setup()

  local entry = state[dir]
  if not entry then return end

  -- If this is the current worktree, switch to main first
  local cwd = vim.fn.getcwd()
  if cwd == dir then
    local worktrees = list_worktrees()
    local main_path = nil
    for _, wt in ipairs(worktrees) do
      if wt.path ~= dir and not wt.bare then
        main_path = wt.path
        break
      end
    end
    if main_path then
      M.switch_to(main_path)
    else
      vim.notify("Cannot close the only worktree", vim.log.levels.WARN)
      return
    end
  end

  -- Wipeout saved buffers
  wipeout_buffers_for_dir(dir)

  -- Tear down SSE subscription
  if entry.subscription and type(entry.subscription.shutdown) == "function" then
    pcall(entry.subscription.shutdown)
  end
  entry.subscription = nil

  -- Mark closed
  entry.open = false
  entry.status = "unknown"

  vim.notify("Closed worktree " .. (entry.branch ~= "" and entry.branch or dir), vim.log.levels.INFO)
end

------------------------------------------------------------------------
-- Public API: worktree create / delete
------------------------------------------------------------------------

--- Create a new worktree.
--- @param opts? { fork?: boolean }
function M.create(opts)
  M.setup()
  opts = opts or {}

  -- Step 1: prompt for branch name
  vim.ui.input({ prompt = "New branch name: " }, function(branch)
    if not branch or branch == "" then return end

    -- Step 2: ask fork-or-fresh (before git add, so user can cancel)
    local do_fork = false
    if opts.fork ~= nil then
      do_fork = opts.fork
      M._create_continue(branch, do_fork)
    else
      vim.ui.select({ "Fork current session", "Fresh session" }, {
        prompt = "Session for new worktree:",
      }, function(choice)
        if not choice then return end
        do_fork = choice == "Fork current session"
        M._create_continue(branch, do_fork)
      end)
    end
  end)
end

--- Internal: continue worktree creation after prompts.
--- @param branch string
--- @param do_fork boolean
function M._create_continue(branch, do_fork)
  local worktrees = list_worktrees()
  local path = derive_worktree_path(worktrees, branch)

  -- Step 3: git worktree add
  local result = vim.system(
    { "git", "worktree", "add", "-b", branch, path },
    { text = true }
  ):wait()

  if result.code ~= 0 then
    vim.notify("Failed to create worktree: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  -- Step 4: fork session if requested
  if do_fork then
    local oc_state = package.loaded["opencode.state"]
    if oc_state and oc_state.api_client and oc_state.active_session then
      local session_id = oc_state.active_session.id
      local msg_id = oc_state.last_user_message
        and oc_state.last_user_message.info
        and oc_state.last_user_message.info.id
      oc_state.api_client
        :fork_session(session_id, msg_id and { messageID = msg_id } or nil, path)
        :and_then(function(response)
          vim.schedule(function()
            if response and response.id then
              vim.notify("Session forked for " .. branch, vim.log.levels.INFO)
            end
          end)
        end)
        :catch(function(err)
          vim.schedule(function()
            vim.notify("Session fork failed: " .. vim.inspect(err), vim.log.levels.WARN)
          end)
        end)
    end
  end

  -- Step 5: switch to the new worktree
  M.switch_to(path)
end

--- Delete a worktree.
--- Shows a picker to select which worktree to delete.
function M.delete()
  M.setup()

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("worktree.delete: fzf-lua not available", vim.log.levels.ERROR)
    return
  end
  local worktrees = list_worktrees()
  local cwd = vim.fn.getcwd()

  -- Filter out the main worktree (first entry) and current
  local candidates = {}
  local line_to_wt = {}
  for i, wt in ipairs(worktrees) do
    if i > 1 and not wt.bare then -- skip main worktree
      local marker = wt.path == cwd and " (current)" or ""
      local display_path = wt.path:gsub("^" .. vim.pesc(vim.env.HOME), "~")
      local line = string.format("%s  %s%s", wt.branch, display_path, marker)
      table.insert(candidates, line)
      line_to_wt[line] = wt
    end
  end

  if #candidates == 0 then
    vim.notify("No linked worktrees to delete", vim.log.levels.WARN)
    return
  end

  fzf.fzf_exec(candidates, {
    prompt = "Delete worktree> ",
    fzf_opts = { ["--no-multi"] = "" },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local wt = line_to_wt[selected[1]]
        if not wt then return end

        vim.ui.select({ "Yes", "No" }, {
          prompt = string.format("Delete worktree '%s' at %s?", wt.branch, wt.path),
        }, function(confirm)
          if confirm ~= "Yes" then return end
          M._delete_continue(wt)
        end)
      end,
    },
  })
end

--- Internal: continue worktree deletion after confirmation.
--- @param wt neovia.WorktreeEntry
function M._delete_continue(wt)
  -- Create tombstone session (emulates /new) so the path is left clean
  local oc_state = package.loaded["opencode.state"]
  if oc_state and oc_state.api_client then
    oc_state.api_client:create_session(false, wt.path)
      :catch(function() end) -- best-effort
  end

  -- Close the worktree (switch away if current, wipeout buffers, tear down SSE)
  local entry = state[wt.path]
  if entry and entry.open then
    M.close(wt.path)
  end

  -- git worktree remove
  local rm_result = vim.system(
    { "git", "worktree", "remove", wt.path },
    { text = true }
  ):wait()

  if rm_result.code ~= 0 then
    vim.notify("Failed to remove worktree: " .. (rm_result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  -- git branch -d (safe delete)
  if wt.branch ~= "" and wt.branch ~= "(detached)" then
    local br_result = vim.system(
      { "git", "branch", "-d", wt.branch },
      { text = true }
    ):wait()

    if br_result.code ~= 0 then
      -- Branch not fully merged -- ask about force delete
      vim.ui.select({ "Force delete (-D)", "Keep branch" }, {
        prompt = string.format("Branch '%s' is not fully merged:", wt.branch),
      }, function(choice)
        if choice == "Force delete (-D)" then
          local force = vim.system(
            { "git", "branch", "-D", wt.branch },
            { text = true }
          ):wait()
          if force.code ~= 0 then
            vim.notify("Failed to delete branch: " .. (force.stderr or ""), vim.log.levels.ERROR)
          else
            vim.notify("Branch '" .. wt.branch .. "' force-deleted", vim.log.levels.INFO)
          end
        end
      end)
    end
  end

  -- Clean up state
  state[wt.path] = nil

  -- Refresh subscriptions
  ensure_subscriptions()

  vim.notify("Deleted worktree " .. wt.branch, vim.log.levels.INFO)
end

------------------------------------------------------------------------
-- Picker
------------------------------------------------------------------------

--- Open the worktree picker.
--- Shows all worktrees (open and closed). Closed worktrees are dimmed.
--- Selecting a worktree switches to it (reopening if closed).
function M.pick()
  M.setup()

  -- Refresh worktree list and subscriptions
  ensure_subscriptions()

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("worktree.pick: fzf-lua not available", vim.log.levels.ERROR)
    return
  end
  local worktrees = list_worktrees()

  if #worktrees == 0 then
    vim.notify("No git worktrees found", vim.log.levels.WARN)
    return
  end

  local cwd = vim.fn.getcwd()
  local dim = "\27[90m" -- ANSI dim grey for closed worktrees

  -- Build entries and a lookup from display line to worktree path
  local entries = {} --- @type string[]
  local line_to_path = {} --- @type table<string, string>
  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path] or { status = "unknown", open = true }
    local is_open = entry.open ~= false
    local colour = is_open and (status_ansi[entry.status] or status_ansi.unknown) or dim
    local icon = is_open and (status_icon[entry.status] or "") or "[closed]"
    local marker = wt.path == cwd and " *" or ""

    -- Show path relative to home for readability
    local display_path = wt.path:gsub("^" .. vim.pesc(vim.env.HOME), "~")

    local line = string.format(
      "%s%-20s%s  %s%s%s%s",
      colour, wt.branch, ansi_reset,
      is_open and display_path or (dim .. display_path .. ansi_reset),
      marker,
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
        local target = line_to_path[selected[1]]
        if target then
          M.switch_to(target)
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
  -- Closed worktree: dim/comment colour
  vim.api.nvim_set_hl(0, "NeoviaWtClosed", { fg = "#565f89", italic = true })
end

--- Set up highlights lazily, re-apply on colorscheme change.
local hl_initialised = false
ensure_highlights = function()
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

------------------------------------------------------------------------
-- Tabline
------------------------------------------------------------------------

--- Spinner frames for "responding" status.
local spinner_frames = { "|", "/", "-", "\\" }

--- Spinner state: advances each time status_char is called for responding.
local spinner_idx = 0

--- Timer for spinning the tabline spinner.
--- @type uv_timer_t|nil
local spinner_timer = nil

--- Return a single-character status indicator.
--- @param s string  One of "idle", "responding", "needs_attention", "unknown".
--- @return string
local function status_char(s)
  if s == "needs_attention" then return "!" end
  if s == "responding" then
    spinner_idx = (spinner_idx % #spinner_frames) + 1
    return spinner_frames[spinner_idx]
  end
  if s == "unknown" then return "?" end
  return "" -- idle: no indicator
end

--- @class neovia.TablineEntry
--- @field branch string
--- @field status string
--- @field current boolean
--- @field open boolean

--- Render the tabline string from a list of entries (pure).
--- Returns "" if there are 0 or 1 entries (tabline not useful).
--- @param entries neovia.TablineEntry[]
--- @return string
local function render_tabline(entries)
  if #entries <= 1 then return "" end

  local parts = {}
  for _, e in ipairs(entries) do
    local char = status_char(e.status)
    local suffix = char ~= "" and (" " .. char) or ""

    if e.current then
      table.insert(parts, "%#TabLineSel# " .. e.branch .. suffix .. " ")
    elseif not e.open then
      table.insert(parts, "%#NeoviaWtClosed# " .. e.branch .. suffix .. " ")
    else
      -- Use status-coloured highlight for the indicator character
      local hl = "TabLine"
      if e.status == "needs_attention" then
        hl = "NeoviaWt_needs_attention"
      elseif e.status == "responding" then
        hl = "NeoviaWt_responding"
      end
      if char ~= "" then
        table.insert(parts, "%#TabLine# " .. e.branch .. " %#" .. hl .. "#" .. char .. " ")
      else
        table.insert(parts, "%#TabLine# " .. e.branch .. " ")
      end
    end
  end

  return table.concat(parts) .. "%#TabLineFill#"
end

--- Build tabline entries from current state + worktree list.
--- @return neovia.TablineEntry[]
local function build_tabline_entries()
  local worktrees = list_worktrees()
  local cwd = vim.fn.getcwd()
  local entries = {} --- @type neovia.TablineEntry[]

  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path]
    table.insert(entries, {
      branch = wt.branch,
      status = entry and entry.status or "unknown",
      current = wt.path == cwd,
      open = entry and entry.open ~= false or true,
    })
  end

  return entries
end

-- _G.neovia_tabline is set in setup() so it survives reload.

--- Start the spinner timer (redraws tabline periodically when any worktree is responding).
start_spinner = function()
  if spinner_timer then return end
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(200, 200, vim.schedule_wrap(function()
    -- Check if any worktree is still responding
    local any_responding = false
    for _, entry in pairs(state) do
      if entry.status == "responding" then
        any_responding = true
        break
      end
    end
    if any_responding then
      vim.cmd.redrawtabline()
    else
      -- Stop spinner when nothing is responding
      if spinner_timer then
        spinner_timer:stop()
        spinner_timer:close()
        spinner_timer = nil
      end
      vim.cmd.redrawtabline()
    end
  end))
end

------------------------------------------------------------------------
-- Test internals (exposed for unit tests only)
------------------------------------------------------------------------

--- @class neovia.WorktreeInternals
M._internal = {
  parse_worktree_porcelain = parse_worktree_porcelain,
  apply_event = apply_event,
  derive_worktree_path = derive_worktree_path,
  collect_file_buffers = collect_file_buffers,
  unlist_file_buffers = unlist_file_buffers,
  relist_buffers = relist_buffers,
  wipeout_buffers_for_dir = wipeout_buffers_for_dir,
  status_char = status_char,
  render_tabline = render_tabline,
  build_tabline_entries = build_tabline_entries,
  status_icon = status_icon,
  status_hl = status_hl,
  process_event = process_event,
  subscribe_one = subscribe_one,
  ensure_subscriptions = ensure_subscriptions,
  unsubscribe_all = unsubscribe_all,
  start_spinner = start_spinner,
  resolve_git_common_dir = resolve_git_common_dir,
  list_worktrees = list_worktrees,

  --- Get the raw state table (for assertions).
  --- @return table<string, neovia.WorktreeState>
  get_state = function() return state end,

  --- Replace the state table (for test setup).
  --- @param new_state table<string, neovia.WorktreeState>
  set_state = function(new_state) state = new_state end,

  --- Mark the module as initialised (for tests that bypass setup).
  set_initialised = function(val) initialised = val end,

  --- Reset module to uninitialised state (for test isolation).
  reset = function()
    unsubscribe_all()
    state = {}
    initialised = false
    hl_initialised = false
    in_git_repo = false
    if dir_timer then
      dir_timer:stop()
      dir_timer:close()
      dir_timer = nil
    end
    if spinner_timer then
      spinner_timer:stop()
      spinner_timer:close()
      spinner_timer = nil
    end
    spinner_idx = 0
    _G.neovia_tabline = nil
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_worktree")
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_worktree_hl")
  end,

  --- Create a fresh WorktreeState entry.
  --- @param overrides? table
  --- @return neovia.WorktreeState
  make_entry = function(overrides)
    return vim.tbl_extend("force", {
      status = "unknown",
      branch = "main",
      pending_permissions = {},
      buffer_paths = {},
      open = true,
    }, overrides or {})
  end,
}

return M
