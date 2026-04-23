-- tests/neovia/fs_spec.lua
-- Unit tests for lua/neovia/fs.lua

local fs = require("neovia.fs")

------------------------------------------------------------------------
-- read_file
------------------------------------------------------------------------

describe("read_file", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
  end)

  after_each(function()
    os.remove(tmp)
  end)

  it("reads file contents", function()
    local fd = vim.uv.fs_open(tmp, "w", 384)
    vim.uv.fs_write(fd, "hello-world", 0)
    vim.uv.fs_close(fd)

    assert.equals("hello-world", fs.read_file(tmp))
  end)

  it("trims trailing whitespace", function()
    local fd = vim.uv.fs_open(tmp, "w", 384)
    vim.uv.fs_write(fd, "value\n\n", 0)
    vim.uv.fs_close(fd)

    assert.equals("value", fs.read_file(tmp))
  end)

  it("returns nil for a non-existent file", function()
    assert.is_nil(fs.read_file("/no/such/file"))
  end)
end)

------------------------------------------------------------------------
-- write_file
------------------------------------------------------------------------

describe("write_file", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
  end)

  after_each(function()
    os.remove(tmp)
  end)

  it("writes data and round-trips with read_file", function()
    fs.write_file(tmp, "test-data")
    assert.equals("test-data", fs.read_file(tmp))
  end)

  it("creates the file with owner-only permissions (0600)", function()
    fs.write_file(tmp, "secret")
    local stat = vim.uv.fs_stat(tmp)
    assert.is_not_nil(stat)
    -- 0600 in octal = 384 in decimal; check only the permission bits
    local mode_bits = bit.band(stat.mode, tonumber("777", 8))
    assert.equals(tonumber("600", 8), mode_bits)
  end)
end)
