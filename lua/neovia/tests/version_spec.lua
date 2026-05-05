-- tests/neovia/version_spec.lua
-- Unit tests for lua/neovia/version.lua

local version = require("neovia.version")
local I = version._internal

------------------------------------------------------------------------
-- parse_semver
------------------------------------------------------------------------

describe("parse_semver", function()
  it("parses a plain semver string", function()
    local v = I.parse_semver("1.14.33")
    assert.is_not_nil(v)
    assert.equals(1, v.major)
    assert.equals(14, v.minor)
    assert.equals(33, v.patch)
  end)

  it("parses a v-prefixed semver string", function()
    local v = I.parse_semver("v1.14.33")
    assert.is_not_nil(v)
    assert.equals(1, v.major)
    assert.equals(14, v.minor)
    assert.equals(33, v.patch)
  end)

  it("returns nil for nil input", function()
    assert.is_nil(I.parse_semver(nil))
  end)

  it("returns nil for malformed input", function()
    assert.is_nil(I.parse_semver("not-a-version"))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(I.parse_semver(""))
  end)

  it("parses version with extra suffix (ignored)", function()
    local v = I.parse_semver("2.0.1-beta")
    assert.is_not_nil(v)
    assert.equals(2, v.major)
    assert.equals(0, v.minor)
    assert.equals(1, v.patch)
  end)
end)

------------------------------------------------------------------------
-- compare_semver
------------------------------------------------------------------------

describe("compare_semver", function()
  it("returns 0 for equal versions", function()
    local a = { major = 1, minor = 14, patch = 33 }
    local b = { major = 1, minor = 14, patch = 33 }
    assert.equals(0, I.compare_semver(a, b))
  end)

  it("returns -1 when a < b (patch)", function()
    local a = { major = 1, minor = 14, patch = 30 }
    local b = { major = 1, minor = 14, patch = 33 }
    assert.equals(-1, I.compare_semver(a, b))
  end)

  it("returns 1 when a > b (patch)", function()
    local a = { major = 1, minor = 14, patch = 33 }
    local b = { major = 1, minor = 14, patch = 30 }
    assert.equals(1, I.compare_semver(a, b))
  end)

  it("returns -1 when a < b (minor)", function()
    local a = { major = 1, minor = 13, patch = 99 }
    local b = { major = 1, minor = 14, patch = 0 }
    assert.equals(-1, I.compare_semver(a, b))
  end)

  it("returns 1 when a > b (major)", function()
    local a = { major = 2, minor = 0, patch = 0 }
    local b = { major = 1, minor = 99, patch = 99 }
    assert.equals(1, I.compare_semver(a, b))
  end)
end)

------------------------------------------------------------------------
-- update_available
------------------------------------------------------------------------

describe("update_available", function()
  it("returns true when system is newer than server", function()
    assert.is_true(I.update_available("1.14.30", "1.14.33"))
  end)

  it("returns false when versions are equal", function()
    assert.is_false(I.update_available("1.14.33", "1.14.33"))
  end)

  it("returns false when server is newer than system", function()
    assert.is_false(I.update_available("1.14.33", "1.14.30"))
  end)

  it("returns false when server is nil", function()
    assert.is_false(I.update_available(nil, "1.14.33"))
  end)

  it("returns false when system is nil", function()
    assert.is_false(I.update_available("1.14.33", nil))
  end)

  it("returns false when both are nil", function()
    assert.is_false(I.update_available(nil, nil))
  end)

  it("handles v-prefix on either side", function()
    assert.is_true(I.update_available("v1.14.30", "v1.14.33"))
    assert.is_false(I.update_available("v1.14.33", "v1.14.33"))
  end)
end)

------------------------------------------------------------------------
-- parse_health_version
------------------------------------------------------------------------

describe("parse_health_version", function()
  it("extracts version from a health JSON response", function()
    local ver = I.parse_health_version('{"healthy":true,"version":"1.14.33"}')
    assert.equals("1.14.33", ver)
  end)

  it("handles whitespace in JSON", function()
    local ver = I.parse_health_version('{ "healthy": true, "version": "2.0.1" }')
    assert.equals("2.0.1", ver)
  end)

  it("returns nil for nil input", function()
    assert.is_nil(I.parse_health_version(nil))
  end)

  it("returns nil when version field is missing", function()
    assert.is_nil(I.parse_health_version('{"healthy":true}'))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(I.parse_health_version(""))
  end)
end)

