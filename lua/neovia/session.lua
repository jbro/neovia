-- neovia session module
-- Buffer management for worktree switching (collect, unlist, relist, wipeout).

local M = {}

--- Collect file paths of all listed, normal file buffers.
--- Excludes scratch buffers (they are managed separately).
--- @return string[]
function M.collect_file_buffers()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
      and not vim.b[buf].neovia_scratch
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
function M.unlist_file_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buflisted
      and vim.bo[buf].buftype == ""
    then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        -- Stop treesitter before unlisting to prevent async fold callbacks
        -- from firing on a stale buffer (Neovim _foldupdate race, #35312).
        vim.treesitter.stop(buf)
        vim.bo[buf].buflisted = false
      end
    end
  end
end

--- Re-list buffers by path. If a buffer for the path already exists
--- (unlisted), re-list it. Otherwise create a new buffer.
--- @param paths string[]
--- @return integer[] bufs  Buffer handles of restored buffers.
function M.relist_buffers(paths)
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
