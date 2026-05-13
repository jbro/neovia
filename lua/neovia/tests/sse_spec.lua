-- tests/neovia/sse_spec.lua
-- Unit tests for lua/neovia/sse.lua
-- Tests the global SSE connection model (/global/event endpoint).

local sse = require("neovia.sse")

describe("sse module", function()
  it("exists and returns a table", function()
    assert.is_table(sse)
  end)

  it("exposes connect, ensure_connection, disconnect, process_event", function()
    assert.is_function(sse.connect)
    assert.is_function(sse.ensure_connection)
    assert.is_function(sse.disconnect)
    assert.is_function(sse.process_event)
  end)
end)

--- Helper: make a fresh state entry.
local function make_entry(overrides)
  return vim.tbl_extend("force", {
    status = "unknown",
    branch = "main",
    pending_permissions = {},
    buffer_paths = {},
  }, overrides or {})
end

------------------------------------------------------------------------
-- parse_global_event (unwrap /global/event envelope)
------------------------------------------------------------------------

describe("parse_global_event", function()
  it("extracts directory and payload from a global event", function()
    local raw = {
      directory = "/proj/a",
      project = "abc123",
      payload = {
        id = "evt_1",
        type = "message.updated",
        properties = { sessionID = "s1" },
      },
    }
    local dir, event = sse._internal.parse_global_event(raw)
    assert.equals("/proj/a", dir)
    assert.equals("message.updated", event.type)
    assert.same({ sessionID = "s1" }, event.properties)
  end)

  it("returns nil directory for server.connected (no directory field)", function()
    local raw = {
      payload = {
        id = "evt_1",
        type = "server.connected",
        properties = {},
      },
    }
    local dir, event = sse._internal.parse_global_event(raw)
    assert.is_nil(dir)
    assert.equals("server.connected", event.type)
  end)

  it("returns nil for malformed events", function()
    local dir, event = sse._internal.parse_global_event({})
    assert.is_nil(dir)
    assert.is_nil(event)
  end)

  it("returns nil for nil input", function()
    local dir, event = sse._internal.parse_global_event(nil)
    assert.is_nil(dir)
    assert.is_nil(event)
  end)

  it("skips sync wrapper events (type=sync inside payload)", function()
    local raw = {
      directory = "/proj/a",
      project = "abc123",
      payload = {
        type = "sync",
        syncEvent = { type = "message.part.updated.1" },
      },
    }
    local dir, event = sse._internal.parse_global_event(raw)
    assert.is_nil(dir)
    assert.is_nil(event)
  end)
end)

------------------------------------------------------------------------
-- connect
------------------------------------------------------------------------

describe("connect", function()
  local saved_stream_api

  before_each(function()
    sse.disconnect()
    saved_stream_api = nil
  end)

  after_each(function()
    sse.disconnect()
    package.loaded["opencode.server_job"] = nil
  end)

  it("creates a connection to /global/event", function()
    local connected_url
    local mock_handle = {
      shutdown = function() end,
      is_running = function() return true end,
    }
    package.loaded["opencode.server_job"] = {
      stream_api = function(url, method, body, on_chunk)
        connected_url = url
        return mock_handle
      end,
    }

    sse.connect("http://localhost:4096", function() end)
    assert.equals("http://localhost:4096/global/event", connected_url)
  end)

  it("is a no-op when server_job is not available", function()
    package.loaded["opencode.server_job"] = nil
    -- should not error
    sse.connect("http://localhost:4096", function() end)
  end)

  it("shuts down existing connection before creating a new one", function()
    local shutdown_called = false
    local mock_handle_1 = {
      shutdown = function() shutdown_called = true end,
      is_running = function() return true end,
    }
    local mock_handle_2 = {
      shutdown = function() end,
      is_running = function() return true end,
    }
    local call_count = 0
    package.loaded["opencode.server_job"] = {
      stream_api = function(url, method, body, on_chunk)
        call_count = call_count + 1
        if call_count == 1 then return mock_handle_1 end
        return mock_handle_2
      end,
    }

    sse.connect("http://localhost:4096", function() end)
    sse.connect("http://localhost:4096", function() end)
    assert.is_true(shutdown_called)
  end)
end)

