-- lua/neovia/magic_context.lua
-- Magic Context integration: RPC client for context/memory status.
--
-- Discovers the magic-context RPC server port from its on-disk state,
-- fetches status-detail data, and displays it in a floating popup.

local M = {}

local ok_nui_line, NuiLine = pcall(require, "nui.line")
if not ok_nui_line then NuiLine = nil end

local initialised = false

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

--- @class neovia.magic_context.State
--- @field port number?      Discovered RPC server port.
--- @field token string?     Auth token from per-PID port file.
--- @field session_id string? Active opencode session ID.
--- @field last_notification_id number Last acked notification ID for RPC drain.
--- @field last_drain_at number  Monotonic ms timestamp of last drain call.
--- @field sse_cb_id string?  Registered worktree SSE activity callback ID.

--- @type neovia.magic_context.State
local state = {
  port = nil,
  token = nil,
  session_id = nil,
  last_notification_id = 0,
  last_drain_at = 0,
  sse_cb_id = nil,
}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

--- Base directory for magic-context RPC port files.
--- magic-context stores under ~/.local/share/cortexkit/magic-context/.
local RPC_BASE = (vim.env.HOME or "") .. "/.local/share/cortexkit/magic-context/rpc/"

------------------------------------------------------------------------
-- Segment colors (derived from catppuccin palette when available)
------------------------------------------------------------------------

--- Semantic mapping from segment name to catppuccin palette key.
--- @type table<string, string>
local segment_palette_keys = {
  system       = "blue",
  compartments = "sky",
  facts        = "teal",
  memories     = "green",
  conversation = "yellow",
  tool_calls   = "peach",
  tool_defs    = "red",
}

--- Fallback hex values (catppuccin mocha) used when the palette is not loaded.
--- @type table<string, string>
local fallback_segment_colors = {
  blue   = "#89b4fa",
  sky    = "#89dceb",
  teal   = "#94e2d5",
  green  = "#a6e3a1",
  yellow = "#f9e2af",
  peach  = "#fab387",
  red    = "#f38ba8",
}

--- Resolve segment colours from catppuccin palette, falling back to mocha defaults.
--- @return table<string, string>
local function resolve_segment_colors()
  local ok, palettes = pcall(require, "catppuccin.palettes")
  local palette = ok and palettes.get_palette() or nil
  local colors = {}
  for segment, key in pairs(segment_palette_keys) do
    colors[segment] = (palette and palette[key]) or fallback_segment_colors[key]
  end
  return colors
end

--- @type table<string, string>
local segment_colors = resolve_segment_colors()



------------------------------------------------------------------------
-- Project hash
------------------------------------------------------------------------

--- Compute the project hash (SHA256, first 16 hex chars).
--- Magic-context uses SHA256(directory) with trailing slashes stripped.
--- @param dir string
--- @return string
local function project_hash(dir)
  local clean = dir:gsub("/$", "")
  local hash = vim.fn.sha256(clean)
  return hash:sub(1, 16)
end

------------------------------------------------------------------------
-- Port file path
------------------------------------------------------------------------

--- Build the port file path for a given directory.
--- @param dir string
--- @return string
local function port_file_path(dir)
  return RPC_BASE .. project_hash(dir) .. "/port"
end

------------------------------------------------------------------------
-- Bar segments
------------------------------------------------------------------------

--- Compute proportional segments from a snapshot's token breakdown.
--- @param snap table
--- @return table[]  Array of {label, tokens, fraction, color}
local function bar_segments(snap)
  local total = snap.inputTokens or 0
  local categories = {
    { label = "System",       tokens = snap.systemPromptTokens or 0,   color = segment_colors.system },
    { label = "Compartments", tokens = snap.compartmentTokens or 0,    color = segment_colors.compartments },
    { label = "Facts",        tokens = snap.factTokens or 0,           color = segment_colors.facts },
    { label = "Memories",     tokens = snap.memoryTokens or 0,         color = segment_colors.memories },
    { label = "Conversation", tokens = snap.conversationTokens or 0,   color = segment_colors.conversation },
    { label = "Tool Calls",   tokens = snap.toolCallTokens or 0,      color = segment_colors.tool_calls },
    { label = "Tool Defs",    tokens = snap.toolDefinitionTokens or 0, color = segment_colors.tool_defs },
  }
  for _, seg in ipairs(categories) do
    seg.fraction = total > 0 and (seg.tokens / total) or 0
  end
  return categories
