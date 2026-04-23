-- neovia worktree module
-- Worktree lifecycle (create/switch/close/delete), status tracking via SSE,
-- and picker. Rendering lives in lua/plugins/ui.lua (decision 0009).

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
--- @field session_id string|nil  cached opencode session ID (used by resync and fork)

--- Per-directory state. Keyed by absolute path.
--- @type table<string, neovia.WorktreeState>
local state = {}

--- Whether setup() has been called.
local initialised = false

--- Timer handle for DirChanged debounce (nil = no pending call).
--- @type uv_timer_t|nil
local dir_timer = nil

-- Forward declarations
local ensure_subscriptions, list_worktrees, unsubscribe_all, build_picker_entries
local build_close_candidates, find_current_worktree, prompt_branch

------------------------------------------------------------------------
-- Directory helpers
------------------------------------------------------------------------

--- Return the tab-level working directory (set by tcd), ignoring any
--- window-local lcd overrides.  This is the authoritative "which worktree
--- are we in?" answer, because tcd is the switching mechanism.
--- @return string
local function tab_cwd()
  return vim.fn.getcwd(-1, 0)
end

------------------------------------------------------------------------
-- Buffer helpers
------------------------------------------------------------------------

--- Collect file paths of all listed, normal file buffers.
--- Excludes scratch buffers (they are managed separately).
--- @return string[]
local function collect_file_buffers()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
      and not vim.b[buf].neovia_scratch
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
        -- Stop treesitter before unlisting to prevent async fold callbacks
        -- from firing on a stale buffer (Neovim _foldupdate race, #35312).
        vim.treesitter.stop(buf)
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
    dir = tab_cwd() .. "/" .. dir
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

--- Build a lualine-compatible color table from the theme's authoritative colours.
--- Uses pcall because the theme module may not be loaded yet during early require.
--- @param status string
--- @return table
local function status_hl_for(status)
  local ok, theme = pcall(require, "neovia.theme")
  if ok and theme.status_colors then
    return { fg = theme.status_colors[status] or theme.status_colors.unknown }
  end
  -- Fallback: neutral dim grey if theme is unavailable
  return { fg = "#565f89" }
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

  elseif t == "permission.asked" or t == "question.asked" then
    entry.status = "needs_attention"
    local id = props.id or props.requestID
    if id then entry.pending_permissions[id] = true end

  elseif t == "permission.replied" or t == "question.replied" or t == "question.rejected" then
    local id = props.permissionID or props.requestID or props.id
    if id then entry.pending_permissions[id] = nil end
    -- If no more pending permissions/questions, revert to responding.
    -- It will settle to idle via session.idle later.
    if vim.tbl_isempty(entry.pending_permissions) then
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
      local t = vim.uv.new_timer()
      dir_timer = t
      t:start(500, 0, vim.schedule_wrap(function()
        if not t:is_closing() then t:close() end
        if dir_timer == t then dir_timer = nil end
        ensure_subscriptions()
        vim.cmd.redrawtabline()
      end))
    end,
    desc = "neovia: refresh worktree subscriptions on tcd",
  })

  -- Defer subscription until opencode server is ready.
  -- Not once=true: the server may restart (external process) and
  -- fire this event again, so we need to re-subscribe each time.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OpencodeEvent:server.connected",
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

  -- Global click handler for worktree tabline entries.
  -- Defined as VimScript so it is callable from %@FuncName@ statusline syntax.
  -- function! is idempotent (overwrites on reload).
  vim.cmd([[
    function! NeoviaWorktreeSwitch(id, clicks, button, modifiers)
      call v:lua.require('neovia.worktree')._internal.handle_tabline_click(a:id)
    endfunction
  ]])
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
end

