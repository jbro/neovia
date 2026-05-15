-- tests/neovia/magic_context_spec.lua
-- Unit tests for lua/neovia/magic_context.lua

local mc = require("neovia.magic_context")
local I = mc._internal

--- Extract plain text from a list of NuiLine objects.
--- @param lines table[]
--- @return string
local function lines_text(lines)
  return table.concat(vim.tbl_map(function(l) return l:content() end, lines), "\n")
end

------------------------------------------------------------------------
-- project_hash
------------------------------------------------------------------------

describe("project_hash", function()
  it("returns a 16-char hex string", function()
    local h = I.project_hash("/Users/jbr/Private/neovia")
    assert.is_string(h)
    assert.equals(16, #h)
    assert.is_truthy(h:match("^[0-9a-f]+$"), "expected hex chars only")
  end)

  it("strips trailing slash before hashing", function()
    local a = I.project_hash("/Users/jbr/Private/neovia/")
    local b = I.project_hash("/Users/jbr/Private/neovia")
    assert.equals(a, b)
  end)

  it("returns different hashes for different dirs", function()
    local a = I.project_hash("/tmp/project-a")
    local b = I.project_hash("/tmp/project-b")
    assert.are_not.equals(a, b)
  end)

  it("is deterministic", function()
    local a = I.project_hash("/foo/bar")
    local b = I.project_hash("/foo/bar")
    assert.equals(a, b)
  end)
end)

------------------------------------------------------------------------
-- port_file_path
------------------------------------------------------------------------

describe("port_file_path", function()
  it("builds the correct path from a directory", function()
    local path = I.port_file_path("/Users/jbr/Private/neovia")
    local hash = I.project_hash("/Users/jbr/Private/neovia")
    local expected = (vim.env.HOME or "") .. "/.local/share"
      .. "/cortexkit/magic-context/rpc/"
      .. hash
      .. "/port"
    assert.equals(expected, path)
  end)
end)

------------------------------------------------------------------------
-- format_memory
------------------------------------------------------------------------

------------------------------------------------------------------------
-- bar_segments
------------------------------------------------------------------------

describe("bar_segments", function()
  it("returns proportional segments for each token category", function()
    local snap = {
      inputTokens = 1000,
      systemPromptTokens = 200,
      compartmentTokens = 100,
      factTokens = 50,
      memoryTokens = 50,
      conversationTokens = 300,
      toolCallTokens = 200,
      toolDefinitionTokens = 100,
    }
    local segs = I.bar_segments(snap)
    assert.is_table(segs)
    -- Each segment has label, tokens, fraction
    for _, s in ipairs(segs) do
      assert.is_string(s.label)
      assert.is_number(s.tokens)
      assert.is_number(s.fraction)
    end
    -- Fractions sum to 1.0 (within floating point tolerance)
    local total = 0
    for _, s in ipairs(segs) do total = total + s.fraction end
    assert.is_true(math.abs(total - 1.0) < 0.01,
      "fractions should sum to ~1.0, got " .. total)
  end)

  it("handles zero inputTokens gracefully", function()
    local snap = {
      inputTokens = 0,
      systemPromptTokens = 0,
      compartmentTokens = 0,
      factTokens = 0,
      memoryTokens = 0,
      conversationTokens = 0,
      toolCallTokens = 0,
      toolDefinitionTokens = 0,
    }
    local segs = I.bar_segments(snap)
    assert.is_table(segs)
    for _, s in ipairs(segs) do
      assert.equals(0, s.fraction)
    end
  end)
end)

------------------------------------------------------------------------
-- format_popup_lines
------------------------------------------------------------------------

describe("format_popup_lines", function()
  it("returns a table of strings for a full detail snapshot", function()
    local detail = {
      sessionId = "ses_abc123",
      usagePercentage = 42.5,
      inputTokens = 50000,
      systemPromptTokens = 8000,
      compartmentCount = 5,
      compartmentTokens = 3000,
      factCount = 12,
      factTokens = 1500,
      memoryCount = 20,
      memoryBlockCount = 15,
      memoryTokens = 2000,
      conversationTokens = 25000,
      toolCallTokens = 8000,
      toolDefinitionTokens = 2500,
      pendingOpsCount = 2,
      historianRunning = false,
      compartmentInProgress = false,
      sessionNoteCount = 3,
      readySmartNoteCount = 1,
      cacheTtl = "4m 30s",
      lastDreamerRunAt = 1714800000,
      projectIdentity = "neovia",
      -- status-detail extras
      tagCounter = 45,
      activeTags = 30,
      droppedTags = 15,
      totalTags = 45,
      activeBytes = 120000,
      contextLimit = 200000,
      cacheTtlMs = 270000,
      cacheRemainingMs = 180000,
      cacheExpired = false,
      executeThreshold = 65,
      executeThresholdMode = "percentage",
      protectedTagCount = 20,
      nudgeInterval = 3,
      historyBudgetPercentage = 30,
      historyBlockTokens = 4500,
      compressionBudget = 60000,
      compressionUsage = "4500/60000 (7.5%)",
      lastResponseTime = 1714800500,
      lastNudgeTokens = 45000,
      lastNudgeBand = "gentle",
      lastTransformError = nil,
      isSubagent = false,
      pendingOps = {},
      nextNudgeAfter = 1714800600,
    }
    local lines = I.format_popup_lines(detail)
    assert.is_table(lines)
    assert.is_true(#lines > 0, "should produce output lines")
    -- Each element should be a NuiLine
    for _, line in ipairs(lines) do
      assert.is_function(line.content, "each line should be a NuiLine")
    end
  end)

  it("includes a color key section", function()
    local detail = {
      sessionId = "ses_abc123",
      usagePercentage = 42.5,
      inputTokens = 50000,
      systemPromptTokens = 8000,
      compartmentCount = 5,
      compartmentTokens = 3000,
      factCount = 12,
      factTokens = 1500,
      memoryCount = 20,
      memoryBlockCount = 15,
      memoryTokens = 2000,
      conversationTokens = 25000,
      toolCallTokens = 8000,
      toolDefinitionTokens = 2500,
      pendingOpsCount = 0,
      historianRunning = false,
      compartmentInProgress = false,
      sessionNoteCount = 0,
      readySmartNoteCount = 0,
      cacheTtl = "5m",
      lastDreamerRunAt = nil,
      projectIdentity = nil,
      tagCounter = 10,
      activeTags = 10,
      droppedTags = 0,
      totalTags = 10,
      activeBytes = 50000,
      contextLimit = 200000,
      cacheTtlMs = 300000,
      cacheRemainingMs = 300000,
      cacheExpired = false,
      executeThreshold = 65,
      executeThresholdMode = "percentage",
      protectedTagCount = 20,
      nudgeInterval = 3,
      historyBudgetPercentage = 30,
      historyBlockTokens = 3000,
      compressionBudget = nil,
      compressionUsage = nil,
      lastResponseTime = 0,
      lastNudgeTokens = 0,
      lastNudgeBand = "",
      lastTransformError = nil,
      isSubagent = false,
      pendingOps = {},
      nextNudgeAfter = 0,
    }
    local lines = I.format_popup_lines(detail)
    local text = lines_text(lines)
    -- Should contain a legend/key section explaining colors
    assert.is_truthy(text:find("System"), "should mention System Prompt category")
    assert.is_truthy(text:find("Conversation"), "should mention Conversation category")
    assert.is_truthy(text:find("Tool"), "should mention Tool category")
  end)

  it("handles lastDreamerRunAt as vim.NIL (JSON null)", function()
    local detail = {
      sessionId = "ses_abc123",
      usagePercentage = 0,
      inputTokens = 0,
      systemPromptTokens = 0,
      compartmentCount = 0,
      compartmentTokens = 0,
      factCount = 0,
      factTokens = 0,
      memoryCount = 0,
      memoryBlockCount = 0,
      memoryTokens = 0,
      conversationTokens = 0,
      toolCallTokens = 0,
      toolDefinitionTokens = 0,
      pendingOpsCount = 0,
      historianRunning = false,
      compartmentInProgress = false,
      sessionNoteCount = 0,
      readySmartNoteCount = 0,
      cacheTtl = "5m",
      lastDreamerRunAt = vim.NIL,
      projectIdentity = vim.NIL,
      tagCounter = 0,
      activeTags = 0,
      droppedTags = 0,
      totalTags = 0,
      activeBytes = 0,
      contextLimit = 0,
      cacheTtlMs = 300000,
      cacheRemainingMs = 0,
      cacheExpired = false,
      executeThreshold = 65,
      executeThresholdMode = "percentage",
      protectedTagCount = 20,
      nudgeInterval = 3,
      historyBudgetPercentage = 30,
      historyBlockTokens = 0,
      compressionBudget = vim.NIL,
      compressionUsage = vim.NIL,
      lastResponseTime = 0,
      lastNudgeTokens = 0,
      lastNudgeBand = "",
      lastTransformError = vim.NIL,
      isSubagent = false,
      pendingOps = {},
      nextNudgeAfter = 0,
    }
    local lines = I.format_popup_lines(detail)
    assert.is_table(lines)
    local text = lines_text(lines)
    assert.is_truthy(text:find("no runs yet"),
      "should show 'no runs yet' when lastDreamerRunAt is vim.NIL")
  end)

  it("shows historian as running when active", function()
    local detail = {
      sessionId = "ses_abc123",
      usagePercentage = 42.5,
      inputTokens = 50000,
      systemPromptTokens = 8000,
      compartmentCount = 5,
      compartmentTokens = 3000,
      factCount = 12,
      factTokens = 1500,
      memoryCount = 20,
      memoryBlockCount = 15,
      memoryTokens = 2000,
      conversationTokens = 25000,
      toolCallTokens = 8000,
      toolDefinitionTokens = 2500,
      pendingOpsCount = 0,
      historianRunning = true,
      compartmentInProgress = false,
      sessionNoteCount = 0,
      readySmartNoteCount = 0,
      cacheTtl = "5m",
      lastDreamerRunAt = nil,
      projectIdentity = nil,
      tagCounter = 10,
      activeTags = 10,
      droppedTags = 0,
      totalTags = 10,
      activeBytes = 50000,
      contextLimit = 200000,
      cacheTtlMs = 300000,
      cacheRemainingMs = 300000,
      cacheExpired = false,
      executeThreshold = 65,
      executeThresholdMode = "percentage",
      protectedTagCount = 20,
      nudgeInterval = 3,
      historyBudgetPercentage = 30,
      historyBlockTokens = 3000,
      compressionBudget = nil,
      compressionUsage = nil,
      lastResponseTime = 0,
      lastNudgeTokens = 0,
      lastNudgeBand = "",
      lastTransformError = nil,
      isSubagent = false,
      pendingOps = {},
      nextNudgeAfter = 0,
    }
    local lines = I.format_popup_lines(detail)
    local text = table.concat(vim.tbl_map(function(l) return l:content() end, lines), "\n")
    assert.is_truthy(text:lower():find("running"),
      "should indicate historian is running")
  end)

  it("returns NuiLine objects with highlights for context bar", function()
    local detail = {
      sessionId = "ses_abc123",
      usagePercentage = 61,
      inputTokens = 122500,
      systemPromptTokens = 6500,
      compartmentCount = 0,
      compartmentTokens = 0,
      factCount = 0,
      factTokens = 0,
      memoryCount = 3,
      memoryBlockCount = 3,
      memoryTokens = 140,
      conversationTokens = 3900,
      toolCallTokens = 92500,
      toolDefinitionTokens = 19500,
      pendingOpsCount = 34,
      historianRunning = false,
      compartmentInProgress = false,
      sessionNoteCount = 0,
      readySmartNoteCount = 0,
      cacheTtl = "5m",
      lastDreamerRunAt = nil,
      projectIdentity = nil,
      tagCounter = 125,
      activeTags = 118,
      droppedTags = 7,
      totalTags = 125,
      activeBytes = 122500,
      contextLimit = 200000,
      cacheTtlMs = 300000,
      cacheRemainingMs = 200000,
      cacheExpired = false,
      executeThreshold = 65,
      executeThresholdMode = "percentage",
      protectedTagCount = 20,
      nudgeInterval = 3,
      historyBudgetPercentage = 30,
      historyBlockTokens = 0,
      compressionBudget = nil,
      compressionUsage = nil,
      lastResponseTime = 0,
      lastNudgeTokens = 0,
      lastNudgeBand = "",
      lastTransformError = nil,
      isSubagent = false,
      pendingOps = {},
      nextNudgeAfter = 0,
    }
    local lines = I.format_popup_lines(detail)
    assert.is_table(lines)
    assert.is_true(#lines > 0)

    -- Every element should be a NuiLine (has :content() method)
    for i, line in ipairs(lines) do
      assert.is_function(line.content,
        string.format("line %d should be a NuiLine (missing :content())", i))
    end

    -- Context bar line (line index 2, after "Context Usage")
    -- should have multiple NuiText children with highlight groups
    local bar_line = lines[2]
    local bar_text = bar_line:content()
    assert.is_truthy(bar_text:find("\u{2588}"),
      "context bar should contain block characters")

    -- Color key swatches should have segment highlights
    local all_text = table.concat(
      vim.tbl_map(function(l) return l:content() end, lines), "\n")
    assert.is_truthy(all_text:find("Color Key"), "should have Color Key section")
    assert.is_truthy(all_text:find("System"), "color key should list System")
    assert.is_truthy(all_text:find("Tool Calls"), "color key should list Tool Calls")
  end)
end)

------------------------------------------------------------------------
-- State management
------------------------------------------------------------------------

describe("state management", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("stores and retrieves port", function()
    I.set_port(12345)
    assert.equals(12345, I.get_port())
  end)

  it("clears port on reset", function()
    I.set_port(12345)
    I.reset()
    assert.is_nil(I.get_port())
  end)
end)

------------------------------------------------------------------------
-- setup / reset
------------------------------------------------------------------------

describe("setup", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("is idempotent", function()
    mc.setup()
    mc.setup()  -- should not error
  end)

  it("runs again after reset()", function()
    mc.setup()
    I.reset()
    mc.setup()  -- should not error
  end)
end)

------------------------------------------------------------------------
-- read_port
------------------------------------------------------------------------

describe("read_port", function()
  local tmpdir

  before_each(function()
    I.reset()
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
  end)

  after_each(function()
    I.reset()
    vim.fn.delete(tmpdir, "rf")
  end)

  it("reads port number from a file", function()
    local path = tmpdir .. "/port"
    local fd = assert(io.open(path, "w"))
    fd:write("50442\n")
    fd:close()
    local port = I.read_port(path)
    assert.equals(50442, port)
  end)

  it("returns nil for non-existent file", function()
    local port = I.read_port(tmpdir .. "/nonexistent")
    assert.is_nil(port)
  end)

  it("returns nil for non-numeric content", function()
    local path = tmpdir .. "/port"
    local fd = assert(io.open(path, "w"))
    fd:write("not-a-number\n")
    fd:close()
    local port = I.read_port(path)
    assert.is_nil(port)
  end)

  it("trims whitespace around port number", function()
    local path = tmpdir .. "/port"
    local fd = assert(io.open(path, "w"))
    fd:write("  12345  \n")
    fd:close()
    local port = I.read_port(path)
    assert.equals(12345, port)
  end)
end)

------------------------------------------------------------------------
-- resolve_session_id
------------------------------------------------------------------------

describe("resolve_session_id", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
    package.loaded["opencode.state"] = nil
  end)

  it("reads from opencode.state.active_session.id", function()
    package.loaded["opencode.state"] = {
      active_session = { id = "ses_test123" },
    }
    local id = I.resolve_session_id()
    assert.equals("ses_test123", id)
  end)

  it("returns nil when opencode.state is not loaded", function()
    package.loaded["opencode.state"] = nil
    local id = I.resolve_session_id()
    assert.is_nil(id)
  end)

  it("returns nil when active_session is nil", function()
    package.loaded["opencode.state"] = {}
    local id = I.resolve_session_id()
    assert.is_nil(id)
  end)
end)

------------------------------------------------------------------------
-- fmt_tokens
------------------------------------------------------------------------

describe("fmt_tokens", function()
  it("formats thousands with K suffix", function()
    assert.equals("50.0K", I.fmt_tokens(50000))
    assert.equals("1.5K", I.fmt_tokens(1500))
    assert.equals("100.0K", I.fmt_tokens(100000))
  end)

  it("formats sub-1000 as plain integers", function()
    assert.equals("500", I.fmt_tokens(500))
    assert.equals("0", I.fmt_tokens(0))
    assert.equals("999", I.fmt_tokens(999))
  end)

  it("formats exactly 1000", function()
    assert.equals("1.0K", I.fmt_tokens(1000))
  end)
end)

------------------------------------------------------------------------
-- define_highlights
------------------------------------------------------------------------

describe("define_highlights", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("creates highlight groups for each segment color", function()
    I.define_highlights()
    -- Check that a few key highlight groups exist
    local sys_hl = vim.api.nvim_get_hl(0, { name = "NeoviaMc_system", link = false })
    assert.is_not_nil(sys_hl.fg, "NeoviaMc_system should have fg color")

    local conv_hl = vim.api.nvim_get_hl(0, { name = "NeoviaMc_conversation", link = false })
    assert.is_not_nil(conv_hl.fg, "NeoviaMc_conversation should have fg color")
  end)

  it("is idempotent", function()
    I.define_highlights()
    I.define_highlights()  -- should not error
  end)
end)

------------------------------------------------------------------------
-- segment_palette_keys (semantic colour mapping)
------------------------------------------------------------------------

describe("segment_palette_keys", function()
  it("maps system to blue", function()
    assert.equals("blue", I.segment_palette_keys.system)
  end)

  it("maps compartments to sky", function()
    assert.equals("sky", I.segment_palette_keys.compartments)
  end)

  it("maps facts to teal", function()
    assert.equals("teal", I.segment_palette_keys.facts)
  end)

  it("maps memories to green", function()
    assert.equals("green", I.segment_palette_keys.memories)
  end)

  it("maps conversation to yellow", function()
    assert.equals("yellow", I.segment_palette_keys.conversation)
  end)

  it("maps tool_calls to peach", function()
    assert.equals("peach", I.segment_palette_keys.tool_calls)
  end)

  it("maps tool_defs to red", function()
    assert.equals("red", I.segment_palette_keys.tool_defs)
  end)
end)

------------------------------------------------------------------------
-- resolve_segment_colors (palette-based colour resolution)
------------------------------------------------------------------------

describe("resolve_segment_colors", function()
  it("returns a table with all seven segment keys", function()
    local colors = I.resolve_segment_colors()
    assert.is_string(colors.system)
    assert.is_string(colors.compartments)
    assert.is_string(colors.facts)
    assert.is_string(colors.memories)
    assert.is_string(colors.conversation)
    assert.is_string(colors.tool_calls)
    assert.is_string(colors.tool_defs)
  end)

  it("returns hex colour strings", function()
    local colors = I.resolve_segment_colors()
    for _, colour in pairs(colors) do
      assert.is_truthy(colour:match("^#%x+$"), "expected hex colour, got: " .. colour)
    end
  end)

  it("uses catppuccin palette colours when available", function()
    local ok, palettes = pcall(require, "catppuccin.palettes")
    if not ok then return end -- skip if not installed
    local palette = palettes.get_palette()
    local colors = I.resolve_segment_colors()
    assert.equals(palette.blue, colors.system)
    assert.equals(palette.sky, colors.compartments)
    assert.equals(palette.teal, colors.facts)
    assert.equals(palette.green, colors.memories)
    assert.equals(palette.yellow, colors.conversation)
    assert.equals(palette.peach, colors.tool_calls)
    assert.equals(palette.red, colors.tool_defs)
  end)

  it("returns fallback colours when catppuccin is not loaded", function()
    local colors = I.resolve_segment_colors()
    assert.is_truthy(colors.system:match("^#%x+$"))
  end)
end)

------------------------------------------------------------------------
-- Integration: live RPC server
------------------------------------------------------------------------

--- Poll for the magic-context RPC port to become available and healthy.
--- The opencode server loads magic-context as a plugin which starts its
--- own RPC server; the port file may appear slightly after the opencode
--- health endpoint is ready.
--- @param timeout_ms number  Maximum time to wait.
--- @return number?  port, or nil on timeout.
local function await_rpc_port(timeout_ms)
  local dir = vim.uv.cwd()
  if not dir then return nil end
  local port
  vim.wait(timeout_ms, function()
    port = I.discover_port(dir)
    if not port then return false end
    local ok, result = pcall(vim.system, {
      "curl", "-sf", "--max-time", "1",
      string.format("http://127.0.0.1:%d/health", port),
    }, { text = true })
    if not ok or not result then return false end
    return result:wait().code == 0
  end, 200)
  return port
end

describe("integration: live RPC", function()
  local port
  local server_started = false

  before_each(function()
    if not port then
      local ok_srv, srv = pcall(require, "neovia.server")
      if not ok_srv then pending("neovia.server not available") end

      -- Fail if a server is already running — we must not hijack or
      -- tear down a server we did not start.
      local pre = srv.status()
      assert.is_not.equals("running", pre.state,
        "an opencode server is already running (pid " .. tostring(pre.pid)
        .. "); stop it before running integration tests")

      -- Start our own server.
      local srv_port, err = srv.ensure_running()
      if not srv_port then pending("could not start opencode server: " .. (err or "unknown")) end
      server_started = true

      -- Wait for the magic-context RPC port to become healthy.
      port = await_rpc_port(15000)
      if not port then pending("magic-context RPC server did not start within 15s") end
    end
    I.reset()
    I.set_port(port)
  end)

  after_each(function()
    I.reset()
  end)

  it("port file exists at the cortexkit storage path", function()
    local dir = vim.uv.cwd()
    assert.is_not_nil(dir)
    local path = I.port_file_path(dir)
    assert.is_truthy(path:find("cortexkit/magic%-context/rpc/"),
      "port file path should use cortexkit storage: " .. path)
    local p = I.read_port(path)
    assert.is_number(p)
    assert.is_true(p > 0 and p <= 65535, "port should be valid: " .. tostring(p))
  end)

  it("health endpoint responds with ok and pid", function()
    local ok, result = pcall(vim.system, {
      "curl", "-sf", "--max-time", "2",
      string.format("http://127.0.0.1:%d/health", port),
    }, { text = true })
    assert.is_true(ok)
    local out = result:wait()
    assert.equals(0, out.code)
    local decode_ok, data = pcall(vim.fn.json_decode, out.stdout)
    assert.is_true(decode_ok)
    assert.equals(true, data.ok)
    assert.is_number(data.pid)
  end)

  it("sidebar-snapshot returns expected fields", function()
    local dir = vim.uv.cwd()
    local body = vim.fn.json_encode({ sessionId = "integration-test", directory = dir })
    local ok, result = pcall(vim.system, {
      "curl", "-sf", "--max-time", "2",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", body,
      string.format("http://127.0.0.1:%d/rpc/sidebar-snapshot", port),
    }, { text = true })
    assert.is_true(ok)
    local out = result:wait()
    assert.equals(0, out.code, "curl should succeed; got: " .. (out.stderr or ""))
    local decode_ok, snap = pcall(vim.fn.json_decode, out.stdout)
    assert.is_true(decode_ok, "response should be valid JSON")
    -- Validate required fields from the snapshot schema
    assert.is_number(snap.usagePercentage)
    assert.is_number(snap.inputTokens)
    assert.is_number(snap.systemPromptTokens)
    assert.is_number(snap.compartmentCount)
    assert.is_number(snap.factCount)
    assert.is_number(snap.memoryCount)
    assert.is_number(snap.memoryBlockCount)
    assert.is_number(snap.compartmentTokens)
    assert.is_number(snap.conversationTokens)
    assert.is_number(snap.toolCallTokens)
    assert.is_number(snap.toolDefinitionTokens)
    assert.is_boolean(snap.historianRunning)
    assert.is_boolean(snap.compartmentInProgress)
  end)

  it("status-detail returns superset of snapshot fields", function()
    local dir = vim.uv.cwd()
    local body = vim.fn.json_encode({ sessionId = "integration-test", directory = dir })
    local ok, result = pcall(vim.system, {
      "curl", "-sf", "--max-time", "2",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", body,
      string.format("http://127.0.0.1:%d/rpc/status-detail", port),
    }, { text = true })
    assert.is_true(ok)
    local out = result:wait()
    assert.equals(0, out.code)
    local decode_ok, detail = pcall(vim.fn.json_decode, out.stdout)
    assert.is_true(decode_ok, "response should be valid JSON")
    -- Snapshot fields (superset)
    assert.is_number(detail.usagePercentage)
    assert.is_number(detail.inputTokens)
    assert.is_number(detail.memoryCount)
    -- Detail-only fields
    assert.is_number(detail.activeTags)
    assert.is_number(detail.droppedTags)
    assert.is_number(detail.totalTags)
    assert.is_number(detail.executeThreshold)
    assert.is_string(detail.executeThresholdMode)
    assert.is_number(detail.protectedTagCount)
    assert.is_boolean(detail.cacheExpired)
    assert.is_number(detail.cacheTtlMs)
  end)

  -- Tear down: stop the server we started for integration tests.
  -- Plenary has no after_all, so this runs as the final "test".
  it("teardown: stop opencode server", function()
    if server_started then
      local ok_srv, srv = pcall(require, "neovia.server")
      if ok_srv then srv.stop() end
      server_started = false
    end
  end)

end)
