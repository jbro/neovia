-- neovia worktree module
-- Worktree lifecycle (create/switch/delete), status tracking via SSE,
-- and picker. Rendering lives in lua/plugins/ui.lua (decision 0009).

local M = {}

--- @class neovia.WorktreeEntry
--- @field path string Absolute path to the worktree
--- @field branch string Branch name (or "(detached)")
--- @field head string Short SHA
--- @field bare boolean

--- @class neovia.ModelState
--- @field model string|nil  "provider/model" string
--- @field variant string|nil  reasoning level ("high", "medium", "low")
--- @field mode string|nil  agent mode ("build", "plan", etc.)
--- @field mode_model_map table<string, string>|nil  per-mode model overrides

--- @class neovia.WorktreeState
--- @field status "unknown"|"idle"|"responding"|"needs_attention"
--- @field branch string
--- @field subscription table|nil  curl job handle from subscribe_to_events
--- @field pending_permissions table<string, boolean>  permission IDs awaiting reply
--- @field buffer_paths string[]  saved file paths (for switch restore)
--- @field session_id string|nil  cached opencode session ID (used by resync and fork)
--- @field model_state neovia.ModelState|nil  saved model/variant/mode for restore on switch
--- @field neo_tree_expanded string[]|nil  saved expanded node IDs (absolute paths) for restore on switch
--- @field last_buffer_path string|nil  path of the buffer displayed in the code window when switching away
--- @field last_view "code"|"diff"|nil  which tab (code or diffview) was last active

--- Per-directory state. Keyed by absolute path.
--- @type table<string, neovia.WorktreeState>
local state = {}

--- Create a fresh WorktreeState entry.
--- @param overrides? table
--- @return neovia.WorktreeState
local function make_entry(overrides)
  return vim.tbl_extend("force", {
    status = "unknown",
    branch = "main",
    pending_permissions = {},
    buffer_paths = {},
    session_id = nil,
    model_state = nil,
    neo_tree_expanded = nil,
    last_buffer_path = nil,
    last_view = nil,
  }, overrides or {})
end

--- Whether setup() has been called.
local initialised = false

--- Timer handle for DirChanged debounce (nil = no pending call).
--- @type uv_timer_t|nil
local dir_timer = nil

--- Registered SSE activity callbacks, keyed by unique string ID.
--- @type table<string, fun()>
local sse_activity_cbs = {}

--- Monotonic counter for callback IDs.
local sse_activity_cb_next = 0

-- Forward declarations
local ensure_sse, list_worktrees, disconnect_sse
local find_current_worktree, prompt_branch

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
-- Buffer helpers (delegated to neovia.session)
------------------------------------------------------------------------

local ok_session, session_mod = pcall(require, "neovia.session")
local collect_file_buffers = ok_session and session_mod.collect_file_buffers or function() return {} end
local unlist_file_buffers = ok_session and session_mod.unlist_file_buffers or function() end
local relist_buffers = ok_session and session_mod.relist_buffers or function() return {} end
local function wipeout_buffers_for_dir(dir)
  local entry = state[dir]
  if not entry then return end
  if ok_session then
    session_mod.wipeout_buffers_for_dir(entry)
  end
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

------------------------------------------------------------------------
-- SSE delegation (delegated to neovia.sse via /global/event)
------------------------------------------------------------------------

local ok_sse, sse_mod = pcall(require, "neovia.sse")

--- Get the server base URL from opencode.state.
--- The url field already includes the port (e.g. "http://localhost:4096").
--- @return string|nil
local function get_base_url()
  local oc_state = package.loaded["opencode.state"]
  if not oc_state then return nil end
  local srv = oc_state.opencode_server
  if not srv or not srv.url then return nil end
  return srv.url:gsub("/$", "")
end

--- SSE event callback: route global events by directory.
--- For server.connected (dir=nil), apply to all entries.
--- After routing, fires all registered SSE activity callbacks.
--- @param dir string|nil
--- @param event table
local function process_event(dir, event)
  if not ok_sse then return end
  if dir then
    sse_mod.process_event(state, dir, event, apply_event)
  else
    -- Broadcast events (e.g. server.connected) apply to all entries
    for d, _ in pairs(state) do
      sse_mod.process_event(state, d, event, apply_event)
    end
  end
  -- Fire registered SSE activity callbacks (e.g. magic-context drain).
  for _, cb in pairs(sse_activity_cbs) do
    pcall(cb)
  end