--- Resync cached session IDs for all open worktrees from the opencode API.
--- Useful when sessions are created or switched outside neovia's control
--- (e.g. via opencode's /session command or the session picker).
function M.resync()
  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state or not oc_state.api_client then
    vim.notify("worktree.resync: opencode not available", vim.log.levels.WARN)
    return
  end

  -- Save the current worktree's active session immediately
  local cwd = tab_cwd()
  if state[cwd] and oc_state.active_session and oc_state.active_session.id then
    state[cwd].session_id = oc_state.active_session.id
  end

  -- Query the API for each other open worktree
  for dir, entry in pairs(state) do
    if entry.open and dir ~= cwd then
      oc_state.api_client
        :list_sessions(dir)
        :and_then(function(sessions)
          vim.schedule(function()
            if not sessions or type(sessions) ~= "table" or #sessions == 0 then
              return
            end
            -- Pick the most recently updated non-child session
            table.sort(sessions, function(a, b)
              return a.time.updated > b.time.updated
            end)
            for _, s in ipairs(sessions) do
              if s.parentID == nil then
                entry.session_id = s.id
                return
              end
            end
            -- Fall back to any session
            entry.session_id = sessions[1].id
          end)
        end)
        :catch(function() end) -- silently ignore per-worktree failures
    end
  end

  vim.notify("Worktree sessions resynced", vim.log.levels.INFO)
end

------------------------------------------------------------------------
-- Public API: worktree lifecycle
------------------------------------------------------------------------

--- Save the active opencode session ID into state for the given directory.
--- @param dir string
local function save_session_id(dir)
  local entry = state[dir]
  if not entry then return end
  local ok, oc_state = pcall(require, "opencode.state")
  if ok and oc_state.active_session and oc_state.active_session.id then
    entry.session_id = oc_state.active_session.id
  end
end

--- Switch to a worktree directory.
--- Saves current file buffer paths (unlist), tcd to target,
--- restores saved buffers (relist) or opens scratch on first visit.
--- If the target is closed, reopens it (re-subscribes SSE).
--- Session switching is left to opencode.nvim's DirChanged autocmd
--- (fires synchronously during tcd) so that SSE reconnection and
--- session loading happen atomically.
--- Tells neo-tree the new root directory.
--- @param dir string  Absolute path to the target worktree.
function M.switch_to(dir)
  M.setup()

  local cwd = tab_cwd()
  if cwd == dir then return end

  -- Save current buffers and session ID
  local current_entry = state[cwd]
  if current_entry then
    current_entry.buffer_paths = collect_file_buffers()
    save_session_id(cwd)
  end

  -- Unlist current file buffers
  unlist_file_buffers()

  -- tcd to target.  opencode.nvim's DirChanged autocmd fires
  -- synchronously here, calling set_current_cwd and
  -- handle_directory_change.  We do NOT pre-set current_cwd
  -- ourselves because that would trigger the event manager's SSE
  -- reconnection before the session switch, creating a gap where
  -- streaming events are lost.
  vim.cmd.tcd(dir)

  -- Ensure target has a state entry
  if not state[dir] then
    state[dir] = {
      status = "unknown",
      branch = "",
      pending_permissions = {},
      buffer_paths = {},
      open = true,
      session_id = nil,
    }
  end

  local target = state[dir]

  -- Reopen if closed
  if not target.open then
    target.open = true
    subscribe_one(dir)
  end

  -- Restore saved buffers or open scratch
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if ok_nav then
    if #target.buffer_paths > 0 then
      local bufs = relist_buffers(target.buffer_paths)
      -- Open the first restored buffer in the code window
      if #bufs > 0 then
        local win = navigate.find_code_win()
        if win then
          vim.api.nvim_set_current_win(win)
          vim.api.nvim_win_set_buf(win, bufs[1])
        end
      end
    else
      -- First visit: open scratch in the code window
      navigate.open_scratch_in_code_win(dir)
    end
  end

  -- Tell neo-tree the new root (bind_to_cwd is off, so we do it explicitly)
  pcall(vim.cmd, "Neotree dir=" .. vim.fn.fnameescape(dir))

  -- Immediate tabline update so the current-worktree highlight is visible
  -- without waiting for the debounced DirChanged handler.
  vim.cmd.redrawtabline()

  -- Deferred layout check: opencode.nvim's session swap is async, so if
  -- it disrupts the output window, ensure_layout repairs it.
  -- Also re-subscribe the event manager's SSE so the server re-emits
  -- pending permission state.  renderer.reset() clears permissions
  -- before render_full_session runs, so permissions delivered on the
  -- first SSE connection are lost.  The deferred re-subscribe ensures
  -- they arrive after the session switch has settled.
  vim.defer_fn(function()
    local ok, layout = pcall(require, "neovia.layout")
    if ok and layout._internal and layout._internal.ensure_layout then
      layout._internal.ensure_layout()
    end

    local ok_oc, oc_state = pcall(require, "opencode.state")
    if ok_oc and oc_state.event_manager
      and oc_state.event_manager._subscribe_to_server_events
      and oc_state.opencode_server then
      oc_state.event_manager:_subscribe_to_server_events(oc_state.opencode_server)
    end
  end, 100)

  vim.notify("Switched to " .. dir, vim.log.levels.INFO)
end

--- Close a worktree: wipeout its buffers, tear down SSE, mark closed.
--- The git worktree stays on disk. Sessions are untouched.
--- @param dir? string  Absolute path to the worktree (defaults to tab-level cwd).
function M.close(dir)
  M.setup()
  dir = dir or tab_cwd()

  local entry = state[dir]
  if not entry then return end

  -- If this is the current worktree, switch to main first
  local cwd = tab_cwd()
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

  -- Save and wipe scratch buffer
  local ok_scratch, scratch = pcall(require, "neovia.scratch")
  if ok_scratch then
    scratch.save(dir)
    scratch.wipe(dir)
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

  -- Deferred redraw: switch_to (called above when closing the current worktree)
  -- triggers a debounced DirChanged that redraws the tabline before our state
  -- mutation is visible. Schedule the redraw so it runs after pending events.
  vim.schedule(function()
    vim.cmd.redrawstatus()
    vim.cmd.redrawtabline()
  end)

  vim.notify("Closed worktree " .. (entry.branch ~= "" and entry.branch or dir), vim.log.levels.INFO)
end

------------------------------------------------------------------------
-- Public API: worktree create / delete
------------------------------------------------------------------------

--- Create a new worktree from the current HEAD.
--- @param opts? { fork?: boolean }
function M.create(opts)
  M.setup()
  opts = opts or {}
  local do_fork = opts.fork or false

  prompt_branch(function(branch)
    M._create_continue(branch, do_fork)
  end)
end

--- Create a new worktree from a picked source worktree.
--- Shows an fzf picker to select the source, then prompts for a branch name.
--- @param opts? { fork?: boolean }
function M.create_from(opts)
  M.setup()
  opts = opts or {}
  local do_fork = opts.fork or false

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("worktree.create_from: fzf-lua not available", vim.log.levels.ERROR)
    return
  end

  local worktrees = list_worktrees()
  if #worktrees == 0 then
    vim.notify("No git worktrees found", vim.log.levels.WARN)
    return
  end

  local cwd = tab_cwd()
  local entries, paths = build_picker_entries(worktrees, cwd)

  fzf.fzf_exec(entries, {
    prompt = "Source worktree> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--no-multi"] = "",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        -- Resolve path from selection
        local source_path = nil
        local source_branch = nil
        for i, e in ipairs(entries) do
          local stripped = e:gsub("\27%[[%d;]*m", "")
          if stripped == selected[1] then
            source_path = paths[i]
            break
          end
        end
        if not source_path then return end

        -- Find the branch name for the source
        for _, w in ipairs(worktrees) do
          if w.path == source_path then
            source_branch = w.branch
            break
          end
        end

        -- Defer so fzf-lua's window teardown completes before dressing opens.
        -- A short delay is needed because vim.schedule alone can fire before
        -- fzf-lua finishes restoring focus, which prevents dressing from
        -- gaining focus and entering insert mode.
        vim.defer_fn(function()
          prompt_branch(function(branch)
            M._create_continue(branch, do_fork, source_branch, source_path)
          end)
        end, 50)
      end,
    },
  })
