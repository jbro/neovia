-- lua/neovia/fs.lua
-- Shared filesystem utilities for neovia modules.

local M = {}

--- Read the full contents of a file, trimming trailing whitespace.
--- @param path string
--- @return string?
function M.read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438) -- 0o666
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then vim.uv.fs_close(fd); return nil end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not data then return nil end
  return vim.trim(data)
end

--- Write `data` to `path` with mode 0600.
--- @param path string
--- @param data string
function M.write_file(path, data)
  local fd = vim.uv.fs_open(path, "w", 384) -- 0o600
  if not fd then return end
  vim.uv.fs_write(fd, data, 0)
  vim.uv.fs_close(fd)
end

return M
