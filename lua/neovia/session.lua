-- neovia session module
-- Buffer management for worktree switching (collect, unlist, relist, wipeout).

local M = {}

--- Collect file paths of all listed, normal file buffers.
--- Excludes notes buffers (they are managed separately).
--- @return string[]
function M.collect_file_buffers()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
      and not vim.b[buf].neovia_notes
    then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        table.insert(paths, name)
      end
    end
  end
  return paths
end

--- Unlist all listed file buffers (buftype="" and buflisted).
--- Suppresses autocmds during the bulk operation for performance.
function M.unlist_file_buffers()
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = "all"

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
    then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        vim.bo[buf].buflisted = false
      end
    end
  end

  vim.o.eventignore = saved_ei
end

--- Re-list buffers by path. If a buffer for the path already exists
--- (unlisted), re-list it. Otherwise create a new buffer.
--- Suppresses autocmds during the bulk operation for performance.
--- @param paths string[]
--- @return integer[] bufs  Buffer handles of restored buffers.
function M.relist_buffers(paths)
  local saved_ei = vim.o.eventignore
  vim.o.eventignore = "all"

  local bufs = {}
  for _, path in ipairs(paths) do
    local existing = vim.fn.bufnr(path)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
      vim.bo[existing].buflisted = true
      table.insert(bufs, existing)
    else
      local buf = vim.fn.bufadd(path)
      vim.bo[buf].buflisted = true
      table.insert(bufs, buf)
    end
  end

  vim.o.eventignore = saved_ei
  return bufs
end

--- Wipeout all unlisted buffers matching saved paths for a directory.
--- Also clears buffer_paths from the entry table.
--- @param entry table|nil  State entry with buffer_paths field.
function M.wipeout_buffers_for_dir(entry)
  if not entry then return end

  for _, path in ipairs(entry.buffer_paths) do
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  entry.buffer_paths = {}
end

return M