end

--- Internal: continue worktree creation after prompts.
--- @param branch string
--- @param do_fork boolean
--- @param start_point? string  Git ref to base the new branch on (default: HEAD).
--- @param source_path? string  Absolute path to the source worktree (for fork-from).
function M._create_continue(branch, do_fork, start_point, source_path)
  local worktrees = list_worktrees()
  local path = derive_worktree_path(worktrees, branch)

  -- Step 3: git worktree add
  local cmd = { "git", "worktree", "add", "-b", branch, path }
  if start_point then
    table.insert(cmd, start_point)
  end
  local result = vim.system(cmd, { text = true }):wait()

  if result.code ~= 0 then
    vim.notify("Failed to create worktree: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  -- Step 4: fork session if requested, then switch.
  -- When forking, switch must wait for the fork to complete so the new
  -- worktree's opencode session exists before DirChanged fires.
  if do_fork then
    local oc_state = package.loaded["opencode.state"]
    if oc_state and oc_state.api_client then
      -- Resolve which session to fork:
      -- - wf (no source_path): fork the current active session
      -- - wF (source_path): find the source worktree's session via API
      local function do_fork_session(session_id)
        local fork_data = vim.empty_dict()
        oc_state.api_client
          :fork_session(session_id, fork_data, path)
          :and_then(function(response)
            vim.schedule(function()
              if response and response.id then
                -- Pre-set opencode's current_cwd so the DirChanged autocmd
                -- (fired by tcd inside switch_to) short-circuits and does
                -- not race with switch_session.
                if oc_state.context and oc_state.context.set_current_cwd then
                  oc_state.context.set_current_cwd(path)
                end
                M.switch_to(path)
                vim.notify("Session forked for " .. branch, vim.log.levels.INFO)
                local ok_core, core = pcall(require, "opencode.core")
                if ok_core and core.switch_session then
                  core.switch_session(response.id)
                end
              else
                M.switch_to(path)
              end
            end)
          end)
          :catch(function(err)
            vim.schedule(function()
              vim.notify("Session fork failed: " .. vim.inspect(err), vim.log.levels.WARN)
              M.switch_to(path)
            end)
          end)
      end

      if source_path then
        -- Fork-from: look up the most recent session for the source worktree
        oc_state.api_client
          :list_sessions(source_path)
          :and_then(function(sessions)
            vim.schedule(function()
              if not sessions or type(sessions) ~= "table" or #sessions == 0 then
                vim.notify("No session found for source worktree", vim.log.levels.WARN)
                M.switch_to(path)
                return
              end
              -- Sort by updated time descending, pick the most recent parent session
              table.sort(sessions, function(a, b)
                return a.time.updated > b.time.updated
              end)
              local target = nil
              for _, s in ipairs(sessions) do
                if s.parentID == nil then
                  target = s
                  break
                end
              end
              -- Fall back to any session if no parent sessions exist
              target = target or sessions[1]
              do_fork_session(target.id)
            end)
          end)
          :catch(function(err)
            vim.schedule(function()
              vim.notify("Failed to find source session: " .. vim.inspect(err), vim.log.levels.WARN)
              M.switch_to(path)
            end)
          end)
      elseif oc_state.active_session then
        -- Fork current: use the active session directly
        do_fork_session(oc_state.active_session.id)
      else
        M.switch_to(path)
      end
      return
    end
  end

  -- Step 5: switch to the new worktree (no fork, or opencode unavailable)
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
  local cwd = tab_cwd()

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

  -- git worktree remove (try clean first, then force)
  local rm_result = vim.system(
    { "git", "worktree", "remove", wt.path },
    { text = true }
  ):wait()

  if rm_result.code ~= 0 then
    local force_result = vim.system(
      { "git", "worktree", "remove", "--force", wt.path },
      { text = true }
    ):wait()
    if force_result.code ~= 0 then
      vim.notify("Failed to remove worktree: " .. (force_result.stderr or ""), vim.log.levels.ERROR)
      return
    end
  end

  -- git branch -d (safe delete)
  -- Run from the current tab cwd (which close() switched to main) so git
  -- can find the repository. The deleted worktree directory no longer exists.
  if wt.branch ~= "" and wt.branch ~= "(detached)" then
    local git_cwd = tab_cwd()
    local br_result = vim.system(
      { "git", "branch", "-d", wt.branch },
      { text = true, cwd = git_cwd }
    ):wait()

    if br_result.code ~= 0 then
      -- Branch not fully merged -- ask about force delete
      vim.ui.select({ "Force delete (-D)", "Keep branch" }, {
        prompt = string.format("Branch '%s' is not fully merged:", wt.branch),
      }, function(choice)
        if choice == "Force delete (-D)" then
          vim.system(
            { "git", "branch", "-D", wt.branch },
            { text = true, cwd = git_cwd },
            function(force)
              vim.schedule(function()
                if force.code ~= 0 then
                  vim.notify("Failed to delete branch: " .. (force.stderr or ""), vim.log.levels.ERROR)
                else
                  vim.notify("Branch '" .. wt.branch .. "' force-deleted", vim.log.levels.INFO)
                end
              end)
            end
          )
        end
      end)
    end
  end

  -- Delete scratch storage (worktree is gone, notes lose context)
  local ok_scratch, scratch = pcall(require, "neovia.scratch")
  if ok_scratch then
    scratch.delete_storage(wt.path)
  end

  -- Clean up state
  state[wt.path] = nil

  -- Refresh subscriptions
  ensure_subscriptions()

  vim.notify("Deleted worktree " .. wt.branch, vim.log.levels.INFO)
end

--- Close a worktree via fzf picker.
--- Shows open, non-main worktrees. Selecting one calls M.close(path).
function M.close_picker()
  M.setup()

  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    vim.notify("worktree.close_picker: fzf-lua not available", vim.log.levels.ERROR)
    return
  end

  local worktrees = list_worktrees()
  local cwd = tab_cwd()
  local candidates, line_to_wt = build_close_candidates(worktrees, cwd)

  if #candidates == 0 then
    vim.notify("No open worktrees to close", vim.log.levels.WARN)
    return
  end

  fzf.fzf_exec(candidates, {
    prompt = "Close worktree> ",
    fzf_opts = { ["--no-multi"] = "" },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local wt = line_to_wt[selected[1]]
        if wt then
          M.close(wt.path)
        end
      end,
    },
  })
