-- neovia review module
-- Per-worktree code review comments on diffview diffs.
-- Shared JSON file: neovia creates/edits comments, OpenCode marks resolved.

local M = {}

local initialised = false

--- In-memory comment cache, keyed by worktree dir.
--- @type table<string, neovia.ReviewData>
local cache = {}

--- Configured state directory (set via setup()).
--- @type string
local state_dir = ""

--- File watcher handles, keyed by worktree dir.
--- @type table<string, userdata>
local watchers = {}

--- Extmark namespace.
local ns = vim.api.nvim_create_namespace("neovia_review")

--- Valid comment states.
local valid_states = { new = true, resolved = true, rereview = true }

--- @class neovia.ReviewComment
--- @field id string
--- @field file string
--- @field line integer
--- @field end_line integer|nil
--- @field text string
--- @field state "new"|"resolved"|"rereview"

--- @class neovia.ReviewData
--- @field comments neovia.ReviewComment[]

local ok_fs, fs = pcall(require, "neovia.fs")

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

--- Compute the on-disk storage path for a worktree's review file.
--- @param dir string  Absolute worktree path.
--- @param sdir string  State directory root.
--- @return string
local function storage_path(dir, sdir)
  local hash = vim.fn.sha256(dir)
  return sdir .. "/review/" .. hash .. ".json"
end

--- Extract and trim text from popup buffer lines.
--- Returns nil if the result is empty.
--- @param lines string[]|nil
--- @return string|nil
local function prepare_submit_text(lines)
  if not lines then return nil end
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then return nil end
  return text
end

--- Split default text into lines for popup pre-fill.
--- @param text string|nil
--- @return string[]
local function split_default_text(text)
  if not text then return {} end
  return vim.split(text, "\n", { plain = true })
end

