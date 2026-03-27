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

--- Whether setup() has been called.
local initialised = false

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

  -- Clean up subscriptions on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() unsubscribe_all() end,
    desc = "neovia: clean up worktree SSE subscriptions",
  })

  -- Refresh worktree list on directory change
  vim.api.nvim_create_autocmd("DirChanged", {
    callback = function()
      vim.defer_fn(function() ensure_subscriptions() end, 500)
    end,
    desc = "neovia: refresh worktree subscriptions on tcd",
  })

  -- Defer initial subscription until opencode server is ready.
  -- Listen for the server_ready custom event.
  vim.api.nvim_create_autocmd("User", {
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
  vim.schedule(function() vim.cmd.redrawstatus() end)
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

  -- Build entries
  local entries = {} --- @type string[]
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
  end

  fzf.fzf_exec(entries, {
    prompt = "Worktrees> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--no-multi"] = "",
      ["--print-query"] = "",
    },
    actions = {
      ["default"] = function(selected, opts)
        if not selected or #selected == 0 then return end

        -- With --print-query, selected[1] is the query, selected[2] is the match
        local query = selected[1] or ""
        local match = selected[2]

        -- Try to find the worktree that matches
        local target = nil
        if match then
          for _, wt in ipairs(worktrees) do
            if match:find(wt.branch, 1, true) or match:find(wt.path, 1, true) then
              target = wt.path
              break
            end
          end
        end

        if target then
          -- Switch to existing worktree
          vim.cmd.tcd(target)
          vim.notify("Switched to " .. target, vim.log.levels.INFO)
        elseif query ~= "" then
          -- No match: create a new worktree with the query as branch name
          vim.ui.input({
            prompt = string.format("Create worktree for branch '%s'? (path or empty to cancel): ", query),
            default = vim.fn.fnamemodify(cwd, ":h") .. "/" .. query,
          }, function(path)
            if not path or path == "" then return end
            local result = vim.system(
              { "git", "worktree", "add", "-b", query, path },
              { text = true }
            ):wait()
            if result.code == 0 then
              vim.cmd.tcd(path)
              vim.notify("Created and switched to " .. path, vim.log.levels.INFO)
            else
              vim.notify(
                "Failed to create worktree: " .. (result.stderr or ""),
                vim.log.levels.ERROR
              )
            end
          end)
        end
      end,
    },
  })
end

------------------------------------------------------------------------
-- Lualine components
------------------------------------------------------------------------

--- Define highlight groups (called lazily).
local hl_defined = false
local function ensure_highlights()
  if hl_defined then return end
  hl_defined = true
  for name, hl in pairs(status_hl) do
    vim.api.nvim_set_hl(0, "NeoviaWt_" .. name, hl)
  end
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

--- Lualine component: aggregate status across all worktrees.
--- @return string
function M.lualine_aggregate()
  ensure_highlights()
  M.setup()

  local worst = "idle" --- @type string
  local count = vim.tbl_count(state)

  -- Don't show anything if there's only one worktree or all idle
  if count <= 1 then return "" end

  for _, entry in pairs(state) do
    if entry.status == "needs_attention" then
      worst = "needs_attention"
      break -- can't get worse
    elseif entry.status == "responding" then
      worst = "responding"
    end
  end

  if worst == "idle" then return "" end

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
  local worst = "idle"
  for _, entry in pairs(state) do
    if entry.status == "needs_attention" then
      worst = "needs_attention"
      break
    elseif entry.status == "responding" then
      worst = "responding"
    end
  end
  if worst == "idle" then return nil end
  return { fg = (status_hl[worst] or {}).fg }
end

------------------------------------------------------------------------
-- Test internals (exposed for unit tests only)
------------------------------------------------------------------------

--- @class neovia.WorktreeInternals
M._internal = {
  parse_worktree_porcelain = parse_worktree_porcelain,
  apply_event = apply_event,
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
    initialised = false
    git_common_dir = nil
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
