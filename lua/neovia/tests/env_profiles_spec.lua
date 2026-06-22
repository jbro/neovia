-- tests/neovia/env_profiles_spec.lua
-- Unit tests for the named-profile support in lua/neovia/env.lua

local env = require("neovia.env")
local I = env._internal

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function clear_test_env()
  vim.env.TEST_PROF_KEY = nil
  vim.env.TEST_PROF_URL = nil
  vim.env.TEST_PROF_SHARED = nil
end

local function rm_state()
  os.remove(I.profile_state_file())
end

------------------------------------------------------------------------
-- shape detection
------------------------------------------------------------------------

describe("is_profiles_config", function()
  it("returns false for a flat list of specs", function()
    assert.is_false(I.is_profiles_config({
      { name = "A", value = "x" },
      { name = "B", value = "y" },
    }))
  end)

  it("returns true for a config with a profiles table", function()
    assert.is_true(I.is_profiles_config({
      profiles = { dev = {}, prod = {} },
    }))
  end)

  it("returns false for an empty table", function()
    assert.is_false(I.is_profiles_config({}))
  end)
end)

------------------------------------------------------------------------
-- setup with profiles
------------------------------------------------------------------------

describe("setup with profiles", function()
  before_each(function()
    I.reset()
    rm_state()
    clear_test_env()
  end)

  after_each(function()
    I.reset()
    rm_state()
    clear_test_env()
  end)

  local function config()
    return {
      shared = {
        { name = "TEST_PROF_SHARED", value = "shared-val" },
      },
      default = "dev",
      profiles = {
        dev = {
          { name = "TEST_PROF_KEY", value = "dev-key" },
          { name = "TEST_PROF_URL", value = "https://dev.example" },
        },
        prod = {
          { name = "TEST_PROF_KEY", value = "prod-key" },
          { name = "TEST_PROF_URL", value = "https://prod.example" },
        },
      },
    }
  end

  it("loads shared specs and the default profile", function()
    env.setup(config())

    assert.equals("shared-val", vim.env.TEST_PROF_SHARED)
    assert.equals("dev-key", vim.env.TEST_PROF_KEY)
    assert.equals("https://dev.example", vim.env.TEST_PROF_URL)
  end)

  it("reports the active profile name", function()
    env.setup(config())
    assert.equals("dev", env.active_profile())
  end)

  it("lists profile names sorted", function()
    env.setup(config())
    assert.same({ "dev", "prod" }, env.profiles())
  end)

  it("falls back to the first sorted profile when no default is set", function()
    local c = config()
    c.default = nil
    env.setup(c)
    assert.equals("dev", env.active_profile())
  end)

  it("prefers a persisted selection over the default", function()
    -- Persist "prod" before setup
    env.setup(config())
    env.select_profile("prod")
    I.reset()
    clear_test_env()

    env.setup(config())
    assert.equals("prod", env.active_profile())
    assert.equals("prod-key", vim.env.TEST_PROF_KEY)
  end)

  it("ignores a persisted selection that no longer exists", function()
    I.save_profile("ghost")
    env.setup(config())
    assert.equals("dev", env.active_profile())
  end)
end)

------------------------------------------------------------------------
-- select_profile
------------------------------------------------------------------------

describe("select_profile", function()
  before_each(function()
    I.reset()
    rm_state()
    clear_test_env()
  end)

  after_each(function()
    I.reset()
    rm_state()
    clear_test_env()
  end)

  local function config()
    return {
      default = "dev",
      profiles = {
        dev = { { name = "TEST_PROF_KEY", value = "dev-key" } },
        prod = { { name = "TEST_PROF_KEY", value = "prod-key" } },
      },
    }
  end

  it("switches the active profile and updates vim.env", function()
    env.setup(config())
    local ok, err = env.select_profile("prod")

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("prod", env.active_profile())
    assert.equals("prod-key", vim.env.TEST_PROF_KEY)
  end)

  it("persists the selection across reset", function()
    env.setup(config())
    env.select_profile("prod")
    assert.equals("prod", I.load_profile())
  end)

  it("returns an error for an unknown profile", function()
    env.setup(config())
    local ok, err = env.select_profile("nope")

    assert.is_false(ok)
    assert.is_not_nil(err)
    -- active profile unchanged
    assert.equals("dev", env.active_profile())
  end)

  it("returns an error when not in profiles mode", function()
    env.setup({ { name = "TEST_PROF_KEY", value = "x" } })
    local ok, err = env.select_profile("anything")
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)
end)

------------------------------------------------------------------------
-- apply_active (re-read persisted selection and re-apply to vim.env)
------------------------------------------------------------------------

describe("apply_active", function()
  before_each(function()
    I.reset()
    rm_state()
    clear_test_env()
  end)

  after_each(function()
    I.reset()
    rm_state()
    clear_test_env()
  end)

  local function config()
    return {
      shared = { { name = "TEST_PROF_SHARED", value = "shared-val" } },
      default = "dev",
      profiles = {
        dev = { { name = "TEST_PROF_KEY", value = "dev-key" } },
        prod = { { name = "TEST_PROF_KEY", value = "prod-key" } },
      },
    }
  end

  it("adopts a profile selected by another instance", function()
    -- This instance starts on the default (dev).
    env.setup(config())
    assert.equals("dev-key", vim.env.TEST_PROF_KEY)

    -- Another instance persists "prod" out-of-band.
    I.save_profile("prod")

    -- Re-applying re-reads the persisted selection and updates vim.env.
    local ok = env.apply_active()
    assert.is_true(ok)
    assert.equals("prod", env.active_profile())
    assert.equals("prod-key", vim.env.TEST_PROF_KEY)
    assert.equals("shared-val", vim.env.TEST_PROF_SHARED)
  end)

  it("returns false when not in profiles mode", function()
    env.setup({ { name = "TEST_PROF_KEY", value = "x" } })
    assert.is_false(env.apply_active())
  end)
end)

------------------------------------------------------------------------
-- resolve_active
------------------------------------------------------------------------

describe("resolve_active", function()
  before_each(function()
    rm_state()
  end)

  after_each(function()
    rm_state()
  end)

  local cfg = {
    default = "dev",
    profiles = { dev = {}, prod = {}, staging = {} },
  }

  it("returns the persisted profile when it still exists", function()
    I.save_profile("prod")
    assert.equals("prod", I.resolve_active(cfg))
  end)

  it("returns the default when no selection is persisted", function()
    assert.equals("dev", I.resolve_active(cfg))
  end)

  it("ignores a persisted profile that no longer exists", function()
    I.save_profile("ghost")
    assert.equals("dev", I.resolve_active(cfg))
  end)

  it("falls back to the first sorted name with no default or selection", function()
    assert.equals("dev", I.resolve_active({ profiles = { dev = {}, prod = {} } }))
  end)
end)

------------------------------------------------------------------------
-- legacy flat list still works
------------------------------------------------------------------------

describe("setup with legacy flat list", function()
  before_each(function()
    I.reset()
    clear_test_env()
  end)

  after_each(function()
    I.reset()
    clear_test_env()
  end)

  it("loads specs and reports no profiles", function()
    env.setup({
      { name = "TEST_PROF_KEY", value = "flat" },
    })

    assert.equals("flat", vim.env.TEST_PROF_KEY)
    assert.same({}, env.profiles())
    assert.is_nil(env.active_profile())
  end)
end)