end

--- Populate state entries from list_worktrees(), remove stale ones,
--- and ensure the global SSE connection is alive.
ensure_sse = function()
  if not ok_sse then return end

  local worktrees = list_worktrees()
  if #worktrees == 0 then return end

  local valid = {} --- @type table<string, boolean>
  for _, wt in ipairs(worktrees) do
    valid[wt.path] = true
    if not state[wt.path] then
      state[wt.path] = {
        status = "unknown",
        branch = wt.branch,
        pending_permissions = {},
        buffer_paths = {},
      }
    end
  end

   -- Remove state for worktrees that no longer exist on disk
  for d, _ in pairs(state) do
    if not valid[d] then
      state[d] = nil
    end
  end

  -- If the current worktree was deleted externally, switch to main.
  -- This can happen when another session (e.g., opencode CLI or other user)
  -- deletes a worktree while we're viewing it.
  local cwd = tab_cwd()
  if cwd and not valid[cwd] then
    local main_path = nil
    for _, wt in ipairs(worktrees) do
      if not wt.bare then
        main_path = wt.path
        break
      end
    end
    if main_path then
      M.switch_to(main_path)
    end
  end

  local base_url = get_base_url()
  if base_url then
    sse_mod.ensure_connection(base_url, process_event)
  end
end

--- Shut down the global SSE connection.
disconnect_sse = function()
  if ok_sse then
    sse_mod.disconnect()
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

  -- Clean up SSE connection on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() disconnect_sse() end,
    desc = "neovia: clean up worktree SSE connection",
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
        ensure_sse()
        vim.cmd.redrawtabline()
      end))
    end,
    desc = "neovia: refresh worktree state on tcd",
  })

  -- Connect to SSE when the opencode server is ready.
  -- Not once=true: the server may restart (external process) and
  -- fire this event again, so we need to reconnect each time.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OpencodeEvent:server.connected",
    callback = function()
      vim.defer_fn(function() ensure_sse() end, 1000)
    end,
    desc = "neovia: connect to global SSE on server ready",
  })

  -- Also try immediately in case the server is already running
  vim.defer_fn(function()
    local oc_state = package.loaded["opencode.state"]
    if oc_state and oc_state.api_client then
      ensure_sse()
    end
  end, 2000)

  -- Wire the tabline click handler to switch worktrees.
  local ok_tl, tl = pcall(require, "neovia.tabline")
  if ok_tl then
    tl.set_click_handler(function(path)
      M.switch_to(path)
    end)

    -- Global VimScript click handler for %@FuncName@ statusline syntax.
    -- function! is idempotent (overwrites on reload).
    vim.cmd([[
      function! NeoviaWorktreeSwitch(id, clicks, button, modifiers)
        call v:lua.require('neovia.tabline')._internal.handle_tabline_click(a:id)
      endfunction
    ]])
  end
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

  -- Query the API for each other worktree
  for dir, entry in pairs(state) do
    if dir ~= cwd then
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
--- Writes when the active session genuinely belongs to `dir`, i.e. opencode's
--- current_cwd matches.  This captures a session created mid-session (e.g. a
--- new session via <leader>on) so it is restored on a later switch back.
---
--- The current_cwd guard prevents overwriting a known-good session_id with a
--- stale active_session that handle_directory_change selected from the wrong
--- worktree before switch_session (async) has completed: in that race the
--- active session belongs to a different directory, so current_cwd ~= dir.
---
--- On first save (no current_cwd available yet) we still fall back to writing
--- the active session when the entry has none, preserving first-visit capture.
--- @param dir string
local function save_session_id(dir)
  local entry = state[dir]
  if not entry then return end
  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state then return end
  local active = oc_state.active_session
  if not active or not active.id then return end

  -- The active session is authoritative for `dir` only when opencode's
  -- current_cwd matches.  Then capture it (covers newly created sessions).
  if oc_state.current_cwd == dir then
    entry.session_id = active.id
    return
  end

  -- current_cwd unknown/mismatched: only fill in a first-time session_id,
  -- never overwrite a known-good one with a possibly-stale active session.
  if not entry.session_id then
    entry.session_id = active.id
  end
end

--- Clear opencode's active session, blanking the panel and preventing
--- send_message from routing input to a stale session.  Guarded for older
--- opencode versions / test mocks that lack session.clear_active.
--- @param oc_state table  opencode.state module
local function clear_active_session(oc_state)
  if oc_state.session and oc_state.session.clear_active then
    pcall(oc_state.session.clear_active)
  end
