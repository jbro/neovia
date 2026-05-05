-- lua/neovia/magic_context.lua
-- Magic Context integration: RPC client for context/memory status.
--
-- Discovers the magic-context RPC server port from its on-disk state,
-- fetches sidebar-snapshot and status-detail data, and exposes it for
-- lualine components and a floating popup.

local M = {}

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
--- Uses opencode's own data directory (not Neovim's stdpath("data"),
--- which varies with the config name).
local RPC_BASE = (vim.env.HOME or "") .. "/.local/share"
  .. "/opencode/storage/plugin/magic-context/rpc/"

------------------------------------------------------------------------
-- Segment colors (authoritative source for bar/popup)
------------------------------------------------------------------------

--- @type table<string, string>
local segment_colors = {
  system       = "#7aa2f7", -- blue
  compartments = "#7dcfff", -- cyan
  facts        = "#73daca", -- teal
  memories     = "#9ece6a", -- green
  conversation = "#e0af68", -- yellow
  tool_calls   = "#ff9e64", -- orange
  tool_defs    = "#f7768e", -- red/pink
}

M.segment_colors = segment_colors

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
-- Memory display
------------------------------------------------------------------------

--- Format the memory count display (loaded/known).
--- @param snap table?
--- @return { text: string, hl: table }
local function format_memory(snap)
  if not snap then return { text = "", hl = {} } end
  local loaded = snap.memoryBlockCount or 0
  local known = snap.memoryCount or 0
  return { text = string.format("%d/%d", loaded, known), hl = {} }
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
-- Format bar (plain text with highlight groups for popup)
------------------------------------------------------------------------

--- Build a text progress bar with usage percentage.
--- Uses block characters to represent proportional segments.
--- @param snap table?
--- @param width number  Character width of the bar area
--- @return string
local function format_bar(snap, width)
  if not snap then return "" end

  local segs = bar_segments(snap)
  local pct = snap.usagePercentage or 0
  local label = string.format(" %d%%", math.floor(pct))
  local bar_width = width - #label

  if bar_width < 1 then
    return string.format("%d%%", math.floor(pct))
  end

  local chars = {}
  local used = 0
  for i, seg in ipairs(segs) do
    local seg_width = math.floor(seg.fraction * bar_width + 0.5)
    -- Last segment takes the remainder to avoid rounding gaps
    if i == #segs then
      seg_width = bar_width - used
    end
    if seg_width > 0 then
      for _ = 1, seg_width do
        table.insert(chars, "\u{2588}") -- full block
      end
    end
    used = used + seg_width
  end

  return table.concat(chars) .. label
end

------------------------------------------------------------------------
-- Format bar (lualine statusline with highlight groups)
------------------------------------------------------------------------

--- Build a statusline-format bar string with highlight group references.
--- @param snap table?
--- @param width number
--- @return string
local function format_bar_lualine(snap, width)
  if not snap then return "" end

  local segs = bar_segments(snap)
  local pct = snap.usagePercentage or 0
  local label = string.format(" %d%%", math.floor(pct))
  local bar_width = width - #label

  if bar_width < 1 then
    return string.format("%%#NeoviaMcUsage#%d%%%%", math.floor(pct))
  end

  local parts = {}
  local used = 0
  for i, seg in ipairs(segs) do
    local seg_width = math.floor(seg.fraction * bar_width + 0.5)
    if i == #segs then
      seg_width = bar_width - used
    end
    if seg_width > 0 then
      local hl_name = "NeoviaMc_" .. seg.label:lower():gsub(" ", "_")
      table.insert(parts, "%#" .. hl_name .. "#" .. string.rep("\u{2588}", seg_width))
    end
    used = used + seg_width
  end

  table.insert(parts, "%#NeoviaMcUsage#" .. label)
  return table.concat(parts)
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
--- @param detail table
--- @return string[]
local function format_popup_lines(detail)
  local lines = {}
  local function add(line) table.insert(lines, line) end

  -- Header
  add("Magic Context Status")
  add(string.rep("\u{2500}", 40))
  add("")

  -- Context bar
  add("Context Usage")
  add(format_bar(detail, 40))
  add(string.format("  %s / %s tokens (%d%%)",
    fmt_tokens(detail.inputTokens or 0),
    fmt_tokens(detail.contextLimit or 0),
    math.floor(detail.usagePercentage or 0)))
  add("")

  -- Token breakdown
  add("Token Breakdown")
  local segs = bar_segments(detail)
  for _, seg in ipairs(segs) do
    if seg.tokens > 0 then
      add(string.format("  %s  %s (%d%%)",
        seg.label,
        fmt_tokens(seg.tokens),
        math.floor(seg.fraction * 100 + 0.5)))
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
  if detail.cacheRemainingMs then
    add(string.format("  Remaining: %ds", math.floor(detail.cacheRemainingMs / 1000)))
  end
  add("")

  -- Tags
  add("Tags")
  add(string.format("  Active: %d  Dropped: %d  Total: %d  Protected: %d",
    detail.activeTags or 0, detail.droppedTags or 0,
    detail.totalTags or 0, detail.protectedTagCount or 0))
  if detail.pendingOpsCount and detail.pendingOpsCount > 0 then
    add(string.format("  Pending ops: %d", detail.pendingOpsCount))
  end
  add("")

  -- Thresholds
  add("Thresholds")
  add(string.format("  Execute: %d%% (%s)",
    detail.executeThreshold or 0, detail.executeThresholdMode or "?"))
  add(string.format("  History budget: %d%%", detail.historyBudgetPercentage or 0))
  if detail.compressionUsage then
    add(string.format("  Compression: %s", detail.compressionUsage))
  end
  add("")

  -- Dreamer
  if detail.lastDreamerRunAt then
    add(string.format("Dreamer: last run %s", os.date("%Y-%m-%d %H:%M", detail.lastDreamerRunAt)))
  else
    add("Dreamer: no runs yet")
  end
  add("")

  -- Color key
  add("Color Key")
  add(string.rep("\u{2500}", 40))
  for _, seg in ipairs(segs) do
    add(string.format("  \u{2588}\u{2588} %s", seg.label))
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
--- Synchronous (blocks briefly). Updates state.snapshot on success.
--- @param session_id string
--- @param dir string
local function fetch_snapshot(session_id, dir)
  local port = state.port
  if not port then return end

  local url = string.format("http://127.0.0.1:%d/rpc/sidebar-snapshot", port)
  local body = vim.fn.json_encode({ sessionId = session_id, directory = dir })

  local ok, result = pcall(vim.system, {
    "curl", "-sf", "--max-time", "2",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", body,
    url,
  }, { text = true })

  if not ok or not result then return end
  local out = result:wait()
  if out.code ~= 0 or not out.stdout or out.stdout == "" then return end

  local decode_ok, data = pcall(vim.fn.json_decode, out.stdout)
  if not decode_ok or type(data) ~= "table" then return end

  state.snapshot = data
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