end

--- Delete the current worktree directly (with confirmation).
--- Warns if on the main worktree. Shows vim.ui.select confirmation.
function M.delete_current()
  M.setup()

  local worktrees = list_worktrees()
  local cwd = tab_cwd()
  local current, idx = find_current_worktree(worktrees, cwd)

  if not current then
    vim.notify("Current directory is not a known worktree", vim.log.levels.WARN)
    return
  end

  if idx == 1 then
    vim.notify("Cannot delete the main worktree", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Delete worktree '%s' at %s?", current.branch, current.path),
  }, function(confirm)
    if confirm ~= "Yes" then return end
    M._delete_continue(current)
  end)
end

------------------------------------------------------------------------
-- Public API: worktree navigation (next / prev / next_attention)
------------------------------------------------------------------------

--- Collect open worktree paths in order, returning the list and the
--- 1-based index of the current worktree within it.
--- @return string[] open_paths
--- @return integer? current_idx  nil if cwd is not in the list.
local function open_worktree_list()
  local worktrees = list_worktrees()
  local cwd = tab_cwd()
  local open_paths = {}
  local current_idx = nil
  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path]
    if not entry or entry.open ~= false then
      table.insert(open_paths, wt.path)
      if wt.path == cwd then current_idx = #open_paths end
    end
  end
  return open_paths, current_idx