end

--- Deterministically select or create the opencode session for `dir` after a
--- tcd.  With opencode's lock_session_to_directory on, handle_directory_change
--- never auto-selects, so neovia is the sole authority on session selection
--- (no current_cwd pre-set hack, no polling race).
---
--- - Saved session_id  -> switch_session(id).
--- - First visit        -> list_sessions(dir); switch to newest non-child,
---                         or create a new session when none exist.
---
--- Before any async work, the stale active session (still pointing at the
--- worktree we just left) is cleared synchronously whenever it differs from
--- the target.  This closes the window in which the opencode panel shows the
--- previous worktree's session and routes typed input into it: send_message
--- returns early when active_session is nil, so input cannot leak to the wrong
--- session while the switch resolves.
--- @param dir string
local function select_or_create_session(dir)
  local entry = state[dir]
  if not entry then return end

  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state then return end
  local ok_rt, session_runtime = pcall(require, "opencode.services.session_runtime")
  if not ok_rt then return end

  local active = oc_state.active_session

  -- Saved session: deterministic switch, no polling.
  if entry.session_id then
    if active and active.id == entry.session_id then return end
    -- Clear the stale active session before the async switch so input can't
    -- reach the previous worktree's session in the gap.
    clear_active_session(oc_state)
    session_runtime.switch_session(entry.session_id)
    return
  end

  -- First visit: clear the stale active session up front (input-leak guard),
  -- then discover-or-create a session scoped to this directory.
  if active then clear_active_session(oc_state) end
  if not oc_state.api_client then return end
  oc_state.api_client
    :list_sessions(dir)
    :and_then(function(sessions)
      vim.schedule(function()
        local best = nil
        if type(sessions) == "table" then
          table.sort(sessions, function(a, b)
            return a.time.updated > b.time.updated
          end)
          for _, s in ipairs(sessions) do
            if s.parentID == nil then
              best = s
              break
            end
          end
        end

        if best then
          entry.session_id = best.id
          local cur = oc_state.active_session
          if cur and cur.id == best.id then return end
          session_runtime.switch_session(best.id)
          return
        end

        -- No session exists for this worktree yet: create one.  The
        -- api_client injects the current directory, so creation is
        -- correctly scoped after tcd.
        if not session_runtime.create_new_session then return end
        session_runtime.create_new_session():and_then(function(new_session)
          vim.schedule(function()
            if not new_session or not new_session.id then return end
            entry.session_id = new_session.id
            if oc_state.session and oc_state.session.set_active then
              oc_state.session.set_active(new_session)
            else
              session_runtime.switch_session(new_session.id)
            end
          end)
        end)
      end)
    end)
    :catch(function() end)
end

--- Save the current opencode model/variant/mode into state for a directory.
--- @param dir string
local function save_model_state(dir)
  local entry = state[dir]
  if not entry then return end
  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state then return end
  if not oc_state.current_model then return end

  entry.model_state = {
    model = oc_state.current_model,
    variant = oc_state.current_variant,
    mode = oc_state.current_mode,
    mode_model_map = oc_state.user_mode_model_map
      and vim.deepcopy(oc_state.user_mode_model_map) or nil,
  }
end

--- Restore saved model/variant/mode from state for a directory.
--- Must be called after set_model auto-clears variant (so set_variant comes last).
--- @param dir string
local function restore_model_state(dir)
  local entry = state[dir]
  if not entry or not entry.model_state then return end

  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state or not oc_state.model then return end

  local ms = entry.model_state

  if ms.mode_model_map then
    oc_state.model.set_mode_model_map(ms.mode_model_map)
  end

  -- set_model triggers a subscriber that auto-clears variant and loads
  -- the disk-persisted one, so we call set_variant after set_model.
  if ms.model then
    oc_state.model.set_model(ms.model)
  end

  if ms.variant then
    oc_state.model.set_variant(ms.variant)
  end
end

--- Save Neo-tree expanded node IDs into state for the given directory.
--- Uses neo-tree's renderer API to read the current tree's expanded nodes.
--- @param dir string
local function save_neo_tree_expanded(dir)
  local entry = state[dir]
  if not entry then return end
  local ok_mgr, manager = pcall(require, "neo-tree.sources.manager")
  if not ok_mgr then return end
  local ok_ren, renderer = pcall(require, "neo-tree.ui.renderer")
  if not ok_ren then return end
  local neo_state = manager.get_state("filesystem")
  if neo_state and neo_state.tree then
    entry.neo_tree_expanded = renderer.get_expanded_nodes(neo_state.tree)
  end