--- Define highlight groups used by the context bar and popup.
local function define_highlights()
  for key, color in pairs(segment_colors) do
    local hl_name = "NeoviaMc_" .. key
    vim.api.nvim_set_hl(0, hl_name, { fg = hex_to_int(color) })
  end
  -- Usage percentage text inherits normal fg
  vim.api.nvim_set_hl(0, "NeoviaMcUsage", {})
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

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
    title = " Magic Context ",
    title_pos = "center",
  })

  -- Close on q or Escape
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })
end

------------------------------------------------------------------------
-- Refresh (called from SSE hook)
------------------------------------------------------------------------

--- Refresh the snapshot data. Called when assistant finishes a message.
--- Runs asynchronously to avoid blocking.
function M.refresh()
  local dir = vim.uv.cwd()
  if not dir then return end

  if not state.port then
    discover_port(dir)
  end
  if not state.port then return end

  local session_id = resolve_session_id()
  if not session_id then return end

  vim.system({
    "curl", "-sf", "--max-time", "2",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", vim.fn.json_encode({ sessionId = session_id, directory = dir }),
    string.format("http://127.0.0.1:%d/rpc/sidebar-snapshot", state.port),
  }, { text = true }, function(out)
    if out.code ~= 0 or not out.stdout or out.stdout == "" then return end
    local decode_ok, data = pcall(vim.fn.json_decode, out.stdout)
    if not decode_ok or type(data) ~= "table" then return end
    vim.schedule(function()
      state.snapshot = data
      vim.cmd.redrawstatus()
    end)
  end)
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Initialise the module. Idempotent.
function M.setup()
  if initialised then return end
  initialised = true

  define_highlights()

  -- Re-define highlights on colorscheme change
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("NeoviaMagicContext", { clear = true }),
    callback = define_highlights,
  })
end

--- Get context bar for lualine (statusline-format string).
--- @param width number?  Character width (default 20)
--- @return string
function M.context_bar(width)
  return format_bar_lualine(state.snapshot, width or 20)
end

--- Get memory display info for lualine.
--- @return { text: string, hl: table }
function M.memory_display()
  return format_memory(state.snapshot)
end

--- Show the full status-detail popup.
function M.show_popup()
  show_popup()
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  project_hash = project_hash,
  port_file_path = port_file_path,
  format_memory = format_memory,
  bar_segments = bar_segments,
  format_bar = format_bar,
  format_bar_lualine = format_bar_lualine,
  format_popup_lines = format_popup_lines,
  fmt_tokens = fmt_tokens,
  read_port = read_port,
  resolve_session_id = resolve_session_id,
  fetch_snapshot = fetch_snapshot,
  define_highlights = define_highlights,

  get_snapshot = function() return state.snapshot end,
  set_snapshot = function(s) state.snapshot = s end,
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