end

--- Switch to the next open worktree (wraps around).
function M.next()
  M.setup()
  local paths, idx = open_worktree_list()
  if not idx or #paths <= 1 then return end
  local next_idx = (idx % #paths) + 1
  M.switch_to(paths[next_idx])
end

--- Switch to the previous open worktree (wraps around).
function M.prev()
  M.setup()
  local paths, idx = open_worktree_list()
  if not idx or #paths <= 1 then return end
  local prev_idx = ((idx - 2) % #paths) + 1
  M.switch_to(paths[prev_idx])
end

--- Cycle forward to the next open worktree with needs_attention status.
--- Wraps around. No-op if no worktree needs attention.
function M.next_attention()
  M.setup()
  local worktrees = list_worktrees()
  local cwd = tab_cwd()

  -- Build ordered list of open worktree paths
  local open_paths = {}
  local current_idx = nil
  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path]
    if not entry or entry.open ~= false then
      table.insert(open_paths, wt.path)
      if wt.path == cwd then current_idx = #open_paths end
    end
  end

  if not current_idx or #open_paths == 0 then return end

  -- Search forward from current+1, wrapping around
  for offset = 1, #open_paths - 1 do
    local i = ((current_idx - 1 + offset) % #open_paths) + 1
    local path = open_paths[i]
    local entry = state[path]
    if entry and entry.status == "needs_attention" then
      M.switch_to(path)
      return
    end
  end
end

------------------------------------------------------------------------
-- Picker
------------------------------------------------------------------------

--- Build parallel arrays of display entries and worktree paths for the picker.
--- Entries contain ANSI colour codes for fzf-lua display. Paths are indexed
--- in parallel so lookup works by position (not by string key, since fzf-lua
--- strips ANSI codes from the returned selection).
--- @param worktrees neovia.WorktreeEntry[]
--- @param cwd string  Current working directory (for marking the current entry).
--- @return string[] entries  ANSI-coloured display strings.
--- @return string[] paths    Parallel array of absolute worktree paths.
build_picker_entries = function(worktrees, cwd)
  local dim = status_ansi.unknown -- dim grey for closed worktrees

  local entries = {} --- @type string[]
  local paths = {} --- @type string[]
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
    table.insert(paths, wt.path)
  end

  return entries, paths
end

--- Build candidate list for the close picker.
--- Returns open, non-bare, non-main worktrees as display lines plus a lookup table.
--- @param worktrees neovia.WorktreeEntry[]
--- @param cwd string
--- @return string[] candidates  Display lines for fzf-lua.
--- @return table<string, neovia.WorktreeEntry> line_to_wt  Lookup from line to entry.
build_close_candidates = function(worktrees, cwd)
  local candidates = {}
  local line_to_wt = {}
  for i, wt in ipairs(worktrees) do
    if i > 1 and not wt.bare then -- skip main worktree (first entry)
      local entry = state[wt.path] or { open = true }
      if entry.open ~= false then
        local marker = wt.path == cwd and " (current)" or ""
        local display_path = wt.path:gsub("^" .. vim.pesc(vim.env.HOME), "~")
        local line = string.format("%s  %s%s", wt.branch, display_path, marker)
        table.insert(candidates, line)
        line_to_wt[line] = wt
      end
    end
  end
  return candidates, line_to_wt
end

--- Find the worktree entry matching a given directory.
--- @param worktrees neovia.WorktreeEntry[]
--- @param cwd string
--- @return neovia.WorktreeEntry|nil entry
--- @return integer|nil index  1-based index in the worktree list.
find_current_worktree = function(worktrees, cwd)
  for i, wt in ipairs(worktrees) do
    if wt.path == cwd then
      return wt, i
    end
  end
  return nil, nil
end

--- Prompt for a new branch name via vim.ui.input (rendered by dressing.nvim).
--- @param callback fun(branch: string)  Called with the entered branch name.
prompt_branch = function(callback)
  vim.ui.input({ prompt = "New branch name: " }, function(branch)
    if branch and branch ~= "" then
      callback(branch)
    end
  end)
end

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

  local cwd = tab_cwd()
  local entries, paths = build_picker_entries(worktrees, cwd)

  fzf.fzf_exec(entries, {
    prompt = "Worktrees> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--no-multi"] = "",
    },
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        -- Find the path by matching the selected string back to our entries.
        -- fzf-lua strips ANSI codes from selections, so match against
        -- stripped versions of our entries.
        local target = nil
        for i, e in ipairs(entries) do
          local stripped = e:gsub("\27%[[%d;]*m", "")
          if stripped == selected[1] then
            target = paths[i]
            break
          end
        end
        if target then
          M.switch_to(target)
        end
      end,
    },
  })
