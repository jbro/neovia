-- tests/neovia/session_spec.lua
-- Unit tests for lua/neovia/session.lua (buffer management)

local session = require("neovia.session")

describe("session module", function()
  it("exists and returns a table", function()
    assert.is_table(session)
  end)
end)

------------------------------------------------------------------------
-- collect_file_buffers
------------------------------------------------------------------------

describe("collect_file_buffers", function()
  it("returns paths of listed file buffers", function()
    local buf1 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf1, "/tmp/sess_test_a.lua")
    vim.bo[buf1].buflisted = true
    local buf2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf2, "/tmp/sess_test_b.lua")
    vim.bo[buf2].buflisted = true

    local paths = session.collect_file_buffers()
    local name1 = vim.api.nvim_buf_get_name(buf1)
    local name2 = vim.api.nvim_buf_get_name(buf2)
    local found_a, found_b = false, false
    for _, p in ipairs(paths) do
      if p == name1 then found_a = true end
      if p == name2 then found_b = true end
    end
    assert.is_true(found_a)
    assert.is_true(found_b)

    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)

  it("excludes unlisted buffers", function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/sess_unlisted.lua")
    vim.bo[buf].buflisted = false

    local paths = session.collect_file_buffers()
    for _, p in ipairs(paths) do
      assert.is_not_equal("/tmp/sess_unlisted.lua", p)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("excludes special buftypes", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/sess_special.lua")
    vim.bo[buf].buftype = "nofile"

    local paths = session.collect_file_buffers()
    for _, p in ipairs(paths) do
      assert.is_not_equal("/tmp/sess_special.lua", p)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("excludes scratch buffers", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/sess_scratch_test")
    vim.bo[buf].buflisted = true
    vim.b[buf].neovia_scratch = true

    local paths = session.collect_file_buffers()
    local scratch_name = vim.api.nvim_buf_get_name(buf)
    for _, p in ipairs(paths) do
      assert.is_not_equal(scratch_name, p)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- unlist_file_buffers
------------------------------------------------------------------------

describe("unlist_file_buffers", function()
  it("unlists all listed file buffers", function()
    local buf1 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf1, "/tmp/sess_unlist_a.lua")
    local buf2 = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf2, "/tmp/sess_unlist_b.lua")

    session.unlist_file_buffers()

    assert.is_false(vim.bo[buf1].buflisted)
    assert.is_false(vim.bo[buf2].buflisted)

    vim.api.nvim_buf_delete(buf1, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
  end)

  it("does not touch special buffers", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].buftype = "nofile"

    session.unlist_file_buffers()
    assert.is_true(vim.bo[buf].buflisted)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("restores eventignore after unlisting", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/sess_ei_unlist.lua")

    vim.o.eventignore = ""
    session.unlist_file_buffers()
    assert.equals("", vim.o.eventignore)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("suppresses autocmds during unlisting", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/sess_ei_suppress.lua")

    local autocmd_fired = false
    local group = vim.api.nvim_create_augroup("sess_test_unlist_ei", { clear = true })
    vim.api.nvim_create_autocmd("BufLeave", {
      group = group,
      callback = function() autocmd_fired = true end,
    })

    session.unlist_file_buffers()
    assert.is_false(autocmd_fired)

    vim.api.nvim_del_augroup_by_name("sess_test_unlist_ei")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

------------------------------------------------------------------------
-- relist_buffers
------------------------------------------------------------------------

describe("relist_buffers", function()
  it("re-lists buffers by path and returns them", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/tmp/sess_relist.lua")
    vim.bo[buf].buflisted = false

    local restored = session.relist_buffers({ "/tmp/sess_relist.lua" })
    assert.equals(1, #restored)
    assert.is_true(vim.bo[restored[1]].buflisted)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("creates new buffers for paths not already loaded", function()
    local path = "/tmp/sess_relist_new_" .. os.time() .. ".lua"
    local restored = session.relist_buffers({ path })
    assert.equals(1, #restored)
    vim.api.nvim_buf_delete(restored[1], { force = true })
  end)

  it("returns empty for empty path list", function()
    assert.equals(0, #session.relist_buffers({}))
  end)

  it("restores eventignore after relisting", function()
    vim.o.eventignore = ""
    local restored = session.relist_buffers({ "/tmp/sess_ei_relist_" .. os.time() .. ".lua" })
    assert.equals("", vim.o.eventignore)

    for _, buf in ipairs(restored) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("suppresses autocmds during relisting", function()
    local autocmd_fired = false
    local group = vim.api.nvim_create_augroup("sess_test_relist_ei", { clear = true })
    vim.api.nvim_create_autocmd("BufAdd", {
      group = group,
      callback = function() autocmd_fired = true end,
    })

    local restored = session.relist_buffers({ "/tmp/sess_ei_relist_supp_" .. os.time() .. ".lua" })
    assert.is_false(autocmd_fired)

    vim.api.nvim_del_augroup_by_name("sess_test_relist_ei")
    for _, buf in ipairs(restored) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end)

------------------------------------------------------------------------
-- wipeout_buffers_for_dir
------------------------------------------------------------------------

describe("wipeout_buffers_for_dir", function()
  it("wipes buffers matching saved paths and clears buffer_paths", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "/proj/a/file.lua")
    vim.bo[buf].buflisted = false

    local entry = { buffer_paths = { "/proj/a/file.lua" } }
    session.wipeout_buffers_for_dir(entry)

    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.same({}, entry.buffer_paths)
  end)

  it("is a no-op for nil entry", function()
    session.wipeout_buffers_for_dir(nil)
  end)
end)
