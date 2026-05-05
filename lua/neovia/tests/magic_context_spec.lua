-- tests/neovia/magic_context_spec.lua
-- Unit tests for lua/neovia/magic_context.lua

local mc = require("neovia.magic_context")
local I = mc._internal

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
      .. "/opencode/storage/plugin/magic-context/rpc/"
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
  it("returns a statusline-format string with highlight groups", function()
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
    local bar = I.format_bar_lualine(snap, 20)
    assert.is_string(bar)
    -- Should contain statusline highlight group references
    assert.is_truthy(bar:find("%%#"), "should contain highlight groups")
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
    -- Each element should be a string
    for _, line in ipairs(lines) do
      assert.is_string(line)
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
    local text = table.concat(lines, "\n")
    -- Should contain a legend/key section explaining colors
    assert.is_truthy(text:find("System"), "should mention System Prompt category")
    assert.is_truthy(text:find("Conversation"), "should mention Conversation category")
    assert.is_truthy(text:find("Tool"), "should mention Tool category")
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
      compartmentInProgress = true,
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
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:lower():find("running"),
      "should indicate historian is running")
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
    local bar = mc.context_bar(20)
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
    local bar = mc.context_bar(20)
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