end

------------------------------------------------------------------------
-- Public API: data for lualine components
------------------------------------------------------------------------

--- Return tabline-style entries for all worktrees.
--- Each entry has: branch, status, current (bool), open (bool).
--- Accepts an optional worktree list override for testing.
--- @param worktrees? neovia.WorktreeEntry[]
--- @return neovia.TablineEntry[]
function M.get_entries(worktrees)
  worktrees = worktrees or list_worktrees()
  local cwd = tab_cwd()
  local ok_pr, pr_mod = pcall(require, "neovia.pr")
  local entries = {} --- @type neovia.TablineEntry[]

  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path]
    local is_open = entry == nil or entry.open ~= false
    local pr_info = ok_pr and pr_mod.get(wt.branch) or nil
    table.insert(entries, {
      branch = wt.branch,
      path = wt.path,
      status = entry and entry.status or "unknown",
      current = wt.path == cwd,
      open = is_open,
      pr = pr_info,
    })
  end

  return entries
end

--- Return status info for the current working directory.
--- Returns nil if no state is tracked for the current directory.
--- @return { status: string, icon: string, hl: table }|nil
function M.get_current_status()
  local cwd = tab_cwd()
  local entry = state[cwd]
  if not entry then return nil end

  return {
    status = entry.status,
    icon = status_icon[entry.status] or status_icon.unknown,
    hl = status_hl_for(entry.status),
  }