--- Generate a unique comment ID.
--- @return string
local function generate_id()
  -- 8 hex chars from random bytes gives ~4 billion IDs
  local bytes = {}
  for _ = 1, 4 do
    bytes[#bytes + 1] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(bytes)
end

--- Write review data to a JSON file, creating parent directories.
--- @param path string
--- @param data neovia.ReviewData
local function save_to_disk(path, data)
  local parent = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(parent, "p")
  local json = vim.json.encode(data)
  if ok_fs then
    fs.write_file(path, json)
  else
    vim.fn.writefile({ json }, path)
  end
end

--- Read review data from a JSON file. Returns nil if missing or invalid.
--- @param path string
--- @return neovia.ReviewData|nil
local function load_from_disk(path)
  local raw
  if ok_fs then
    raw = fs.read_file(path)
  else
    if vim.fn.filereadable(path) ~= 1 then return nil end
    local lines = vim.fn.readfile(path)
    raw = table.concat(lines, "\n")
  end
  if not raw or raw == "" then return nil end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

--- Get or load review data for a worktree (lazy load from disk).
--- @param dir string
--- @param sdir string
--- @return neovia.ReviewData
local function ensure_data(dir, sdir)
  if cache[dir] then return cache[dir] end
  local path = storage_path(dir, sdir)
  local data = load_from_disk(path)
  if not data then
    data = { comments = {} }
  end
  cache[dir] = data
  return data
end

--- Persist the in-memory data for a worktree to disk.
--- @param dir string
--- @param sdir string
local function persist(dir, sdir)
  local data = cache[dir]
  if not data then return end
  local path = storage_path(dir, sdir)
  save_to_disk(path, data)
end

--- Find a comment by ID in a data table.
--- @param data neovia.ReviewData
--- @param id string
--- @return neovia.ReviewComment|nil, integer|nil
local function find_by_id(data, id)
  for i, c in ipairs(data.comments) do
    if c.id == id then return c, i end
  end
  return nil, nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Add a comment for a worktree. Persists immediately.
--- @param dir string  Worktree directory.
--- @param opts {file: string, line: integer, end_line?: integer, text: string}
--- @param sdir? string  Override state directory (for testing).
--- @return neovia.ReviewComment
function M.add_comment(dir, opts, sdir)
  sdir = sdir or state_dir
  local data = ensure_data(dir, sdir)
  local comment = {
    id = generate_id(),
    file = opts.file,
    line = opts.line,
    end_line = opts.end_line or vim.NIL,
    text = opts.text,
    state = "new",
  }
  data.comments[#data.comments + 1] = comment
  persist(dir, sdir)
  return comment
end

--- Get all comments for a worktree.
--- @param dir string
--- @param sdir? string
--- @return neovia.ReviewComment[]
function M.get_comments(dir, sdir)
  sdir = sdir or state_dir
  local data = ensure_data(dir, sdir)
  return data.comments
end

--- Get comments filtered by file path.
--- @param dir string
--- @param file string
--- @param sdir? string
--- @return neovia.ReviewComment[]
function M.get_comments_for_file(dir, file, sdir)
  sdir = sdir or state_dir
  local comments = M.get_comments(dir, sdir)
  local result = {}
  for _, c in ipairs(comments) do
    if c.file == file then
      result[#result + 1] = c
    end
  end
  return result
end

--- Edit the text of a comment. Persists immediately.
--- @param dir string
--- @param id string
--- @param new_text string
--- @param sdir? string
--- @return boolean  true if found and edited.
function M.edit_comment(dir, id, new_text, sdir)
  sdir = sdir or state_dir
  local data = ensure_data(dir, sdir)
  local comment = find_by_id(data, id)
  if not comment then return false end
  comment.text = new_text
  persist(dir, sdir)
  return true
end

--- Delete a comment by ID. Persists immediately.
--- @param dir string
--- @param id string
--- @param sdir? string
--- @return boolean  true if found and deleted.
function M.delete_comment(dir, id, sdir)
  sdir = sdir or state_dir
  local data = ensure_data(dir, sdir)
  local _, idx = find_by_id(data, id)
  if not idx then return false end
  table.remove(data.comments, idx)
  persist(dir, sdir)
  return true
end

--- Set the state of a comment. Persists immediately.
--- @param dir string
--- @param id string
--- @param new_state string
--- @param sdir? string
--- @return boolean  true if found and state is valid.
function M.set_state(dir, id, new_state, sdir)
  sdir = sdir or state_dir
  if not valid_states[new_state] then return false end
  local data = ensure_data(dir, sdir)
  local comment = find_by_id(data, id)
  if not comment then return false end
  comment.state = new_state
  persist(dir, sdir)
  return true
end

--- Clear all comments for a worktree (memory + disk).
--- @param dir string
--- @param sdir? string
function M.clear(dir, sdir)
  sdir = sdir or state_dir
  cache[dir] = nil
  local path = storage_path(dir, sdir)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

--- Reload comments from disk (for file watcher callback).
--- @param dir string
--- @param sdir? string
function M.reload_from_disk(dir, sdir)
  sdir = sdir or state_dir
  cache[dir] = nil -- force re-read
  ensure_data(dir, sdir)
end

--- Find a comment at a specific file + line.
--- For range comments, matches if line is within [comment.line, comment.end_line].
--- @param dir string
--- @param file string
--- @param line integer
--- @param sdir? string
--- @return neovia.ReviewComment|nil
function M.find_comment_at_line(dir, file, line, sdir)
  sdir = sdir or state_dir
  local comments = M.get_comments_for_file(dir, file, sdir)
  for _, c in ipairs(comments) do
    local end_line = c.end_line
    if end_line == vim.NIL then end_line = nil end
    if end_line then
      if line >= c.line and line <= end_line then return c end
    else
      if line == c.line then return c end
    end
  end
  return nil
end

--- Build the review prompt text for prefilling the opencode input.
--- Returns nil if there are no actionable (new/rereview) comments.
--- @param dir string
--- @param sdir? string
--- @return string|nil
function M.build_prompt(dir, sdir)
  sdir = sdir or state_dir
  local comments = M.get_comments(dir, sdir)
  local has_actionable = false
  for _, c in ipairs(comments) do
    if c.state == "new" or c.state == "rereview" then
      has_actionable = true
      break
    end
  end
  if not has_actionable then return nil end

  local path = storage_path(dir, sdir)
  return string.format(
    "Review comments are at %s. Read the file and address each comment "
      .. "with state 'new' or 'rereview'. Edit the code to fix the issues, "
      .. "then update the comment's state to 'resolved' in the JSON file.",
    path
  )
end

--- Render review extmarks on a buffer for a specific file.
--- Clears existing review extmarks first.
--- @param buf integer  Buffer handle.
--- @param file string  Relative file path.
--- @param dir string  Worktree directory.
--- @param sdir? string
function M.render_extmarks(buf, file, dir, sdir)
  sdir = sdir or state_dir
  if not vim.api.nvim_buf_is_valid(buf) then return end

  -- Clear existing review extmarks on this buffer.
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local comments = M.get_comments_for_file(dir, file, sdir)
  local line_count = vim.api.nvim_buf_line_count(buf)

  for _, c in ipairs(comments) do
    if c.line >= 1 and c.line <= line_count then
      local row = c.line - 1 -- 0-indexed
      local state_label = c.state == "new" and "review" or c.state
      local virt_text = string.format(" [%s] %s", state_label, c.text)
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_text = { { virt_text, "DiagnosticVirtualTextInfo" } },
        virt_text_pos = "eol",
      })
    end
  end
end

------------------------------------------------------------------------
-- File watching
------------------------------------------------------------------------

--- Start watching the review JSON file for a worktree.
--- When the file changes (e.g. OpenCode edits it), reload from disk.
--- @param dir string
--- @param sdir? string
function M.watch(dir, sdir)
  sdir = sdir or state_dir
  if watchers[dir] then return end -- already watching

  local path = storage_path(dir, sdir)
  local parent = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(parent, "p")

  -- Ensure the file exists so the watcher has something to watch.
  if vim.fn.filereadable(path) ~= 1 then
    save_to_disk(path, ensure_data(dir, sdir))
  end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  handle:start(path, {}, function(err)
    if err then return end
    vim.schedule(function()
      M.reload_from_disk(dir, sdir)
    end)
  end)

  watchers[dir] = handle
end

--- Stop watching the review JSON file for a worktree.
--- @param dir string
function M.unwatch(dir)
  local handle = watchers[dir]
  if not handle then return end
  pcall(function() handle:stop() end)
  pcall(function() handle:close() end)
  watchers[dir] = nil
end

------------------------------------------------------------------------
-- Submit (prefill opencode input)
------------------------------------------------------------------------

--- Prefill the opencode input with the review prompt.
--- Returns true if a prompt was generated, false if no actionable comments.
--- @param dir string
--- @param sdir? string
--- @return boolean
function M.submit(dir, sdir)
  sdir = sdir or state_dir
  local prompt = M.build_prompt(dir, sdir)
  if not prompt then return false end

  -- Attempt to prefill the opencode input window.
  local ok_iw, input_window = pcall(require, "opencode.ui.input_window")
  if ok_iw and input_window.set_content then
    input_window.set_content(prompt)
  end

  return true
end

------------------------------------------------------------------------
-- Comment input popup (nui.popup)
------------------------------------------------------------------------

--- Open a floating popup for entering a comment.
--- @param opts {title?: string, default?: string, on_submit: fun(text: string)}
function M.open_comment_input(opts)
  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    vim.notify("nui.nvim is required for review comments", vim.log.levels.ERROR)
    return
  end

  local popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = opts.title or " Review Comment ",
        top_align = "center",
      },
    },
    position = "50%",
    size = {
      width = 60,
      height = 8,
    },
    buf_options = {
      modifiable = true,
      readonly = false,
      filetype = "markdown",
    },
  })

  popup:mount()

  -- Pre-fill with default text if provided (for editing).
  if opts.default then
    local lines = split_default_text(opts.default)
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  end

  -- Start in insert mode.
  vim.cmd("startinsert")

  -- Confirm: <CR> in normal mode.
  popup:map("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    local text = prepare_submit_text(lines)
    popup:unmount()
    if text then
      opts.on_submit(text)
    end
  end)

  -- Cancel: q in normal mode.
  popup:map("n", "q", function()
    popup:unmount()
  end)
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