end

--- Restore saved Neo-tree expanded node IDs via force_open_folders.
--- Must be called BEFORE the Neotree dir= navigate so the renderer
--- uses the forced list instead of defaulting to root-only.
--- @param dir string
local function restore_neo_tree_expanded(dir)
  local entry = state[dir]
  if not entry or not entry.neo_tree_expanded or #entry.neo_tree_expanded == 0 then
    return
  end
  local ok_mgr, manager = pcall(require, "neo-tree.sources.manager")
  if not ok_mgr then return end
  local neo_state = manager.get_state("filesystem")
  if neo_state then
    neo_state.force_open_folders = entry.neo_tree_expanded
  end
end

------------------------------------------------------------------------
-- Neo-tree git status helpers
------------------------------------------------------------------------

--- Remove "!" (ignored) entries for .worktrees paths from a neo-tree
--- git status table. The parent repo's .gitignore lists .worktrees/,
--- so neo-tree's status_async marks everything under it as ignored.
--- This strips those entries so child worktrees render with correct
--- git status from their own status_async call.
--- Mutates the table in-place.
--- @param status table<string, string> neo-tree git status table (path -> code)
--- @param git_root string absolute path to the repo root (no trailing slash)
local function strip_worktrees_ignored(status, git_root)
  local worktrees_dir = git_root .. "/.worktrees"
  local to_remove = {}
  for path, code in pairs(status) do
    if
      code == "!"
      and (path == worktrees_dir or vim.startswith(path, worktrees_dir .. "/"))
    then
      to_remove[#to_remove + 1] = path
    end
  end
  for _, path in ipairs(to_remove) do
    status[path] = nil
  end
end

--- Strip .worktrees/ ignored entries from ALL registered neo-tree worktrees.
--- Called from the git_status_changed event handler. Each status_async cycle
--- can re-populate ignored entries for any registered worktree, not just the
--- one that fired the event. This ensures no stale "!" entries survive
--- across worktrees.
local function strip_all_worktrees_ignored()
  local ok, neo_git = pcall(require, "neo-tree.git")
  if not ok then return end
  for root, wt in pairs(neo_git.worktrees) do
    if wt.status then
      strip_worktrees_ignored(wt.status, root)
    end
  end
end

--- Patch neo-tree's find_existing_worktree to always return the deepest
--- (most specific) matching worktree root.
---
--- Neo-tree iterates M.worktrees with pairs() (unordered). When both a
--- parent repo (e.g. /repo) and a child worktree (e.g. /repo/.worktrees/foo)
--- are registered, either can match first. If the parent matches, the child's
--- git status is never consulted and files get the wrong status or no status.
---
--- This replaces find_existing_worktree with a version that picks the longest
--- matching root, then caches the result in _upward_worktree_cache.
--- Idempotent: safe to call multiple times.
local neo_tree_patched = false
local function patch_neo_tree_git_lookup()
  if neo_tree_patched then return end
  local ok, neo_git = pcall(require, "neo-tree.git")
  if not ok then return end
  local ok_utils, neo_utils = pcall(require, "neo-tree.utils")
  if not ok_utils then return end

  neo_git.find_existing_worktree = function(path)
    local cached = neo_git._upward_worktree_cache[path]
    if cached ~= nil then
      local wt = cached and neo_git.worktrees[cached]
      return cached or nil, wt and wt
    end
    local best_root, best_wt
    for root, wt in pairs(neo_git.worktrees) do
      if neo_utils.is_subpath(root, path, true) then
        if not best_root or #root > #best_root then
          best_root = root
          best_wt = wt
        end
      end
    end
    neo_git._upward_worktree_cache[path] = best_root or false
    return best_root, best_wt
  end
  neo_tree_patched = true
end

--- Public entry point for the neo-tree git_status_changed event handler.
--- Strips .worktrees/ ignored entries from all registered worktrees, then
--- patches find_existing_worktree to prefer the deepest match.
function M.on_git_status_changed()
  strip_all_worktrees_ignored()
  patch_neo_tree_git_lookup()
end

------------------------------------------------------------------------
-- Public API: worktree switch
------------------------------------------------------------------------

--- Switch to a worktree directory.
--- Saves current file buffer paths (unlist), tcd to target,
--- restores saved buffers (relist) or opens noname buffer on first visit.
--- Session switching is left to opencode.nvim's DirChanged autocmd
--- (fires synchronously during tcd) so that SSE reconnection and
--- session loading happen atomically.
--- Tells neo-tree the new root directory.
--- @param dir string  Absolute path to the target worktree.
function M.switch_to(dir)
  M.setup()

  local cwd = tab_cwd()
  if cwd == dir then return end

  -- Save current buffers, session ID, model state, neo-tree expanded nodes,
  -- and which tab (code vs diffview) was active.
  local current_entry = state[cwd]
  if current_entry then
    current_entry.buffer_paths = collect_file_buffers()
    -- Save which buffer was focused in the code window
    local ok_nav_save, nav_save = pcall(require, "neovia.navigate")
    if ok_nav_save then
      local code_win = nav_save.find_code_win()
      if code_win then
        local cbuf = vim.api.nvim_win_get_buf(code_win)
        local cname = vim.api.nvim_buf_get_name(cbuf)
        current_entry.last_buffer_path = cname ~= "" and cname or nil
      end
    end
    save_session_id(cwd)
    save_model_state(cwd)
    save_neo_tree_expanded(cwd)
    -- Record whether we're leaving from a diffview tab
    local ok_dv, dv_mod = pcall(require, "neovia.diffview")
    if ok_dv and dv_mod.is_diffview_tab(vim.api.nvim_get_current_tabpage()) then
      current_entry.last_view = "diff"
    else
      current_entry.last_view = "code"
    end
  end

  -- If currently on a diffview tab, switch to the code tab first
  -- so tcd and buffer operations happen in the right context.
  do
    local ok_dv, dv_mod = pcall(require, "neovia.diffview")
    if ok_dv and dv_mod.is_diffview_tab(vim.api.nvim_get_current_tabpage()) then
      vim.cmd("tabfirst")
    end
  end

  -- Unlist current file buffers
  unlist_file_buffers()

  -- With lock_session_to_directory on, opencode's handle_directory_change is
  -- a no-op, so neovia owns session selection entirely.  No current_cwd
  -- pre-set hack, no race.

  vim.cmd.tcd(dir)

  -- Ensure target has a state entry
  if not state[dir] then
    state[dir] = make_entry({ branch = "" })
  end

  -- Select (or create) the target worktree's session immediately after tcd,
  -- before the expensive neo-tree rescan.  This clears the stale active
  -- session synchronously (so typed input can't reach the previous worktree's
  -- session) and starts the switch/create as early as possible to minimise the
  -- latency before the correct session is shown.
  select_or_create_session(dir)

  -- Restore saved buffers or show a fresh noname buffer on first visit
  local target = state[dir]
  local ok_nav, navigate = pcall(require, "neovia.navigate")
  if ok_nav then
    local win = navigate.find_code_win()
    if win then
      if #target.buffer_paths > 0 then
        local bufs = relist_buffers(target.buffer_paths)
        if #bufs > 0 then
          vim.api.nvim_set_current_win(win)
          -- Prefer the buffer that was focused when we left this worktree
          local restore_buf = bufs[1]
          if target.last_buffer_path then
            for _, b in ipairs(bufs) do
              if vim.api.nvim_buf_get_name(b) == target.last_buffer_path then
                restore_buf = b
                break
              end
            end
          end
          vim.api.nvim_win_set_buf(win, restore_buf)
        end
      else
        -- First visit: replace the stale buffer with a fresh noname buffer
        local fresh = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(win, fresh)
      end
    end
  end

  -- Ensure session notes buffer is shown in the notes window
  local ok_notes, notes_mod = pcall(require, "neovia.notes")
  if ok_notes and ok_nav then
    local notes_win = navigate.find_notes_win()
    if notes_win then
      local nbuf = notes_mod.get_or_create(dir)
      vim.api.nvim_win_set_buf(notes_win, nbuf)
    end
    -- Re-enforce canonical height (buffer swap or equalalways may drift it).
    local ok_layout, layout_mod = pcall(require, "neovia.layout")
    if ok_layout then layout_mod.enforce_notes_height() end
  end

  -- Immediate tabline update so the current-worktree highlight is visible
  -- without waiting for the debounced DirChanged handler.
  vim.cmd.redrawtabline()

  -- If the target worktree was last viewed on its diffview tab, jump there.
  do
    local ok_dv, dv_mod = pcall(require, "neovia.diffview")
    if ok_dv and target.last_view == "diff" then
      local dv_tab = dv_mod.tab_for_worktree(dir)
      if dv_tab then
        local tabnr = vim.api.nvim_tabpage_get_number(dv_tab)
        vim.cmd("tabnext " .. tabnr)
      end
    end
  end

  -- Defer neo-tree root update and layout check.  The Neotree dir= command
  -- rescans the filesystem synchronously and is the most expensive single
  -- call in the switch path.  Running it in vim.schedule moves it out of the
  -- critical path so the UI feels instant.
   -- Pending permissions/questions are restored by opencode.nvim's
   -- render_full_session() via REST API calls after renderer.reset().
   vim.schedule(function()
    -- Invalidate neo-tree's upward worktree cache so the next lookup
     -- re-discovers the correct git root for the new directory.
     -- We must NOT remove entries from neo_git.worktrees: async git
     -- status jobs reference those entries by root path, and deleting
     -- an entry while a job is in flight causes "Could not find
     -- worktree" assertion crashes in change_worktree_git_status.
     -- Clearing only the lookup cache is safe — Neotree dir= below
     -- re-registers the target directory via try_register_worktree.
      local ok_git, neo_git = pcall(require, "neo-tree.git")
      if ok_git then
        neo_git._upward_worktree_cache = setmetatable({}, { __mode = "kv" })
      end
      -- Ensure the deepest-match patch is active and strip stale
      -- .worktrees/ ignored entries before the rescan.
      patch_neo_tree_git_lookup()
      strip_all_worktrees_ignored()

      -- Clear cached git status for parent worktree roots so neo-tree
      -- does not short-circuit on a stale raw_status_text_cache match.
      -- Skip the target's own entry (root == dir): keep its status as
      -- a warm cache and let status_async refresh it in the background.
      -- This avoids the expensive synchronous full-scan that Neotree
      -- dir= performs when status is nil — the main bottleneck when
      -- switching to the main worktree (full repo checkout).
      if ok_git and neo_git.worktrees then
        for root, wt in pairs(neo_git.worktrees) do
          if root ~= dir and vim.startswith(dir, root) then
            wt.status = nil
          end
        end
      end

    -- Restore saved expanded nodes before navigating so neo-tree's
    -- renderer uses force_open_folders instead of collapsing to root.
    restore_neo_tree_expanded(dir)

    -- Tell neo-tree the new root (bind_to_cwd is off, so we do it explicitly).
    -- Use manager.navigate() with async=true instead of :Neotree dir= which
    -- hardcodes async=false and forces a synchronous filesystem rescan.
    -- The async path uses libuv readdir callbacks so the UI stays responsive.
    local ok_mgr, neo_mgr = pcall(require, "neo-tree.sources.manager")
    if ok_mgr then
      local mgr_state = neo_mgr.get_state("filesystem")
      neo_mgr.navigate(mgr_state, dir, nil, nil, true)
    end

    -- Layout check: opencode.nvim's session swap is async, so if
    -- it disrupts the output window, apply repairs it.
    local ok, layout = pcall(require, "neovia.layout")
    if ok then layout.apply() end

    -- Session selection already happened synchronously after tcd (above).
    -- Restore saved model/variant/mode after the session switch has
    -- settled.  set_model auto-clears variant (via a subscriber), so
    -- restore_model_state calls set_variant last.
    restore_model_state(dir)
  end)

  vim.notify("Switched to " .. dir, vim.log.levels.INFO)
end

------------------------------------------------------------------------
-- Public API: worktree create / delete
------------------------------------------------------------------------

--- Create a new worktree.
--- By default branches from the main branch. Pass `from_current = true` to
--- branch from the current HEAD, or `fork = true` to branch from current HEAD
--- and fork the opencode session.
--- @param opts? { fork?: boolean, from_current?: boolean }
function M.create(opts)
  M.setup()
  opts = opts or {}
  local do_fork = opts.fork or false
  local from_current = opts.from_current or false

  -- Resolve start_point: branch from main unless forking or from_current.
  -- Call through _internal so tests can stub list_worktrees.
  local start_point = nil
  if not do_fork and not from_current then
    local worktrees = M._internal.list_worktrees()
    if #worktrees > 0 then
      start_point = worktrees[1].branch
    end
  end

  prompt_branch(function(branch)
    M._create_continue(branch, do_fork, start_point)
  end)
end

--- Internal: continue worktree creation after prompts.
--- @param branch string
--- @param do_fork boolean
--- @param start_point? string  Git ref to base the new branch on (default: HEAD).
function M._create_continue(branch, do_fork, start_point)
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
  -- worktree's opencode session exists before we switch to it.
  if do_fork then
    local oc_state = package.loaded["opencode.state"]
    if oc_state and oc_state.api_client and oc_state.active_session then
      local fork_data = vim.empty_dict()
      oc_state.api_client
        :fork_session(oc_state.active_session.id, fork_data, path)
        :and_then(function(response)
          vim.schedule(function()
            if response and response.id then
              -- Record the forked session as the worktree's session BEFORE
              -- switching.  Under the session-lock model switch_to's
              -- select_or_create_session then takes the deterministic
              -- saved-session branch and activates exactly this fork --
              -- no discover/create race, no double switch.
              if not state[path] then
                state[path] = make_entry({ branch = branch })
              end
              state[path].session_id = response.id
              M.switch_to(path)
              vim.notify("Session forked for " .. branch, vim.log.levels.INFO)
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

  -- Switch away if deleting the current worktree
  local cwd = tab_cwd()
  if cwd == wt.path then
    local worktrees = list_worktrees()
    local main_path = nil
    for _, w in ipairs(worktrees) do
      if w.path ~= wt.path and not w.bare then
        main_path = w.path
        break
      end
    end
    if main_path then
      M.switch_to(main_path)
    end
  end

  -- Wipeout buffers and tear down SSE for this worktree
  local entry = state[wt.path]
  if entry then
    local ok_notes, notes_mod = pcall(require, "neovia.notes")
    if ok_notes then
      notes_mod.save(wt.path)
      notes_mod.wipe(wt.path)
    end
    wipeout_buffers_for_dir(wt.path)
    if entry.subscription and type(entry.subscription.shutdown) == "function" then
      pcall(entry.subscription.shutdown)
    end
    entry.subscription = nil
  end

  -- Close any diffview tab for this worktree
  local ok_dv, dv_mod = pcall(require, "neovia.diffview")
  if ok_dv then
    dv_mod.close_for_worktree(wt.path)
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

  -- Delete notes storage (worktree is gone, notes lose context)
  local ok_notes, notes = pcall(require, "neovia.notes")
  if ok_notes then
    notes.delete_storage(wt.path)
  end

  -- Clean up state
  state[wt.path] = nil

  -- Refresh state (SSE connection stays alive, stale entry already removed)
  ensure_sse()

  vim.notify("Deleted worktree " .. wt.branch, vim.log.levels.INFO)
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

--- Collect worktree paths in order, returning the list and the
--- 1-based index of the current worktree within it.
--- @return string[] paths
--- @return integer? current_idx  nil if cwd is not in the list.
local function worktree_path_list()
  local worktrees = list_worktrees()
  local cwd = tab_cwd()
  local paths = {}
  local current_idx = nil
  for _, wt in ipairs(worktrees) do
    table.insert(paths, wt.path)
    if wt.path == cwd then current_idx = #paths end
  end
  return paths, current_idx
end

--- Switch to the next worktree (wraps around).
function M.next()
  M.setup()
  local paths, idx = worktree_path_list()
  if not idx or #paths <= 1 then return end
  local next_idx = (idx % #paths) + 1
  M.switch_to(paths[next_idx])
end

--- Switch to the previous worktree (wraps around).
function M.prev()
  M.setup()
  local paths, idx = worktree_path_list()
  if not idx or #paths <= 1 then return end
  local prev_idx = ((idx - 2) % #paths) + 1
  M.switch_to(paths[prev_idx])
end

--- Cycle forward to the next worktree with needs_attention status.
--- Wraps around. No-op if no worktree needs attention.
function M.next_attention()
  M.setup()
  local paths, current_idx = worktree_path_list()

  if not current_idx or #paths == 0 then return end

  -- Search forward from current+1, wrapping around
  for offset = 1, #paths - 1 do
    local i = ((current_idx - 1 + offset) % #paths) + 1
    local path = paths[i]
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
--- Shows all worktrees. Selecting a worktree switches to it.
function M.pick()
  M.setup()

  -- Refresh worktree list and SSE state
  ensure_sse()

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
  local ok_tl, tl = pcall(require, "neovia.tabline")
  if not ok_tl then return end
  local entries, paths = tl.build_picker_entries(worktrees, cwd, state)

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
--- Each entry has: branch, status, current (bool).
--- Accepts an optional worktree list override for testing.
--- @param worktrees? neovia.WorktreeEntry[]
--- @return neovia.TablineEntry[]
function M.get_entries(worktrees)
  worktrees = worktrees or list_worktrees()
  local cwd = tab_cwd()
  local ok_pr, pr_mod = pcall(require, "neovia.pr")
  local ok_dv, dv_mod = pcall(require, "neovia.diffview")
  local entries = {} --- @type neovia.TablineEntry[]

  for _, wt in ipairs(worktrees) do
    local entry = state[wt.path]
    local pr_info = ok_pr and pr_mod.get(wt.branch) or nil
    -- Use the snapshotted branch from state (stable across rebases);
    -- fall back to the live git branch for worktrees not yet in state.
    local branch = (entry and entry.branch ~= "") and entry.branch or wt.branch

    -- Determine active view: "diff" when this worktree has an open diffview tab.
    local view = nil
    if ok_dv and dv_mod.has_diffview_tab(wt.path) then
      view = "diff"
    end

    table.insert(entries, {
      branch = branch,
      path = wt.path,
      status = entry and entry.status or "unknown",
      current = wt.path == cwd,
      pr = pr_info,
      view = view,
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

  local ok_tl, tl = pcall(require, "neovia.tabline")
  local display = ok_tl and tl.status_display(entry.status)
    or { icon = "[idle]", hl = { fg = "#565f89" } }

  return {
    status = entry.status,
    icon = display.icon,
    hl = display.hl,
  }
end

--- Return the current opencode model name (provider prefix stripped).
--- Reads live state from opencode; returns nil when unavailable.
--- @return string|nil
function M.get_current_model()
  local cwd = tab_cwd()
  if not state[cwd] then return nil end

  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state then return nil end
  local model = oc_state.current_model
  if not model then return nil end

  -- Strip "provider/" prefix (e.g. "anthropic/claude-opus-4-6" -> "claude-opus-4-6")
  return model:match("[^/]+$") or model
end

--- Build the worktree tabline string from current state.
--- Convenience wrapper that calls get_entries() then tabline.build().
--- @param worktrees? neovia.WorktreeEntry[]
--- @return string
function M.build_tabline(worktrees)
  local ok_tl, tl = pcall(require, "neovia.tabline")
  if not ok_tl then return "" end
  return tl.build(M.get_entries(worktrees))
end

--- Register a callback to be called on every SSE event.
--- Returns a string ID that can be passed to unregister_sse_activity_cb.
--- @param fn fun()
--- @return string id
function M.register_sse_activity_cb(fn)
  sse_activity_cb_next = sse_activity_cb_next + 1
  local id = "sse_cb_" .. sse_activity_cb_next
  sse_activity_cbs[id] = fn
  return id
end

--- Remove a previously registered SSE activity callback.
--- No-op if the ID is not found.
--- @param id string
function M.unregister_sse_activity_cb(id)
  sse_activity_cbs[id] = nil
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
  ensure_sse = ensure_sse,
  disconnect_sse = disconnect_sse,
  get_base_url = get_base_url,
  resolve_git_common_dir = resolve_git_common_dir,
  strip_worktrees_ignored = strip_worktrees_ignored,
  strip_all_worktrees_ignored = strip_all_worktrees_ignored,
  patch_neo_tree_git_lookup = patch_neo_tree_git_lookup,
  list_worktrees = list_worktrees,
  find_current_worktree = find_current_worktree,
  prompt_branch = prompt_branch,
  tab_cwd = tab_cwd,
  save_session_id = save_session_id,
  select_or_create_session = select_or_create_session,
  save_neo_tree_expanded = save_neo_tree_expanded,
  restore_neo_tree_expanded = restore_neo_tree_expanded,

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
    disconnect_sse()
    state = {}
    initialised = false
    neo_tree_patched = false
    sse_activity_cbs = {}
    sse_activity_cb_next = 0
    if dir_timer then
      dir_timer:stop()
      dir_timer:close()
      dir_timer = nil
    end
    pcall(vim.api.nvim_del_augroup_by_name, "neovia_worktree")
  end,

  make_entry = make_entry,
}

return M
