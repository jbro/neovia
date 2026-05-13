-- neovia sse module
-- Single global SSE connection to /global/event for worktree status tracking.
-- Replaces per-directory subscriptions with one multiplexed stream that
-- routes events by the `directory` field in each envelope.

local M = {}

--- The active SSE connection handle (nil when disconnected).
local handle = nil

------------------------------------------------------------------------
-- Event parsing
------------------------------------------------------------------------

--- Parse a /global/event envelope into (directory, inner_event).
--- Returns nil, nil for malformed or sync-wrapper events.
--- @param raw table|nil  Raw decoded JSON from the SSE stream.
--- @return string|nil dir
--- @return table|nil event  Inner event with {type, properties, id}.
local function parse_global_event(raw)
  if type(raw) ~= "table" then return nil, nil end
  local payload = raw.payload
  if type(payload) ~= "table" then return nil, nil end
  -- Skip sync wrapper events (duplicates of real events)
  if payload.type == "sync" then return nil, nil end
  return raw.directory, payload -- directory is nil for server.connected
end

------------------------------------------------------------------------
-- Connection lifecycle
------------------------------------------------------------------------

--- Open a single SSE connection to /global/event.
--- Shuts down any existing connection first.
--- @param base_url string  Server base URL (e.g. "http://localhost:4096").
--- @param on_event fun(dir: string|nil, event: table)  Called for each parsed event.
function M.connect(base_url, on_event)
  M.disconnect()

  local ok, server_job = pcall(require, "opencode.server_job")
  if not ok or not server_job then return end

  local url = base_url .. "/global/event"

  handle = server_job.stream_api(url, "GET", nil, function(chunk)
    chunk = chunk:gsub("^data:%s*", "")
    local ok_json, raw = pcall(vim.json.decode, vim.trim(chunk))
    if not ok_json or not raw then return end
    local dir, event = parse_global_event(raw)
    if not event then return end
    vim.schedule(function()
      on_event(dir, event)
    end)
  end)
end

--- Ensure the global SSE connection is alive, reconnecting if needed.
--- @param base_url string
--- @param on_event fun(dir: string|nil, event: table)
function M.ensure_connection(base_url, on_event)
  local alive = handle
    and type(handle.is_running) == "function"
    and handle.is_running()
  if alive then return end
  M.connect(base_url, on_event)
end

--- Shut down the global SSE connection.
function M.disconnect()
  if not handle then return end
  if type(handle.shutdown) == "function" then
    pcall(handle.shutdown)
  end
  handle = nil
end

------------------------------------------------------------------------
-- Event processing
------------------------------------------------------------------------

--- Process a single SSE event and update state for the given directory.
--- Calls apply_fn(entry, event) and redraws if changed.
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

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  parse_global_event = parse_global_event,
}

return M