end

--- @class neovia.TablineEntry
--- @field branch string
--- @field path string
--- @field status string
--- @field current boolean
--- @field open boolean
--- @field pr neovia.PrInfo|nil

------------------------------------------------------------------------
-- Tabline builder
------------------------------------------------------------------------

--- Spinner frames for "responding" status in the tabline.
--- Full braille block with rotating gap -- vertically centered in the cell.
local spinner_frames = { "⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾" }
local spinner_idx = 0

--- Return a single-character status indicator.
--- Every status returns an icon so the tabline width stays stable.
--- @param s string  One of "idle", "responding", "needs_attention", "unknown".
--- @return string
local function status_char(s)
  if s == "needs_attention" then return "󰀦" end
  if s == "responding" then
    spinner_idx = (spinner_idx % #spinner_frames) + 1
    return spinner_frames[spinner_idx]
  end
  if s == "unknown" then return "󰇘" end
  return "󰒲" -- idle: sleep/zzz
end

--- Worktree paths indexed by tabline click ID.
--- Populated on each render so the click handler can resolve the target.
--- @type table<integer, string>
local tabline_click_paths = {}
local tabline_click_next_id = 0

--- Lua-side click handler; called from the VimScript shim registered in setup().
--- @param id integer  Click ID (index into tabline_click_paths)
local function handle_tabline_click(id)
  local path = tabline_click_paths[id]
  if not path then return end
  M.switch_to(path)
end

--- Build the worktree tabline statusline string.
--- Non-current entries are clickable (switch worktree on click).
--- Returns "" when there are no visible (open) entries.
--- @param entries neovia.TablineEntry[]
--- @return string
--- Transitional highlight group name for a powerline separator between two sections.
--- @param from string  "sel", "wt", or "fill"
--- @param to string    "sel", "wt", or "fill"
--- @return string
local function trans_hl(from, to)
  if from == "sel" and to == "wt"   then return "NeoviaWtSel_to_wt" end
  if from == "sel" and to == "fill" then return "NeoviaWtSel_to_fill" end
  if from == "wt"  and to == "sel"  then return "NeoviaWt_to_sel" end
  if from == "wt"  and to == "wt"   then return "NeoviaWt_to_wt" end
  if from == "wt"  and to == "fill" then return "NeoviaWt_to_fill" end
  return "TabLineFill"
end

local function build_tabline(entries)
  if #entries == 0 then return "" end

  -- Reset click ID table each render cycle.
  tabline_click_paths = {}
  tabline_click_next_id = 0

  -- Collect visible entries first so we can look ahead for transitions.
  local visible = {}
  for _, e in ipairs(entries) do
    if e.open then table.insert(visible, e) end
  end
  if #visible == 0 then return "" end

  local parts = {}
  for i, e in ipairs(visible) do
    local char = status_char(e.status)
    local kind = e.current and "sel" or "wt"
    local bg_hl = e.current and "NeoviaWtSel" or "NeoviaWt"

    -- Build the tab content: [PR icon] branch name + status icon, all on bg_hl.
    -- Only the selected tab gets colored status icons; non-selected
    -- tabs keep the tab's own fg so they don't stand out.
    local pr_prefix = ""
    if e.pr then
      local ok_pr, pr_mod = pcall(require, "neovia.pr")
      if ok_pr then
        local icon = pr_mod.icon(e.pr.state)
        if icon ~= "" then
          pr_prefix = icon .. " "
        end
      end
    end
    local content = "%#" .. bg_hl .. "# " .. pr_prefix .. e.branch .. " " .. char .. " "

    -- Wrap non-current entries with click handler.
    if not e.current then
      tabline_click_next_id = tabline_click_next_id + 1
      local click_id = tabline_click_next_id
      tabline_click_paths[click_id] = e.path
      content = "%" .. click_id .. "@NeoviaWorktreeSwitch@" .. content .. "%T"
    end

    -- Powerline separator  after this entry.
    local next_kind = "fill"
    if i < #visible then
      next_kind = visible[i + 1].current and "sel" or "wt"
    end
    local sep = "%#" .. trans_hl(kind, next_kind) .. "#\u{e0b0}"

    table.insert(parts, content .. sep)
  end

  return table.concat(parts) .. "%#TabLineFill#"
end

--- Build the worktree tabline string from current state.
--- Convenience wrapper that calls get_entries() then build_tabline().
--- @param worktrees? neovia.WorktreeEntry[]
--- @return string
function M.build_tabline(worktrees)
  return build_tabline(M.get_entries(worktrees))
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
  process_event = process_event,
  subscribe_one = subscribe_one,
  ensure_subscriptions = ensure_subscriptions,
  unsubscribe_all = unsubscribe_all,
  resolve_git_common_dir = resolve_git_common_dir,
  list_worktrees = list_worktrees,
  build_picker_entries = build_picker_entries,
  build_close_candidates = build_close_candidates,
  find_current_worktree = find_current_worktree,
  prompt_branch = prompt_branch,
  tab_cwd = tab_cwd,
  save_session_id = save_session_id,
  build_tabline = build_tabline,
  handle_tabline_click = handle_tabline_click,

  --- Get the current click path lookup table (for assertions).
  --- @return table<integer, string>
  get_click_paths = function() return tabline_click_paths end,

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
    if dir_timer then
      dir_timer:stop()
      dir_timer:close()
      dir_timer = nil
    end
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_worktree")
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
      session_id = nil,
    }, overrides or {})
  end,
}

return M