end

------------------------------------------------------------------------
-- Format popup lines
------------------------------------------------------------------------

--- Format a human-readable number with K suffix for thousands.
--- @param n number
--- @return string
local function fmt_tokens(n)
  if n >= 1000 then
    return string.format("%.1fK", n / 1000)
  end
  return tostring(math.floor(n))
end

--- Build the full popup content from a status-detail response.
--- Returns NuiLine objects so that the popup can render with highlights.
--- @param detail table
--- @return table[]  Array of NuiLine objects
local function format_popup_lines(detail)
  local Line = NuiLine
  if not Line then return {} end

  local pad = "  "
  local lines = {}
  local function add(line)
    if type(line) == "string" then
      local l = Line()
      l:append(pad .. line)
      table.insert(lines, l)
    else
      -- Prepend padding to NuiLine objects
      local padded = Line()
      padded:append(pad)
      padded:append(line)
      table.insert(lines, padded)
    end
  end


  -- Context bar (colored segments)
  add("Context Usage")

  local segs = bar_segments(detail)
  local pct = detail.usagePercentage or 0
  local bar_width = 40
  local bar_line = Line()
  local used = 0
  for i, seg in ipairs(segs) do
    local seg_width = math.floor(seg.fraction * bar_width + 0.5)
    if i == #segs then seg_width = bar_width - used end
    if seg_width > 0 then
      local hl = "NeoviaMc_" .. seg.label:lower():gsub(" ", "_")
      bar_line:append(string.rep("\u{2588}", seg_width), hl)
    end
    used = used + seg_width
  end
  add(bar_line)

  add(string.format("  %s / %s tokens (%d%%)",
    fmt_tokens(detail.inputTokens or 0),
    fmt_tokens(detail.contextLimit or 0),
    math.floor(pct)))
  add("")

  -- Token breakdown (colored labels)
  local breakdown_header = Line()
  breakdown_header:append("Token Breakdown", "Title")
  add(breakdown_header)
  for _, seg in ipairs(segs) do
    if seg.tokens > 0 then
      local l = Line()
      l:append("  ")
      local hl = "NeoviaMc_" .. seg.label:lower():gsub(" ", "_")
      l:append(seg.label, hl)
      l:append(string.format("  %s (%d%%)",
        fmt_tokens(seg.tokens),
        math.floor(seg.fraction * 100 + 0.5)))
      add(l)
    end
  end
  add("")

  -- Historian
  local hist_status = detail.historianRunning and "running" or "idle"
  if detail.compartmentInProgress then hist_status = "running (compartment)" end
  add("Historian: " .. hist_status)
  add(string.format("  Compartments: %d  Facts: %d",
    detail.compartmentCount or 0, detail.factCount or 0))
  add("")

  -- Memories
  add(string.format("Memories: %d loaded / %d known",
    detail.memoryBlockCount or 0, detail.memoryCount or 0))
  add("")

  -- Notes
  add(string.format("Notes: %d session, %d smart (ready)",
    detail.sessionNoteCount or 0, detail.readySmartNoteCount or 0))
  add("")

  -- Cache
  add("Cache")
  add(string.format("  TTL: %s  Expired: %s",
    detail.cacheTtl or "?",
    detail.cacheExpired and "yes" or "no"))
  if type(detail.cacheRemainingMs) == "number" then
    add(string.format("  Remaining: %ds", math.floor(detail.cacheRemainingMs / 1000)))
  end
  add("")

  -- Tags
  add("Tags")
  add(string.format("  Active: %d  Dropped: %d",
    detail.activeTags or 0, detail.droppedTags or 0))
  add(string.format("  Total: %d  Protected: %d",
    detail.totalTags or 0, detail.protectedTagCount or 0))
  if type(detail.pendingOpsCount) == "number" and detail.pendingOpsCount > 0 then
    add(string.format("  Pending ops: %d", detail.pendingOpsCount))
  end
  add("")

  -- Thresholds
  add("Thresholds")
  add(string.format("  Execute: %d%% (%s)",
    detail.executeThreshold or 0, detail.executeThresholdMode or "?"))
  add(string.format("  History budget: %d%%", detail.historyBudgetPercentage or 0))
  if type(detail.compressionUsage) == "string" then
    add(string.format("  Compression: %s", detail.compressionUsage))
  end
  add("")

  -- Dreamer
  if type(detail.lastDreamerRunAt) == "number" then
    add(string.format("Dreamer: last run %s", os.date("%Y-%m-%d %H:%M", detail.lastDreamerRunAt)))
  else
    add("Dreamer: no runs yet")
  end
  add("")

  -- Color key (colored swatches)
  local key_header = Line()
  key_header:append("Color Key", "Title")
  add(key_header)
  add(string.rep("\u{2500}", 40))
  for _, seg in ipairs(segs) do
    local l = Line()
    local hl = "NeoviaMc_" .. seg.label:lower():gsub(" ", "_")
    l:append("  \u{2588}\u{2588}", hl)
    l:append(" " .. seg.label)
    add(l)
  end

  return lines
