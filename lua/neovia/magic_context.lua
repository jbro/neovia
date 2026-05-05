-- lua/neovia/magic_context.lua
-- Magic Context integration: RPC client for context/memory status.
--
-- Discovers the magic-context RPC server port from its on-disk state,
-- fetches sidebar-snapshot and status-detail data, and exposes it for
-- lualine components and a floating popup.

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
  init_timer = nil,
}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

--- Base directory for magic-context RPC port files.
--- magic-context stores under ~/.local/share/cortexkit/magic-context/.
local RPC_BASE = (vim.env.HOME or "") .. "/.local/share/cortexkit/magic-context/rpc/"

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

--- Build a progress bar for the statusline with colored segments.
--- Each segment is a colored block region; if wide enough the segment's
--- percentage is printed inside. Total percentage follows the bar.
--- @param snap table?
--- @param width number  Character width of the bar (not counting the total label)
--- @return string
local function format_bar_lualine(snap, width)
  if not snap then return "" end

  local segs = bar_segments(snap)
  local pct = math.floor(snap.usagePercentage or 0)
  local bar_width = width or 25

  local parts = {}
  local used = 0
  for i, seg in ipairs(segs) do
    local seg_width = math.floor(seg.fraction * bar_width + 0.5)
    if i == #segs then seg_width = bar_width - used end
    if seg_width > 0 then
      local hl = "NeoviaMcBar_" .. seg.label:lower():gsub(" ", "_")
      local seg_pct = math.floor(seg.fraction * 100 + 0.5)
      local label = tostring(seg_pct)
      if #label <= seg_width then
        -- Center the label inside the segment
        local pad_left = math.floor((seg_width - #label) / 2)
        local pad_right = seg_width - #label - pad_left
        local fill = string.rep(" ", pad_left) .. label .. string.rep(" ", pad_right)
        table.insert(parts, string.format("%%#%s#%s", hl, fill))
      else
        -- Too narrow for the label; just fill with blocks
        table.insert(parts, string.format("%%#%s#%s", hl, string.rep(" ", seg_width)))
      end
    end
    used = used + seg_width
  end

  -- Total percentage after the bar
  table.insert(parts, string.format("%%#NeoviaMcUsage# %d%%%%", pct))
  return " " .. table.concat(parts)
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
  local dark_bg = 0x1a1b26  -- dark background for text on colored bars
  for key, color in pairs(segment_colors) do
    local c = hex_to_int(color)
    -- Foreground-only (popup text labels)
    vim.api.nvim_set_hl(0, "NeoviaMc_" .. key, { fg = c })
    -- Background bar segments (statusline bar with text overlay)
    vim.api.nvim_set_hl(0, "NeoviaMcBar_" .. key, { fg = dark_bg, bg = c, bold = true })
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

  local augroup = vim.api.nvim_create_augroup("NeoviaMagicContext", { clear = true })

  -- Re-define highlights on colorscheme change
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = define_highlights,
  })

  -- Retry initial fetch until we get a snapshot (opencode may not be connected yet)
  state.init_timer = vim.uv.new_timer()
  if state.init_timer then
    local attempts = 0
    state.init_timer:start(2000, 3000, vim.schedule_wrap(function()
      attempts = attempts + 1
      M.refresh()
      if state.snapshot or attempts >= 10 then
        if state.init_timer and not state.init_timer:is_closing() then
          state.init_timer:stop()
          state.init_timer:close()
        end
        state.init_timer = nil
      end
    end))
  end
end

--- Get context bar for lualine (progress bar with colored segments).
--- @param width number?  Bar width in characters (default 25)
--- @return string
function M.context_bar(width)
  return format_bar_lualine(state.snapshot, width or 25)
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
    if state.init_timer and not state.init_timer:is_closing() then
      state.init_timer:stop()
      state.init_timer:close()
    end
    state = {
      snapshot = nil,
      port = nil,
      session_id = nil,
      init_timer = nil,
    }
  end,
}

return M
