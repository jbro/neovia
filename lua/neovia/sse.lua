-- neovia sse module
-- SSE subscription lifecycle for worktree status tracking.
-- Operates on a state table provided by the caller (worktree module).

local M = {}

--- Subscribe to SSE events for a single worktree directory.
--- @param state table<string, table>  Per-dir state table.
--- @param dir string
--- @param event_callback fun(dir: string, event: table)
function M.subscribe_one(state, dir, event_callback)
  local oc_state = package.loaded["opencode.state"]
  if not oc_state then return end

  local api_client = oc_state.api_client
  if not api_client then return end

  local handle = api_client:subscribe_to_events(dir, function(event)
    vim.schedule(function()
      event_callback(dir, event)
    end)
  end)

  if state[dir] then
    state[dir].subscription = handle
  end
end

--- Process a single SSE event and update state for the given directory.
--- Calls apply_fn(entry, event) and redraws if changed.
--- Triggers magic-context refresh on completed assistant messages.
--- @param state table<string, table>
--- @param dir string
--- @param event table
--- @param apply_fn fun(entry: table, event: table): boolean
function M.process_event(state, dir, event, apply_fn)
  local entry = state[dir]
  if not entry then return end

  if apply_fn(entry, event) then
    vim.cmd.redrawstatus()
    vim.cmd.redrawtabline()
  end
end

--- Ensure every known worktree has an active SSE subscription.
--- @param state table<string, table>
--- @param worktrees table[]  Output of list_worktrees().
--- @param event_callback fun(dir: string, event: table)
function M.ensure_subscriptions(state, worktrees, event_callback)
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

    local entry = state[wt.path]
    local alive = entry.subscription
      and type(entry.subscription.is_running) == "function"
      and entry.subscription.is_running()
    if not alive then
      if entry.subscription and type(entry.subscription.shutdown) == "function" then
        pcall(entry.subscription.shutdown)
      end
      entry.subscription = nil
      M.subscribe_one(state, wt.path, event_callback)
    end
  end

  -- Remove state for worktrees that no longer exist on disk
  for dir, _ in pairs(state) do
    if not valid[dir] then
      local entry = state[dir]
      if entry.subscription and type(entry.subscription.shutdown) == "function" then
        pcall(entry.subscription.shutdown)
      end
      state[dir] = nil
    end
  end
end

--- Shut down all SSE subscriptions.
--- @param state table<string, table>
function M.unsubscribe_all(state)
  for _, entry in pairs(state) do
    if entry.subscription and type(entry.subscription.shutdown) == "function" then
      pcall(entry.subscription.shutdown)
    end
    entry.subscription = nil
  end
end

return M