end

------------------------------------------------------------------------
-- Notification drain (SSE-driven)
------------------------------------------------------------------------
-- Drains pending notifications from the magic-context RPC server.
-- Called on every SSE event via on_sse_activity(), throttled to at most
-- once per DRAIN_INTERVAL_MS.  This keeps isTuiConnected() = true inside
-- magic-context so that sendIgnoredMessage() uses the toast path (which
-- succeeds harmlessly on the opencode HTTP API) instead of injecting
-- phantom user messages via prompt({noReply:true}).

--- @type integer  Minimum ms between drain calls (must be < 3000 TUI_CONNECTED_WINDOW_MS).
local DRAIN_INTERVAL_MS = 2000

--- Override for the actual drain function (for testing).
--- @type fun()|nil
local drain_fn_override = nil

--- Clock function — returns monotonic ms.  Overridable for tests.
--- @type fun(): number
local clock_fn = function() return vim.uv.now() end

--- Process notification messages returned from a drain call.
--- Advances last_notification_id and surfaces toast payloads via vim.notify.
--- @param messages table[]
local function handle_notifications(messages)
  for _, msg in ipairs(messages) do
    if msg.id and msg.id > state.last_notification_id then
      state.last_notification_id = msg.id
    end
    if msg.type == "toast" and type(msg.payload) == "table" then
      local text = msg.payload.message or msg.payload.title or ""
      if text ~= "" then
        vim.notify(text, vim.log.levels.INFO)
      end
    end
  end
end

--- Build auth header arguments for curl when a token is available.
--- @return string[]  Empty table or {"-H", "Authorization: Bearer <token>"}
local function auth_headers()
  if not state.token then return {} end
  return { "-H", "Authorization: Bearer " .. state.token }
end

--- Fire one async drain to the pending-notifications RPC endpoint.
local function drain_notifications()
  local port = state.port
  if not port then return end

  local url = string.format("http://127.0.0.1:%d/rpc/pending-notifications", port)
  local body = vim.fn.json_encode({ lastReceivedId = state.last_notification_id })
  local auth = auth_headers()

  local cmd = {
    "curl", "-sf", "--max-time", "1",
    "-X", "POST",
    "-H", "Content-Type: application/json",
  }
  for _, v in ipairs(auth) do table.insert(cmd, v) end
  table.insert(cmd, "-d")
  table.insert(cmd, body)
  table.insert(cmd, url)

  pcall(vim.system, cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 or not out.stdout or out.stdout == "" then return end
      local ok, data = pcall(vim.fn.json_decode, out.stdout)
      if not ok or type(data) ~= "table" then return end
      local messages = data.messages
      if type(messages) == "table" and #messages > 0 then
        handle_notifications(messages)
      end
    end)
  end)
end

--- Called on every SSE event.  Throttles actual drain to DRAIN_INTERVAL_MS.
local function on_sse_activity()
  if not state.port then return end
  local now = clock_fn()
  if (now - state.last_drain_at) < DRAIN_INTERVAL_MS then return end
  state.last_drain_at = now
  local fn = drain_fn_override or drain_notifications
  fn()
end

------------------------------------------------------------------------
-- Port discovery
------------------------------------------------------------------------