--- @class neovia.ReviewOpts
--- @field state_dir? string  Override state directory (default: stdpath("state")).

--- Initialise the review module. Idempotent.
--- @param opts? neovia.ReviewOpts
function M.setup(opts)
  if initialised then return end
  initialised = true

  opts = opts or {}
  state_dir = opts.state_dir or vim.fn.stdpath("state")

  vim.api.nvim_create_augroup("neovia_review", { clear = true })
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

M._internal = {
  storage_path = storage_path,
  generate_id = generate_id,
  save_to_disk = save_to_disk,
  load_from_disk = load_from_disk,
  prepare_submit_text = prepare_submit_text,
  split_default_text = split_default_text,

  --- Return the in-memory cache table (for test assertions).
  get_cache = function()
    return cache
  end,

  --- Return the watchers table (for test assertions).
  get_watchers = function()
    return watchers
  end,

  --- Reset all state (reload contract).
  reset = function()
    -- Stop all file watchers.
    for dir, w in pairs(watchers) do
      pcall(function() w:stop() end)
      pcall(function() w:close() end)
      watchers[dir] = nil
    end
    watchers = {}
    cache = {}
    initialised = false
    state_dir = ""
    pcall(vim.api.nvim_create_augroup, "neovia_review", { clear = true })
  end,
}

return M
