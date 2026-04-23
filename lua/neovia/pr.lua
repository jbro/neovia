-- neovia PR status module
-- Fetches GitHub PR status per branch via gh api graphql.
-- Exposes data for the worktree tabline and lualine statusline.

local M = {}

--- @class neovia.PrInfo
--- @field state "open"|"draft"|"merged"
--- @field number integer
--- @field url string

--- PR cache keyed by branch name.
--- @type table<string, neovia.PrInfo>
local pr_cache = {}

--- GitHub repo owner/name (e.g. "owner/repo"). Resolved once on setup.
--- @type string|nil
local repo_nwo = nil

--- Whether setup() has been called.
local initialised = false

--- Poll timer handle.
--- @type uv_timer_t|nil
local poll_timer = nil

--- PR status icons (nerd font).
--- @type table<string, string>
local pr_icons = {
  open = "\u{f407}",     -- nf-oct-git_pull_request
  draft = "\u{f67c}",    -- nf-oct-git_pull_request_draft
  merged = "\u{f402}",   -- nf-oct-git_merge
}

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

--- Parse the decoded JSON from a GitHub GraphQL PR query into a cache table.
--- @param data table  Decoded JSON response from gh api graphql.
--- @return table<string, neovia.PrInfo>  Cache keyed by branch name.
local function parse_pr_graphql(data)
  local cache = {}
  local repo = data
    and data.data
    and data.data.repository
  if not repo then return cache end

  local nodes = repo.pullRequests and repo.pullRequests.nodes
  if not nodes then return cache end

  for _, pr in ipairs(nodes) do
    if pr.headRefName then
      local st
      if pr.state == "MERGED" then
        st = "merged"
      elseif pr.isDraft then
        st = "draft"
      else
        st = "open"
      end
      cache[pr.headRefName] = {
        state = st,
        number = pr.number,
        url = pr.url or "",
      }
    end
  end
  return cache
end

--- Resolve the GitHub owner/name for the current repo.
--- Runs `gh repo view --json nameWithOwner` synchronously.
--- @return string|nil  "owner/repo" or nil if not a GitHub repo.
local function resolve_repo_nwo()
  local result = vim.system(
    { "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" },
    { text = true }
  ):wait()
  if result.code ~= 0 then return nil end
  local nwo = vim.trim(result.stdout or "")
  if nwo == "" then return nil end
  return nwo
end

--- Return the icon for a PR state, or "" if nil/unknown.
--- @param state string|nil
--- @return string
local function pr_icon(state)
  if not state then return "" end
  return pr_icons[state] or ""
end

------------------------------------------------------------------------
-- Fetch
------------------------------------------------------------------------

--- Build the GraphQL query string for fetching PRs.
--- @param nwo string  "owner/repo"
--- @return string[]  Command args for vim.system.
local function build_gh_cmd(nwo)
  local owner, name = nwo:match("^([^/]+)/(.+)$")
  if not owner then return {} end
  local query = string.format([[
    query {
      repository(owner: "%s", name: "%s") {
        pullRequests(first: 30, states: [OPEN, MERGED], orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            headRefName
            state
            isDraft
            number
            url
          }
        }
      }
    }
  ]], owner, name)
  return { "gh", "api", "graphql", "-f", "query=" .. query }
end

--- Fetch PR status asynchronously and update the cache.
--- No-op if repo_nwo is not set.
local function fetch_pr_status()
  if not repo_nwo then return end

  local cmd = build_gh_cmd(repo_nwo)
  if #cmd == 0 then return end

  vim.system(cmd, { text = true }, function(result)
    if result.code ~= 0 then return end
    local ok, data = pcall(vim.json.decode, result.stdout or "")
    if not ok or not data then return end
    local new_cache = parse_pr_graphql(data)
    vim.schedule(function()
      pr_cache = new_cache
      vim.cmd.redrawtabline()
    end)
  end)
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Return PR info for a branch, or nil if no PR exists.
--- @param branch string
--- @return neovia.PrInfo|nil
function M.get(branch)
  return pr_cache[branch]
end

--- Return PR info for the current worktree's branch, or nil.
--- Uses the worktree module to find the current branch.
--- @return neovia.PrInfo|nil
function M.get_current()
  local ok, wt = pcall(require, "neovia.worktree")
  if not ok then return nil end
  local status = wt.get_current_status()
  if not status then return nil end
  -- get_current_status doesn't expose branch; look it up from state
  local cwd = vim.fn.getcwd(-1, 0)
  local st = wt._internal.get_state()[cwd]
  if not st then return nil end
  return pr_cache[st.branch]
end

--- Return the icon string for a PR state.
--- @param state string|nil
--- @return string
function M.icon(state)
  return pr_icon(state)
end

--- Initialise the module. Idempotent.
function M.setup()
  if initialised then return end
  initialised = true

  -- Resolve repo nwo (synchronous, runs once)
  repo_nwo = resolve_repo_nwo()
  if not repo_nwo then return end

  -- Immediate first fetch
  fetch_pr_status()

  -- Start poll timer (60s interval)
  poll_timer = vim.uv.new_timer()
  poll_timer:start(60000, 60000, vim.schedule_wrap(function()
    fetch_pr_status()
  end))
end

------------------------------------------------------------------------
-- Test internals
------------------------------------------------------------------------

--- @class neovia.PrInternals
M._internal = {
  parse_pr_graphql = parse_pr_graphql,
  resolve_repo_nwo = resolve_repo_nwo,
  pr_icon = pr_icon,
  build_gh_cmd = build_gh_cmd,
  fetch_pr_status = fetch_pr_status,

  --- Get the current cache (for assertions).
  --- @return table<string, neovia.PrInfo>
  get_cache = function() return pr_cache end,

  --- Replace the cache (for test setup).
  --- @param new_cache table<string, neovia.PrInfo>
  set_cache = function(new_cache) pr_cache = new_cache end,

  --- Get the current repo nwo (for assertions).
  --- @return string|nil
  get_repo_nwo = function() return repo_nwo end,

  --- Set repo nwo (for test setup).
  --- @param nwo string|nil
  set_repo_nwo = function(nwo) repo_nwo = nwo end,

  --- Mark as initialised (for tests that bypass setup).
  set_initialised = function(val) initialised = val end,

  --- Get the poll timer (for assertions).
  get_poll_timer = function() return poll_timer end,

  --- Reset module to uninitialised state.
  reset = function()
    if poll_timer then
      poll_timer:stop()
      if not poll_timer:is_closing() then poll_timer:close() end
      poll_timer = nil
    end
    pr_cache = {}
    repo_nwo = nil
    initialised = false
  end,
}

return M