--- Read a plain port number from a legacy port file.
--- @param path string
--- @return number?
local function read_port(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local content = fd:read("*a")
  fd:close()
  if not content then return nil end
  local port = tonumber(vim.trim(content))
  return port
end

--- Read port from a per-PID JSON port file (port-<pid>.json).
--- Returns (port, pid, token) or (nil, nil, nil).
--- @param path string
--- @return number?, number?, string?
local function read_pid_port(path)
  local fd = io.open(path, "r")
  if not fd then return nil, nil, nil end
  local content = fd:read("*a")
  fd:close()
  if not content then return nil, nil, nil end
  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then return nil, nil, nil end
  local token = type(data.token) == "string" and data.token or nil
  return tonumber(data.port), tonumber(data.pid), token
end

--- Check if a PID is still running.
--- @param pid number
--- @return boolean
local function pid_alive(pid)
  -- signal 0: check existence without actually signalling
  local ok = vim.uv.kill(pid, 0)
  return ok == 0
end

--- Discover the RPC server port for the current directory.
--- Prefers per-PID port files (port-<pid>.json) with a live process over
--- the legacy plain port file which can go stale across server restarts.
--- @param dir string?
--- @return number?
local function discover_port(dir)
  dir = dir or vim.uv.cwd()
  if not dir then return nil end

  local rpc_dir = RPC_BASE .. project_hash(dir)

  -- Scan for per-PID port files; pick the newest one with a running process.
  local handle = vim.uv.fs_scandir(rpc_dir)
  if handle then
    local best_port, best_token, best_time = nil, nil, 0
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if (ftype == "file" or ftype == nil) and name:match("^port%-%d+%.json$") then
        local full = rpc_dir .. "/" .. name
        local port, pid, token = read_pid_port(full)
        if port and pid and pid_alive(pid) then
          local stat = vim.uv.fs_stat(full)
          local mtime = stat and stat.mtime and stat.mtime.sec or 0
          if mtime > best_time then
            best_port = port
            best_token = token
            best_time = mtime
          end
        end
      end
    end
    if best_port then
      state.port = best_port
      state.token = best_token
      return best_port
    end
  end

  -- Fallback: legacy plain port file (no token available).
  local path = port_file_path(dir)
  local port = read_port(path)
  if port then
    state.port = port
    state.token = nil
  end
  return port
end

------------------------------------------------------------------------
-- Session ID resolution
------------------------------------------------------------------------

--- Resolve the current opencode session ID.
--- Reads from opencode.nvim's runtime state.
--- @return string?
local function resolve_session_id()
  local ok, oc_state = pcall(require, "opencode.state")
  if not ok or not oc_state then return nil end
  if not oc_state.active_session then return nil end
  return oc_state.active_session.id
end

------------------------------------------------------------------------
-- RPC fetch
------------------------------------------------------------------------

--- Fetch status-detail from the magic-context RPC server.
--- Synchronous (blocks briefly). Returns the detail table or nil.
--- @param session_id string
--- @param dir string
--- @return table?
local function fetch_detail(session_id, dir)
  local port = state.port
  if not port then return nil end

  local url = string.format("http://127.0.0.1:%d/rpc/status-detail", port)
  local body = vim.fn.json_encode({ sessionId = session_id, directory = dir })
  local auth = auth_headers()

  local cmd = {
    "curl", "-sf", "--max-time", "2",
    "-X", "POST",
    "-H", "Content-Type: application/json",
  }
  for _, v in ipairs(auth) do table.insert(cmd, v) end
  table.insert(cmd, "-d")
  table.insert(cmd, body)
  table.insert(cmd, url)

  local ok, result = pcall(vim.system, cmd, { text = true })

  if not ok or not result then return nil end
  local out = result:wait()
  if out.code ~= 0 or not out.stdout or out.stdout == "" then return nil end

  local decode_ok, data = pcall(vim.fn.json_decode, out.stdout)
  if not decode_ok or type(data) ~= "table" then return nil end

  return data
end

------------------------------------------------------------------------
-- Highlight definitions
------------------------------------------------------------------------

--- Hex string to integer for nvim_set_hl.
--- @param hex string  e.g. "#7aa2f7"
--- @return integer
local function hex_to_int(hex)
  return tonumber(hex:sub(2), 16)
end

--- Define highlight groups used by the popup.
--- Refreshes segment colours from the active catppuccin palette.
local function define_highlights()
  local fresh = resolve_segment_colors()
  for k, v in pairs(fresh) do segment_colors[k] = v end

  for key, color in pairs(segment_colors) do
    vim.api.nvim_set_hl(0, "NeoviaMc_" .. key, { fg = hex_to_int(color) })
  end
end

------------------------------------------------------------------------
-- Popup window
------------------------------------------------------------------------

--- Show a floating popup with full status-detail.
local function show_popup()
  local dir = vim.uv.cwd()
  if not dir then return end

  -- Always re-read the port file (tiny I/O) so we pick up server restarts.
  discover_port(dir)
  if not state.port then
    vim.notify("magic-context: RPC server not found", vim.log.levels.WARN)
    return
  end

  -- Resolve session ID
  local session_id = resolve_session_id()
  if not session_id then
    vim.notify("magic-context: no active session", vim.log.levels.WARN)
    return
  end

  -- Fetch detail; retry once with a fresh port in case the server restarted.
  local detail = fetch_detail(session_id, dir)
  if not detail then
    local old_port = state.port
    discover_port(dir)
    if state.port and state.port ~= old_port then
      detail = fetch_detail(session_id, dir)
    end
  end
  if not detail then
    vim.notify(string.format(
      "magic-context: could not fetch status (port=%s, session=%s, dir=%s)",
      tostring(state.port), session_id, dir
    ), vim.log.levels.WARN)
    return
  end

  -- Build lines
  local lines = format_popup_lines(detail)
  if #lines == 0 then
    vim.notify("magic-context: nui.nvim not available", vim.log.levels.WARN)
    return
  end

  -- Create buffer and render NuiLine objects with highlights
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace("neovia_mc_popup")
  for i, line in ipairs(lines) do
    line:render(buf, ns, i)
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Window dimensions
  local width = 50
  local height = math.min(#lines, math.floor(vim.o.lines * 0.8))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Magic Context (q to close) ",
    title_pos = "center",
  })

  -- Close on q or Escape
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Initialise the module. Idempotent.
function M.setup()
  if initialised then return end
  initialised = true

  define_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("NeoviaMagicContext", { clear = true }),
    callback = define_highlights,
  })

  -- Register notification drain as a worktree SSE activity callback.
  local ok_wt, wt = pcall(require, "neovia.worktree")
  if ok_wt then
    state.sse_cb_id = wt.register_sse_activity_cb(on_sse_activity)
  end