------------------------------------------------------------------------
-- disconnect
------------------------------------------------------------------------

describe("disconnect", function()
  after_each(function()
    package.loaded["opencode.server_job"] = nil
  end)

  it("shuts down the active connection", function()
    local shutdown_called = false
    local mock_handle = {
      shutdown = function() shutdown_called = true end,
      is_running = function() return true end,
    }
    package.loaded["opencode.server_job"] = {
      stream_api = function() return mock_handle end,
    }

    sse.connect("http://localhost:4096", function() end)
    sse.disconnect()
    assert.is_true(shutdown_called)
  end)

  it("is a no-op when not connected", function()
    sse.disconnect()  -- should not error
  end)

  it("tolerates shutdown errors", function()
    local mock_handle = {
      shutdown = function() error("already closed") end,
      is_running = function() return false end,
    }
    package.loaded["opencode.server_job"] = {
      stream_api = function() return mock_handle end,
    }

    sse.connect("http://localhost:4096", function() end)
    sse.disconnect()  -- should not error
  end)
end)

------------------------------------------------------------------------
-- ensure_connection
------------------------------------------------------------------------

describe("ensure_connection", function()
  after_each(function()
    sse.disconnect()
    package.loaded["opencode.server_job"] = nil
  end)

  it("connects when not connected", function()
    local connected = false
    local mock_handle = {
      shutdown = function() end,
      is_running = function() return true end,
    }
    package.loaded["opencode.server_job"] = {
      stream_api = function()
        connected = true
        return mock_handle
      end,
    }

    sse.ensure_connection("http://localhost:4096", function() end)
    assert.is_true(connected)
  end)

  it("reconnects when connection is dead", function()
    local connect_count = 0
    local alive = true
    package.loaded["opencode.server_job"] = {
      stream_api = function()
        connect_count = connect_count + 1
        return {
          shutdown = function() end,
          is_running = function() return alive end,
        }
      end,
    }

    sse.ensure_connection("http://localhost:4096", function() end)
    assert.equals(1, connect_count)

    alive = false -- simulate connection death
    sse.ensure_connection("http://localhost:4096", function() end)
    assert.equals(2, connect_count)
  end)

  it("does nothing when connection is alive", function()
    local connect_count = 0
    package.loaded["opencode.server_job"] = {
      stream_api = function()
        connect_count = connect_count + 1
        return {
          shutdown = function() end,
          is_running = function() return true end,
        }
      end,
    }

    sse.ensure_connection("http://localhost:4096", function() end)
    sse.ensure_connection("http://localhost:4096", function() end)
    assert.equals(1, connect_count)
  end)
end)

------------------------------------------------------------------------
-- process_event
------------------------------------------------------------------------

describe("process_event", function()
  before_each(function()
    vim.cmd.redrawstatus = function() end
    vim.cmd.redrawtabline = function() end
  end)

  it("calls apply_fn and triggers redraw on change", function()
    local state = {
      ["/proj/a"] = make_entry({ status = "idle", branch = "main" }),
    }
    local callback_called = false
    local function on_event(entry, event)
      callback_called = true
      entry.status = "responding"
      return true -- changed
    end

    sse.process_event(state, "/proj/a", { type = "test" }, on_event)
    assert.is_true(callback_called)
    assert.equals("responding", state["/proj/a"].status)
  end)

  it("does not redraw when apply_fn returns false", function()
    local redrawn = false
    vim.cmd.redrawstatus = function() redrawn = true end

    local state = {
      ["/proj/a"] = make_entry({ status = "idle", branch = "main" }),
    }

    sse.process_event(state, "/proj/a", { type = "test" }, function()
      return false
    end)
    assert.is_false(redrawn)
  end)

  it("is a no-op for unknown directories", function()
    local state = {}
    sse.process_event(state, "/nonexistent", { type = "test" }, function() end)
    assert.is_nil(state["/nonexistent"])
  end)
end)
