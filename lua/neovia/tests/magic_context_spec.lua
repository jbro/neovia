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

describe("format_memory", function()
  it("returns loaded/known format", function()
    local snap = { memoryBlockCount = 5, memoryCount = 12 }
    local result = I.format_memory(snap)
    assert.equals("5/12", result.text)
  end)

  it("handles zero counts", function()
    local snap = { memoryBlockCount = 0, memoryCount = 0 }
    local result = I.format_memory(snap)
    assert.equals("0/0", result.text)
  end)

  it("returns empty when snapshot is nil", function()
    local result = I.format_memory(nil)
    assert.equals("", result.text)
  end)
end)

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
-- format_bar
------------------------------------------------------------------------

describe("format_bar", function()
  it("returns a string of the requested width", function()
    local snap = {
      inputTokens = 1000,
      usagePercentage = 42,
      systemPromptTokens = 200,
      compartmentTokens = 100,
      factTokens = 50,
      memoryTokens = 50,
      conversationTokens = 300,
      toolCallTokens = 200,
      toolDefinitionTokens = 100,
    }
    local bar = I.format_bar(snap, 30)
    assert.is_string(bar)
    -- Should contain visible characters (the bar itself)
    assert.is_true(#bar > 0)
  end)

  it("returns empty string when snapshot is nil", function()
    local bar = I.format_bar(nil, 30)
    assert.equals("", bar)
  end)

  it("includes usage percentage text", function()
    local snap = {
      inputTokens = 1000,
      usagePercentage = 42,
      systemPromptTokens = 200,
      compartmentTokens = 100,
      factTokens = 50,
      memoryTokens = 50,
      conversationTokens = 300,
      toolCallTokens = 200,
      toolDefinitionTokens = 100,
    }
    local bar = I.format_bar(snap, 30)
    assert.is_truthy(bar:find("42%%"), "should contain usage percentage")
  end)
end)

------------------------------------------------------------------------
-- format_bar_lualine
------------------------------------------------------------------------

describe("format_bar_lualine", function()
  it("returns a progress bar with colored segments and total percentage", function()
    local snap = {
      inputTokens = 1000,
      usagePercentage = 42,
      systemPromptTokens = 200,
      compartmentTokens = 100,
      factTokens = 50,
      memoryTokens = 50,
      conversationTokens = 300,
      toolCallTokens = 200,
      toolDefinitionTokens = 100,
    }
    local bar = I.format_bar_lualine(snap, 25)
    assert.is_string(bar)
    -- Should contain bar highlight groups (background color)
    assert.is_truthy(bar:find("NeoviaMcBar_system"), "should contain system bar highlight")
    assert.is_truthy(bar:find("NeoviaMcBar_tool_calls"), "should contain tool_calls bar highlight")
    -- Should end with total percentage
    assert.is_truthy(bar:find("NeoviaMcUsage"), "should contain usage highlight")
    assert.is_truthy(bar:find("42%%%%"), "should contain total percentage")
  end)

  it("shows segment percentages inside wide enough segments", function()
    local snap = {
      inputTokens = 100,
      usagePercentage = 50,
      systemPromptTokens = 0,
      compartmentTokens = 0,
      factTokens = 0,
      memoryTokens = 0,
      conversationTokens = 0,
      toolCallTokens = 100,
      toolDefinitionTokens = 0,
    }
    -- Single segment at 100% of 20 chars = 20 chars wide
    local bar = I.format_bar_lualine(snap, 20)
    -- "100" should appear inside the segment
    assert.is_truthy(bar:find("100"), "should show percentage inside wide segment")
  end)

  it("omits segments with 0 fraction", function()
    local snap = {
      inputTokens = 1000,
      usagePercentage = 50,
      systemPromptTokens = 500,
      compartmentTokens = 0,
      factTokens = 0,
      memoryTokens = 0,
      conversationTokens = 0,
      toolCallTokens = 500,
      toolDefinitionTokens = 0,
    }
    local bar = I.format_bar_lualine(snap, 20)
    assert.is_truthy(bar:find("NeoviaMcBar_system"), "should include system")
    assert.is_truthy(bar:find("NeoviaMcBar_tool_calls"), "should include tool_calls")
    assert.is_falsy(bar:find("NeoviaMcBar_compartments"), "should omit compartments")
    assert.is_falsy(bar:find("NeoviaMcBar_facts"), "should omit facts")
  end)

  it("returns empty string when snapshot is nil", function()
    local bar = I.format_bar_lualine(nil, 20)
    assert.equals("", bar)
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

  it("starts with nil snapshot", function()
    assert.is_nil(I.get_snapshot())
  end)

  it("stores and retrieves a snapshot", function()
    local snap = { usagePercentage = 42, memoryCount = 10 }
    I.set_snapshot(snap)
    assert.same(snap, I.get_snapshot())
  end)

  it("clears snapshot on reset", function()
    I.set_snapshot({ usagePercentage = 42 })
    I.reset()
    assert.is_nil(I.get_snapshot())
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
-- Public API: context_bar / memory_display
------------------------------------------------------------------------

describe("M.context_bar", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns empty string when no snapshot is available", function()
    local bar = mc.context_bar(25)
    assert.equals("", bar)
  end)

  it("returns a bar when snapshot is set", function()
    I.set_snapshot({
      inputTokens = 1000,
      usagePercentage = 42,
      systemPromptTokens = 200,
      compartmentTokens = 100,
      factTokens = 50,
      memoryTokens = 50,
      conversationTokens = 300,
      toolCallTokens = 200,
      toolDefinitionTokens = 100,
    })
    local bar = mc.context_bar(25)
    assert.is_string(bar)
    assert.is_true(#bar > 0)
  end)
end)

describe("M.memory_display", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns empty text when no snapshot is available", function()
    local d = mc.memory_display()
    assert.equals("", d.text)
  end)

  it("returns loaded/known format when snapshot is set", function()
    I.set_snapshot({
      memoryBlockCount = 5,
      memoryCount = 12,
    })
    local d = mc.memory_display()
    assert.equals("5/12", d.text)
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
-- fetch_snapshot (mocked vim.system)
------------------------------------------------------------------------

describe("fetch_snapshot", function()
  local orig_system

  before_each(function()
    I.reset()
    orig_system = vim.system
  end)

  after_each(function()
    I.reset()
    vim.system = orig_system
  end)

  it("parses a successful JSON response into state.snapshot", function()
    local response = vim.fn.json_encode({
      usagePercentage = 42.5,
      inputTokens = 50000,
      systemPromptTokens = 8000,
      compartmentTokens = 3000,
      factTokens = 1500,
      memoryTokens = 2000,
      memoryCount = 20,
      memoryBlockCount = 15,
      conversationTokens = 25000,
      toolCallTokens = 8000,
      toolDefinitionTokens = 2500,
      historianRunning = false,
      compartmentInProgress = false,
      pendingOpsCount = 0,
      compartmentCount = 5,
      factCount = 12,
      sessionNoteCount = 0,
      readySmartNoteCount = 0,
      cacheTtl = "5m",
      lastDreamerRunAt = vim.NIL,
      projectIdentity = vim.NIL,
      sessionId = "ses_abc",
    })
    vim.system = function()
      return { wait = function() return { code = 0, stdout = response } end }
    end
    I.set_port(50442)
    I.fetch_snapshot("ses_abc", "/tmp/test")
    local snap = I.get_snapshot()
    assert.is_not_nil(snap)
    assert.equals(42.5, snap.usagePercentage)
    assert.equals(20, snap.memoryCount)
  end)

  it("does not update snapshot on curl failure", function()
    vim.system = function()
      return { wait = function() return { code = 7, stdout = "" } end }
    end
    I.set_port(50442)
    I.fetch_snapshot("ses_abc", "/tmp/test")
    assert.is_nil(I.get_snapshot())
  end)

  it("does not crash when port is nil", function()
    I.fetch_snapshot("ses_abc", "/tmp/test")
    assert.is_nil(I.get_snapshot())
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
-- Integration: live RPC server
------------------------------------------------------------------------

--- Helper: check if the magic-context RPC server is reachable.
--- Returns the port number or nil.
local function live_rpc_port()
  local dir = vim.uv.cwd()
  if not dir then return nil end
  local path = I.port_file_path(dir)
  local port = I.read_port(path)
  if not port then return nil end
  local ok, result = pcall(vim.system, {
    "curl", "-sf", "--max-time", "1",
    string.format("http://127.0.0.1:%d/health", port),
  }, { text = true })
  if not ok or not result then return nil end
  local out = result:wait()
  if out.code ~= 0 then return nil end
  return port
end

describe("integration: live RPC", function()
  local port = live_rpc_port()

  before_each(function()
    if not port then pending("RPC server not running") end
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

  it("fetch_snapshot populates state from live server", function()
    local dir = vim.uv.cwd()
    I.fetch_snapshot("integration-test", dir)
    local snap = I.get_snapshot()
    assert.is_not_nil(snap, "snapshot should be populated after fetch")
    assert.is_number(snap.usagePercentage)
    assert.is_number(snap.memoryCount)
  end)

  it("context_bar renders from live snapshot", function()
    local dir = vim.uv.cwd()
    I.fetch_snapshot("integration-test", dir)
    local bar = mc.context_bar(20)
    assert.is_string(bar)
    -- Should contain highlight groups (lualine format)
    assert.is_truthy(bar:find("%%#") or bar:find("%%"),
      "bar should contain statusline formatting: " .. bar)
  end)
end)
