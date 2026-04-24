-- tests/neovia/pr_spec.lua
-- Unit tests for lua/neovia/pr.lua

local pr = require("neovia.pr")
local I = pr._internal

------------------------------------------------------------------------
-- parse_pr_graphql
------------------------------------------------------------------------

describe("parse_pr_graphql", function()
  it("parses an open PR", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              {
                headRefName = "feat-x",
                state = "OPEN",
                isDraft = false,
                number = 42,
                url = "https://github.com/owner/repo/pull/42",
              },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.is_not_nil(cache["feat-x"])
    assert.equals("open", cache["feat-x"].state)
    assert.equals(42, cache["feat-x"].number)
    assert.equals("https://github.com/owner/repo/pull/42", cache["feat-x"].url)
  end)

  it("parses a draft PR", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              {
                headRefName = "wip-branch",
                state = "OPEN",
                isDraft = true,
                number = 7,
                url = "https://github.com/owner/repo/pull/7",
              },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.equals("draft", cache["wip-branch"].state)
  end)

  it("parses a merged PR", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              {
                headRefName = "done-branch",
                state = "MERGED",
                isDraft = false,
                number = 100,
                url = "https://github.com/owner/repo/pull/100",
              },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.equals("merged", cache["done-branch"].state)
  end)

  it("merged takes precedence over isDraft", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              {
                headRefName = "weird",
                state = "MERGED",
                isDraft = true,
                number = 1,
                url = "",
              },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.equals("merged", cache["weird"].state)
  end)

  it("parses multiple PRs", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              { headRefName = "a", state = "OPEN", isDraft = false, number = 1, url = "u1" },
              { headRefName = "b", state = "OPEN", isDraft = true, number = 2, url = "u2" },
              { headRefName = "c", state = "MERGED", isDraft = false, number = 3, url = "u3" },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.equals("open", cache["a"].state)
    assert.equals("draft", cache["b"].state)
    assert.equals("merged", cache["c"].state)
  end)

  it("returns empty table for nil data", function()
    local cache = I.parse_pr_graphql(nil)
    assert.same({}, cache)
  end)

  it("returns empty table for missing repository", function()
    local cache = I.parse_pr_graphql({ data = {} })
    assert.same({}, cache)
  end)

  it("returns empty table for missing pullRequests", function()
    local cache = I.parse_pr_graphql({ data = { repository = {} } })
    assert.same({}, cache)
  end)

  it("returns empty table for empty nodes", function()
    local cache = I.parse_pr_graphql({
      data = { repository = { pullRequests = { nodes = {} } } },
    })
    assert.same({}, cache)
  end)

  it("skips nodes without headRefName", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              { state = "OPEN", isDraft = false, number = 1, url = "u1" },
              { headRefName = "valid", state = "OPEN", isDraft = false, number = 2, url = "u2" },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.equals(1, vim.tbl_count(cache))
    assert.is_not_nil(cache["valid"])
  end)

  it("defaults url to empty string when missing", function()
    local data = {
      data = {
        repository = {
          pullRequests = {
            nodes = {
              { headRefName = "no-url", state = "OPEN", isDraft = false, number = 1 },
            },
          },
        },
      },
    }
    local cache = I.parse_pr_graphql(data)
    assert.equals("", cache["no-url"].url)
  end)
end)

------------------------------------------------------------------------
-- pr_icon
------------------------------------------------------------------------

describe("pr_icon", function()
  it("returns open icon for open state", function()
    local icon = I.pr_icon("open")
    assert.equals("\u{f407}", icon)
  end)

  it("returns draft icon for draft state", function()
    local icon = I.pr_icon("draft")
    assert.equals("\u{f67c}", icon)
  end)

  it("returns merged icon for merged state", function()
    local icon = I.pr_icon("merged")
    assert.equals("\u{f402}", icon)
  end)

  it("returns empty string for nil", function()
    assert.equals("", I.pr_icon(nil))
  end)

  it("returns empty string for unknown state", function()
    assert.equals("", I.pr_icon("something_else"))
  end)
end)

------------------------------------------------------------------------
-- build_gh_cmd
------------------------------------------------------------------------

describe("build_gh_cmd", function()
  it("builds a valid command from owner/repo", function()
    local cmd = I.build_gh_cmd("myowner/myrepo")
    assert.equals("gh", cmd[1])
    assert.equals("api", cmd[2])
    assert.equals("graphql", cmd[3])
    assert.equals("-f", cmd[4])
    assert.is_truthy(cmd[5]:find("myowner"))
    assert.is_truthy(cmd[5]:find("myrepo"))
  end)

  it("returns empty table for invalid nwo", function()
    local cmd = I.build_gh_cmd("invalid")
    assert.same({}, cmd)
  end)

  it("includes pullRequests query", function()
    local cmd = I.build_gh_cmd("a/b")
    assert.is_truthy(cmd[5]:find("pullRequests"))
    assert.is_truthy(cmd[5]:find("headRefName"))
    assert.is_truthy(cmd[5]:find("isDraft"))
    assert.is_truthy(cmd[5]:find("number"))
    assert.is_truthy(cmd[5]:find("url"))
  end)
end)

