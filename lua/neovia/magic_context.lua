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
--- @field snapshot table?   Last sidebar-snapshot response.
--- @field port number?      Discovered RPC server port.
--- @field session_id string? Active opencode session ID.

--- @type neovia.magic_context.State
local state = {
  snapshot = nil,
  port = nil,
  session_id = nil,
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
-- Port discovery
------------------------------------------------------------------------

--- Read the port number from a port file.
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

--- Discover and cache the RPC server port for the current directory.
--- @param dir string?
--- @return number?
local function discover_port(dir)
  dir = dir or vim.uv.cwd()
  if not dir then return nil end
  local path = port_file_path(dir)
  local port = read_port(path)
  if port then
    state.port = port
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

--- Fetch a sidebar-snapshot from the magic-context RPC server.
--- Synchronous (blocks briefly).
--- @param session_id string
--- @param dir string
--- @return table?
local function fetch_snapshot(session_id, dir)
  local port = state.port
  if not port then return nil end

  local url = string.format("http://127.0.0.1:%d/rpc/sidebar-snapshot", port)
  local body = vim.fn.json_encode({ sessionId = session_id, directory = dir })

  local ok, result = pcall(vim.system, {
    "curl", "-sf", "--max-time", "2",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", body,
    url,
  }, { text = true })

  if not ok or not result then return nil end
  local out = result:wait()
  if out.code ~= 0 or not out.stdout or out.stdout == "" then return nil end

  local decode_ok, data = pcall(vim.fn.json_decode, out.stdout)
  if not decode_ok or type(data) ~= "table" then return nil end

  return data
end

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

  local ok, result = pcall(vim.system, {
    "curl", "-sf", "--max-time", "2",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", body,
    url,
  }, { text = true })

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

  -- Ensure port is discovered
  if not state.port then
    discover_port(dir)
  end
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

  -- Fetch detail
  local detail = fetch_detail(session_id, dir)
  if not detail then
    vim.notify("magic-context: could not fetch status", vim.log.levels.WARN)
    return
  end

  -- Also update the cached snapshot from the detail (it's a superset)
  state.snapshot = detail

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
end

--- Show the full status-detail popup.
function M.show_popup()
  show_popup()
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
  resolve_session_id = resolve_session_id,
  fetch_snapshot = fetch_snapshot,
  define_highlights = define_highlights,

  get_port = function() return state.port end,
  set_port = function(p) state.port = p end,

  reset = function()
    initialised = false
    state = {
      snapshot = nil,
      port = nil,
      session_id = nil,
    }
  end,
}

return M