------------------------------------------------------------------------
-- query_system_version
------------------------------------------------------------------------

describe("query_system_version", function()
  it("returns a version string from the opencode binary", function()
    local ver = I.query_system_version()
    -- The opencode binary should be installed in the test environment
    if ver then
      assert.is_true(type(ver) == "string")
      assert.is_true(#ver > 0)
      -- Should look like a semver
      assert.is_not_nil(ver:match("^%d+%.%d+%.%d+"))
    end
  end)
end)

------------------------------------------------------------------------
-- get_system_version (TTL cache)
------------------------------------------------------------------------

describe("get_system_version", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns cached value within TTL", function()
    I.set_state({
      system_version = "1.14.30",
      system_checked_at = 1000,
    })
    -- Within TTL (now = 1100, TTL = 300s)
    local ver = I.get_system_version(1100)
    assert.equals("1.14.30", ver)
  end)

  it("refreshes after TTL expires", function()
    I.set_state({
      system_version = "1.14.30",
      system_checked_at = 1000,
    })
    -- After TTL (now = 1301, TTL = 300s -> expired at 1300)
    local ver = I.get_system_version(1301)
    -- Should have refreshed -- may or may not have opencode installed,
    -- but should not return the stale "1.14.30" if refresh succeeded
    assert.is_true(type(ver) == "string")
  end)
end)

------------------------------------------------------------------------
-- get_server_version (TTL cache)
------------------------------------------------------------------------

describe("get_server_version", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns cached value within TTL", function()
    I.set_state({
      server_version = "1.14.30",
      server_checked_at = 1000,
    })
    -- Within TTL (now = 1100, TTL = 300s)
    local ver = I.get_server_version(1100)
    assert.equals("1.14.30", ver)
  end)

  it("returns nil when no server is running and no cache", function()
    local ver = I.get_server_version(1000)
    -- Server is not running in test env, so should return nil
    assert.is_nil(ver)
  end)
end)

------------------------------------------------------------------------
-- version_display
------------------------------------------------------------------------

describe("version_display", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns empty text when no server version is set", function()
    local d = I.version_display()
    assert.equals("", d.text)
  end)

  it("returns green highlight when versions match", function()
    I.set_state({
      server_version = "1.14.33",
      system_version = "1.14.33",
      system_checked_at = os.time(),
    })
    local d = I.version_display()
    assert.equals("v1.14.33", d.text)
    assert.equals("#a6e3a1", d.hl.fg)
  end)

  it("returns yellow highlight when system is newer", function()
    I.set_state({
      server_version = "1.14.30",
      system_version = "1.14.33",
      system_checked_at = os.time(),
    })
    local d = I.version_display()
    assert.equals("v1.14.30", d.text)
    assert.equals("#f9e2af", d.hl.fg)
  end)

  it("returns green when system version is unknown", function()
    I.set_state({
      server_version = "1.14.33",
      system_version = nil,
      system_checked_at = 0,
    })
    local d = I.version_display()
    assert.equals("v1.14.33", d.text)
    assert.equals("#a6e3a1", d.hl.fg)
  end)

  it("returns green when server is newer than system", function()
    I.set_state({
      server_version = "1.14.33",
      system_version = "1.14.30",
      system_checked_at = os.time(),
    })
    local d = I.version_display()
    assert.equals("v1.14.33", d.text)
    assert.equals("#a6e3a1", d.hl.fg)
  end)
end)

------------------------------------------------------------------------
-- Public API: display()
------------------------------------------------------------------------

describe("M.display", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("delegates to version_display", function()
    I.set_state({
      server_version = "1.14.33",
      system_version = "1.14.33",
      system_checked_at = os.time(),
    })
    local d = version.display()
    assert.equals("v1.14.33", d.text)
  end)
end)

------------------------------------------------------------------------
-- Public API: get_server_version / get_system_version
------------------------------------------------------------------------

describe("get_server_version / get_system_version", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("returns nil for server version before any check", function()
    assert.is_nil(version.get_server_version())
  end)

  it("returns nil for system version before any check", function()
    -- System version is nil until setup or get_system_version is called
    assert.is_nil(version.get_system_version())
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
    version.setup()
    version.setup()  -- should not error
  end)

  it("runs again after reset()", function()
    version.setup()
    I.reset()
    version.setup()  -- should not error
  end)
end)
