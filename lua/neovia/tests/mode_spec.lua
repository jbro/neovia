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

  it("returns false for acwrite buftype", function()
    assert.is_false(I.should_lock({ buftype = "acwrite", filetype = "" }))
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

  it("returns false for opencode filetype (input buffer)", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "opencode" }))
  end)

  it("returns false for opencode_output filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "opencode_output" }))
  end)

  it("returns false for opencode_footer filetype", function()
    assert.is_false(I.should_lock({ buftype = "", filetype = "opencode_footer" }))
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

  it("is a no-op for special buffers", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    I.toggle(buf)

    -- Should remain unchanged
    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)
    assert.is_false(I.is_unlocked(buf))

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

    local result = mode.lualine_mode(buf)
    assert.equals("READ-ONLY", result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns vim mode for an unlocked buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    local result = mode.lualine_mode(buf)
    -- In test harness we're in normal mode
    assert.equals("NORMAL", result)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns vim mode for special buffers", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"

    local result = mode.lualine_mode(buf)
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

------------------------------------------------------------------------
-- apply_lock (autocmd callback path)
------------------------------------------------------------------------

describe("apply_lock", function()
  before_each(function()
    I.reset()
    I.setup({ auto_relock = true })
  end)

  it("locks a normal buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    I.apply_lock(buf)

    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not lock special buftype buffers", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    I.apply_lock(buf)

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not lock special filetype buffers", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "opencode_output"
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    I.apply_lock(buf)

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not re-lock a buffer the user has unlocked", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    -- User unlocks the buffer
    I.toggle(buf)
    assert.is_true(I.is_unlocked(buf))

    -- apply_lock should respect the unlocked tracking
    I.apply_lock(buf)

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("ignores invalid buffers", function()
    -- Should not error on an invalid buffer
    I.apply_lock(99999)
  end)
end)

------------------------------------------------------------------------
-- M.setup() autocmd wiring
------------------------------------------------------------------------

describe("setup autocmds", function()
  before_each(function()
    I.reset()
  end)

  after_each(function()
    I.reset()
  end)

  it("creates the neovia_mode augroup", function()
    mode.setup({ auto_relock = true })
    -- nvim_get_autocmds will error if the group doesn't exist
    local cmds = vim.api.nvim_get_autocmds({ group = "neovia_mode" })
    assert.is_true(#cmds > 0)
  end)

  it("registers BufReadPost and BufNewFile autocmds that lock normal buffers", function()
    mode.setup({ auto_relock = true })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/mode_setup_test_" .. os.time() .. ".lua")

    -- Fire BufReadPost
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("registers BufReadPost autocmd that skips special buffers", function()
    mode.setup({ auto_relock = true })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("registers FileType autocmd that locks buffers", function()
    mode.setup({ auto_relock = true })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    vim.api.nvim_exec_autocmds("FileType", { buffer = buf })

    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("registers BufLeave autocmd that relocks unlocked buffers", function()
    mode.setup({ auto_relock = true })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    -- Unlock via toggle
    I.toggle(buf)
    assert.is_true(I.is_unlocked(buf))

    -- Fire BufLeave
    vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })

    assert.is_false(vim.bo[buf].modifiable)
    assert.is_true(vim.bo[buf].readonly)
    assert.is_false(I.is_unlocked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("registers BufDelete autocmd that cleans up unlocked tracking", function()
    mode.setup({ auto_relock = true })

    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true

    -- Unlock via toggle
    I.toggle(buf)
    assert.is_true(I.is_unlocked(buf))

    -- Fire BufDelete
    vim.api.nvim_exec_autocmds("BufDelete", { buffer = buf })

    assert.is_false(I.is_unlocked(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is idempotent (second call is a no-op)", function()
    mode.setup({ auto_relock = true })
    local cmds1 = vim.api.nvim_get_autocmds({ group = "neovia_mode" })

    mode.setup({ auto_relock = false })
    local cmds2 = vim.api.nvim_get_autocmds({ group = "neovia_mode" })

    assert.equals(#cmds1, #cmds2)
    -- auto_relock should still be true from first call (second was skipped)
    assert.is_true(I.get_auto_relock())
  end)
end)

------------------------------------------------------------------------
-- M.toggle() public wrapper
------------------------------------------------------------------------

describe("M.toggle()", function()
  before_each(function()
    I.reset()
    I.setup({ auto_relock = true })
  end)

  it("toggles the current buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.api.nvim_set_current_buf(buf)

    mode.toggle()

    assert.is_true(vim.bo[buf].modifiable)
    assert.is_false(vim.bo[buf].readonly)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