end

--- Show the full status-detail popup.
function M.show_popup()
  show_popup()
end

--- Signal SSE activity to trigger a throttled notification drain.
--- Called via the worktree SSE activity callback registered in setup().
function M.on_sse_activity()
  on_sse_activity()
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  segment_palette_keys = segment_palette_keys,
  resolve_segment_colors = resolve_segment_colors,
  project_hash = project_hash,
  port_file_path = port_file_path,
  bar_segments = bar_segments,
  format_popup_lines = format_popup_lines,
  fmt_tokens = fmt_tokens,
  read_port = read_port,
  read_pid_port = read_pid_port,
  pid_alive = pid_alive,
  discover_port = discover_port,
  resolve_session_id = resolve_session_id,
  define_highlights = define_highlights,
  handle_notifications = handle_notifications,
  on_sse_activity = on_sse_activity,

  get_port = function() return state.port end,
  set_port = function(p) state.port = p end,
  get_token = function() return state.token end,
  set_token = function(t) state.token = t end,
  get_rpc_base = function() return RPC_BASE end,
  set_rpc_base = function(b) RPC_BASE = b end,
  get_last_notification_id = function() return state.last_notification_id end,

  --- Override the drain function for testing (nil = use real drain).
  --- @param fn fun()|nil
  set_drain_fn = function(fn) drain_fn_override = fn end,

  --- Advance the drain clock by ms (for testing throttle behaviour).
  --- @param ms number
  advance_drain_clock = function(ms)
    state.last_drain_at = state.last_drain_at - ms
  end,

  reset = function()
    initialised = false
    drain_fn_override = nil
    -- Unregister SSE callback before clearing state.
    if state.sse_cb_id then
      local ok_wt, wt = pcall(require, "neovia.worktree")
      if ok_wt then wt.unregister_sse_activity_cb(state.sse_cb_id) end
    end
    state = {
      port = nil,
      token = nil,
      session_id = nil,
      last_notification_id = 0,
      last_drain_at = 0,
      sse_cb_id = nil,
    }
  end,
}

return M