------------------------------------------------------------------------
-- M.get (public API)
------------------------------------------------------------------------

describe("get", function()
  before_each(function()
    I.set_cache({
      ["feat-a"] = { state = "open", number = 10, url = "https://example.com/10" },
      ["feat-b"] = { state = "draft", number = 20, url = "https://example.com/20" },
    })
  end)

  after_each(function()
    I.reset()
  end)

  it("returns PR info for a known branch", function()
    local info = pr.get("feat-a")
    assert.is_not_nil(info)
    assert.equals("open", info.state)
    assert.equals(10, info.number)
  end)

  it("returns nil for an unknown branch", function()
    assert.is_nil(pr.get("no-such-branch"))
  end)
end)

------------------------------------------------------------------------
-- M.icon (public API)
------------------------------------------------------------------------

describe("M.icon", function()
  it("delegates to pr_icon", function()
    assert.equals("\u{f407}", pr.icon("open"))
    assert.equals("\u{f402}", pr.icon("merged"))
    assert.equals("", pr.icon(nil))
  end)
end)

------------------------------------------------------------------------
-- M.get_current
------------------------------------------------------------------------

describe("get_current", function()
  local orig_system

  before_each(function()
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
    I.reset()
  end)

  it("returns PR info for the current branch via git", function()
    -- Mock git rev-parse to return a known branch
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 0, stdout = "my-branch\n" } end }
      end
      return orig_system(cmd, opts, on_exit)
    end

    I.set_cache({
      ["my-branch"] = { state = "open", number = 55, url = "https://example.com/55" },
    })

    local info = pr.get_current()
    assert.is_not_nil(info)
    assert.equals("open", info.state)
    assert.equals(55, info.number)
  end)

  it("returns nil when git rev-parse fails", function()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 1, stdout = "" } end }
      end
      return orig_system(cmd, opts, on_exit)
    end

    I.set_cache({
      ["any-branch"] = { state = "open", number = 1, url = "" },
    })

    local info = pr.get_current()
    assert.is_nil(info)
  end)

  it("returns nil when branch has no PR", function()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 0, stdout = "no-pr-branch\n" } end }
      end
      return orig_system(cmd, opts, on_exit)
    end

    I.set_cache({})

    local info = pr.get_current()
    assert.is_nil(info)
  end)

  it("returns nil for detached HEAD", function()
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 0, stdout = "HEAD\n" } end }
      end
      return orig_system(cmd, opts, on_exit)
    end

    I.set_cache({
      ["HEAD"] = { state = "open", number = 1, url = "" },
    })

    local info = pr.get_current()
    assert.is_nil(info)
  end)
end)

------------------------------------------------------------------------
-- current_branch (internal: git rev-parse wrapper)
------------------------------------------------------------------------

describe("current_branch", function()
  local orig_system

  before_each(function()
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
  end)

  it("returns the branch name from git", function()
    vim.system = function(cmd)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 0, stdout = "feat-x\n" } end }
      end
      return orig_system(cmd)
    end
    assert.equals("feat-x", I.current_branch())
  end)

  it("returns nil when git fails", function()
    vim.system = function(cmd)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 128, stdout = "" } end }
      end
      return orig_system(cmd)
    end
    assert.is_nil(I.current_branch())
  end)

  it("returns nil for detached HEAD", function()
    vim.system = function(cmd)
      if cmd[1] == "git" and cmd[2] == "rev-parse" then
        return { wait = function() return { code = 0, stdout = "HEAD\n" } end }
      end
      return orig_system(cmd)
    end
    assert.is_nil(I.current_branch())
  end)
end)

------------------------------------------------------------------------
-- fetch_pr_status
------------------------------------------------------------------------

