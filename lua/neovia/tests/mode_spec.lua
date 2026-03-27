-- tests/neovia/mode_spec.lua
-- Unit tests for lua/neovia/mode.lua

local mode = require("neovia.mode")
local I = mode._internal

------------------------------------------------------------------------
-- should_lock predicate
------------------------------------------------------------------------

describe("should_lock", function()
  it("returns true for a normal buffer", function()
    assert.is_true(I.should_lock({ buftype = "", filetype = "" }))
  end)

  it("returns false for terminal buftype", function()
    assert.is_false(I.should_lock({ buftype = "terminal", filetype = "" }))
  end)

  it("returns false for help buftype", function()
    assert.is_false(I.should_lock({ buftype = "help", filetype = "" }))
  end)

  it("returns false for quickfix buftype", function()
    assert.is_false(I.should_lock({ buftype = "quickfix", filetype = "" }))
  end)

  it("returns false for nofile buftype", function()
    assert.is_false(I.should_lock({ buftype = "nofile", filetype = "" }))
  end)

  it("returns false for prompt buftype", function()
    assert.is_false(I.should_lock({ buftype = "prompt", filetype = "" }))
  end)

  it("returns false for gitcommit filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "gitcommit" }))
  end)

  it("returns false for fugitive filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "fugitive" }))
  end)

  it("returns false for neo-tree filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "neo-tree" }))
  end)

  it("returns false for opencode_output filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "opencode_output" }))
  end)

  it("returns false for DiffviewFiles filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "DiffviewFiles" }))
  end)

  it("returns false for DiffviewFileHistory filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "DiffviewFileHistory" }))
  end)
end)

------------------------------------------------------------------------
-- toggle logic
------------------------------------------------------------------------

describe("toggle", function()
  before_each(function()
    I.reset()
    I.setup({ auto_relock = true })
  end)

  it("unlocks a locked buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    -- Lock it first
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    I.toggle(buf)

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("locks an unlocked buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    I.toggle(buf)

    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("tracks unlocked buffers", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    I.toggle(buf)

    assert.is_true(I.is_unlocked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("untracks buffer when relocked", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    I.toggle(buf) -- unlock
    I.toggle(buf) -- relock

    assert.is_false(I.is_unlocked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- is_locked
------------------------------------------------------------------------

describe("is_locked", function()
  before_each(function()
    I.reset()
    I.setup({ auto_relock = true })
  end)

  it("returns true for a locked normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    assert.is_true(mode.is_locked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for an unlocked normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    assert.is_false(mode.is_locked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns false for a special buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"

    assert.is_false(mode.is_locked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- lualine_mode
------------------------------------------------------------------------

describe("lualine_mode", function()
  before_each(function()
    I.reset()
    I.setup({ auto_relock = true })
  end)

  it("returns READ-ONLY for a read-only buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    local result = I.lualine_mode(buf)
    assert.equals("READ-ONLY", result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns vim mode for an unlocked buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    local result = I.lualine_mode(buf)
    -- In test harness we're in normal mode
    assert.equals("NORMAL", result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns vim mode for special buffers", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"

    local result = I.lualine_mode(buf)
    assert.equals("NORMAL", result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- auto_relock setting
------------------------------------------------------------------------

describe("auto_relock", function()
  before_each(function()
    I.reset()
  end)

  it("defaults to true", function()
    I.setup({})
    assert.is_true(I.get_auto_relock())
  end)

  it("respects explicit true", function()
    I.setup({ auto_relock = true })
    assert.is_true(I.get_auto_relock())
  end)

  it("respects explicit false", function()
    I.setup({ auto_relock = false })
    assert.is_false(I.get_auto_relock())
  end)

  it("can be changed after setup", function()
    I.setup({ auto_relock = true })
    mode.set_auto_relock(false)
    assert.is_false(I.get_auto_relock())
  end)
end)

------------------------------------------------------------------------
-- relock_buf
------------------------------------------------------------------------

describe("relock_buf", function()
  before_each(function()
    I.reset()
    I.setup({ auto_relock = true })
  end)

  it("relocks a previously unlocked buffer when auto_relock is true", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    I.toggle(buf) -- unlock
    assert.is_true(I.is_unlocked(buf))

    I.relock_buf(buf)
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)
    assert.is_false(I.is_unlocked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not relock when auto_relock is false", function()
    I.reset()
    I.setup({ auto_relock = false })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    I.toggle(buf) -- unlock
    I.relock_buf(buf)

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)
    assert.is_true(I.is_unlocked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does nothing for buffers that were never unlocked", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    -- relock_buf should be a no-op
    I.relock_buf(buf)

    -- State unchanged (was never tracked as unlocked)
    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