describe("fetch_pr_status", function()
  local orig_system

  before_each(function()
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
    I.reset()
  end)

  it("is a no-op when repo_nwo is nil", function()
    I.set_repo_nwo(nil)
    local system_called = false
    vim.system = function()
      system_called = true
      return { wait = function() return { code = 0, stdout = "" } end }
    end

    I.fetch_pr_status()
    assert.is_false(system_called)
  end)

  it("calls gh api graphql with the correct command", function()
    I.set_repo_nwo("owner/repo")
    local captured_cmd = nil
    vim.system = function(cmd, opts, on_exit)
      captured_cmd = cmd
      -- Simulate async completion
      if on_exit then
        on_exit({ code = 1, stdout = "" })
      end
    end

    I.fetch_pr_status()
    assert.is_not_nil(captured_cmd)
    assert.equals("gh", captured_cmd[1])
    assert.equals("api", captured_cmd[2])
    assert.equals("graphql", captured_cmd[3])
  end)

  it("updates cache on successful response", function()
    I.set_repo_nwo("owner/repo")

    local response = vim.json.encode({
      data = {
        repository = {
          pullRequests = {
            nodes = {
              { headRefName = "test-branch", state = "OPEN", isDraft = false, number = 99, url = "https://example.com/99" },
            },
          },
        },
      },
    })

    -- Make vim.schedule run synchronously for this test
    local orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end
    -- Stub redrawtabline
    local orig_redraw = vim.cmd.redrawtabline
    vim.cmd.redrawtabline = function() end

    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        on_exit({ code = 0, stdout = response })
      end
    end

    I.fetch_pr_status()

    vim.schedule = orig_schedule
    vim.cmd.redrawtabline = orig_redraw

    local cache = I.get_cache()
    assert.is_not_nil(cache["test-branch"])
    assert.equals("open", cache["test-branch"].state)
    assert.equals(99, cache["test-branch"].number)
  end)

  it("does not update cache on failed response", function()
    I.set_repo_nwo("owner/repo")
    I.set_cache({ ["old"] = { state = "open", number = 1, url = "" } })

    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        on_exit({ code = 1, stdout = "" })
      end
    end

    I.fetch_pr_status()

    -- Cache should be unchanged
    assert.is_not_nil(I.get_cache()["old"])
  end)

  it("does not update cache on invalid JSON", function()
    I.set_repo_nwo("owner/repo")
    I.set_cache({ ["old"] = { state = "open", number = 1, url = "" } })

    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        on_exit({ code = 0, stdout = "not json{{{" })
      end
    end

    I.fetch_pr_status()

    assert.is_not_nil(I.get_cache()["old"])
  end)
end)

------------------------------------------------------------------------
-- setup / reset
------------------------------------------------------------------------

describe("setup", function()
  local orig_system

  before_each(function()
    I.reset()
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
    I.reset()
  end)

  it("is idempotent", function()
    local call_count = 0
    vim.system = function(cmd, opts, on_exit)
      call_count = call_count + 1
      if on_exit then
        on_exit({ code = 1, stdout = "" })
        return
      end
      return { wait = function() return { code = 1, stdout = "" } end }
    end

    pr.setup()
    local count1 = call_count
    pr.setup()
    assert.equals(count1, call_count, "second setup should not make additional calls")
  end)

  it("does not start timer when repo detection fails", function()
    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        on_exit({ code = 1, stdout = "" })
        return
      end
      return { wait = function() return { code = 1, stdout = "" } end }
    end

    pr.setup()
    assert.is_nil(I.get_poll_timer())
  end)

  it("starts poll timer when repo is detected", function()
    -- First call is resolve_repo_nwo (sync), second is fetch_pr_status (async)
    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        -- async fetch call
        on_exit({ code = 1, stdout = "" })
        return
      end
      -- sync resolve call
      if cmd[1] == "gh" and cmd[2] == "repo" then
        return { wait = function() return { code = 0, stdout = "owner/repo\n" } end }
      end
      return { wait = function() return { code = 1, stdout = "" } end }
    end

    pr.setup()
    assert.is_not_nil(I.get_poll_timer())
    assert.equals("owner/repo", I.get_repo_nwo())
  end)
end)

describe("reset", function()
  local orig_system

  before_each(function()
    orig_system = vim.system
  end)

  after_each(function()
    vim.system = orig_system
    I.reset()
  end)

  it("clears cache", function()
    I.set_cache({ ["a"] = { state = "open", number = 1, url = "" } })
    I.reset()
    assert.same({}, I.get_cache())
  end)

  it("clears repo_nwo", function()
    I.set_repo_nwo("owner/repo")
    I.reset()
    assert.is_nil(I.get_repo_nwo())
  end)

  it("stops and closes poll timer", function()
    -- Set up a real timer
    local timer = vim.uv.new_timer()
    timer:start(999999, 999999, function() end)

    -- Inject it
    I.set_repo_nwo("x/y")
    I.set_initialised(true)
    -- Manually set the timer via a setup that creates one
    -- Instead, just reset after a real setup
    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        on_exit({ code = 1, stdout = "" })
        return
      end
      if cmd[1] == "gh" and cmd[2] == "repo" then
        return { wait = function() return { code = 0, stdout = "x/y\n" } end }
      end
      return { wait = function() return { code = 1, stdout = "" } end }
    end

    I.reset()
    pr.setup()
    local t = I.get_poll_timer()
    assert.is_not_nil(t)

    I.reset()
    assert.is_nil(I.get_poll_timer())

    -- Clean up the standalone timer
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)

  it("allows setup to run again after reset", function()
    vim.system = function(cmd, opts, on_exit)
      if on_exit then
        on_exit({ code = 1, stdout = "" })
        return
      end
      if cmd[1] == "gh" and cmd[2] == "repo" then
        return { wait = function() return { code = 0, stdout = "a/b\n" } end }
      end
      return { wait = function() return { code = 1, stdout = "" } end }
    end

    pr.setup()
    assert.equals("a/b", I.get_repo_nwo())

    I.reset()
    assert.is_nil(I.get_repo_nwo())

    pr.setup()
    assert.equals("a/b", I.get_repo_nwo())
  end)
end)
