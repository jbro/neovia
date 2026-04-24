-- tests/neovia/tabline_spec.lua
-- Unit tests for lua/neovia/tabline.lua

local tabline = require("neovia.tabline")
local I = tabline._internal

describe("tabline module", function()
  it("exists and returns a table", function()
    assert.is_table(tabline)
  end)
end)

------------------------------------------------------------------------
-- status_colors (authoritative colour source, moved from theme.lua)
------------------------------------------------------------------------

describe("status_colors", function()
  it("is exposed on the public API", function()
    assert.is_table(tabline.status_colors)
  end)

  it("contains all four status keys", function()
    assert.is_string(tabline.status_colors.idle)
    assert.is_string(tabline.status_colors.responding)
    assert.is_string(tabline.status_colors.needs_attention)
    assert.is_string(tabline.status_colors.unknown)
  end)

  it("values are hex colour strings", function()
    for _, colour in pairs(tabline.status_colors) do
      assert.is_truthy(colour:match("^#%x+$"), "expected hex colour, got: " .. colour)
    end
  end)
end)

------------------------------------------------------------------------
-- status_icon
------------------------------------------------------------------------

describe("status_icon", function()
  it("returns text icons for all statuses", function()
    assert.equals("[idle]", I.status_icon.idle)
    assert.equals("[working]", I.status_icon.responding)
    assert.equals("[needs you]", I.status_icon.needs_attention)
    assert.equals("[idle]", I.status_icon.unknown)
  end)
end)

------------------------------------------------------------------------
-- status_hl_for
------------------------------------------------------------------------

describe("status_hl_for", function()
  it("returns a table with fg for known statuses", function()
    local hl = I.status_hl_for("idle")
    assert.is_table(hl)
    assert.is_not_nil(hl.fg)
  end)

  it("falls back to unknown colour for unrecognised status", function()
    local hl = I.status_hl_for("something_else")
    assert.is_table(hl)
    assert.is_not_nil(hl.fg)
  end)
end)

------------------------------------------------------------------------
-- status_display (public API)
------------------------------------------------------------------------

describe("status_display", function()
  it("returns icon and hl for a known status", function()
    local result = tabline.status_display("idle")
    assert.is_table(result)
    assert.equals("[idle]", result.icon)
    assert.is_table(result.hl)
    assert.is_not_nil(result.hl.fg)
  end)

  it("returns icon and hl for needs_attention", function()
    local result = tabline.status_display("needs_attention")
    assert.equals("[needs you]", result.icon)
  end)

  it("falls back to unknown for unrecognised status", function()
    local result = tabline.status_display("something_else")
    assert.equals("[idle]", result.icon)
    assert.is_not_nil(result.hl.fg)
  end)
end)

------------------------------------------------------------------------
-- status_ansi
------------------------------------------------------------------------

describe("status_ansi", function()
  it("has ANSI codes for all four statuses", function()
    assert.is_string(I.status_ansi.idle)
    assert.is_string(I.status_ansi.responding)
    assert.is_string(I.status_ansi.needs_attention)
    assert.is_string(I.status_ansi.unknown)
  end)
end)

------------------------------------------------------------------------
-- status_char
------------------------------------------------------------------------

describe("status_char", function()
  it("returns alert icon for needs_attention", function()
    assert.equals("󰀦", I.status_char("needs_attention"))
  end)

  it("returns a braille spinner frame for responding", function()
    local frame = I.status_char("responding")
    local braille = { "⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾" }
    local found = false
    for _, f in ipairs(braille) do
      if f == frame then found = true; break end
    end
    assert.is_true(found, "expected a braille spinner frame")
  end)

  it("returns dots icon for unknown", function()
    assert.equals("󰇘", I.status_char("unknown"))
  end)

  it("returns sleep icon for idle", function()
    assert.equals("󰒲", I.status_char("idle"))
  end)
end)

------------------------------------------------------------------------
-- define_worktree_highlights (moved from theme.lua)
------------------------------------------------------------------------

describe("define_worktree_highlights", function()
  before_each(function()
    vim.api.nvim_set_hl(0, "lualine_a_normal", { bg = "#aaaaaa", fg = "#111111" })
    vim.api.nvim_set_hl(0, "lualine_b_normal", { bg = "#555555", fg = "#eeeeee" })
    vim.api.nvim_set_hl(0, "TabLineFill", { bg = "#222222" })
  end)

  after_each(function()
    vim.api.nvim_set_hl(0, "lualine_a_normal", {})
    vim.api.nvim_set_hl(0, "lualine_b_normal", {})
    vim.api.nvim_set_hl(0, "TabLineFill", {})
  end)

  it("creates NeoviaWtSel from lualine_a_normal", function()
    tabline.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWtSel", link = false })
    assert.is_not_nil(hl.bg)
    assert.is_true(hl.bold or false)
  end)

  it("creates NeoviaWt from lualine_b_normal", function()
    tabline.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWt", link = false })
    assert.is_not_nil(hl.bg)
  end)

  it("creates transitional highlight NeoviaWtSel_to_wt", function()
    tabline.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWtSel_to_wt", link = false })
    assert.is_not_nil(hl.fg)
    assert.is_not_nil(hl.bg)
  end)

  it("creates transitional highlight NeoviaWtSel_to_fill", function()
    tabline.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWtSel_to_fill", link = false })
    assert.is_not_nil(hl.fg)
    assert.is_not_nil(hl.bg)
  end)

  it("creates transitional highlight NeoviaWt_to_fill", function()
    tabline.define_worktree_highlights()
    local hl = vim.api.nvim_get_hl(0, { name = "NeoviaWt_to_fill", link = false })
    assert.is_not_nil(hl.fg)
    assert.is_not_nil(hl.bg)
  end)

  it("creates status indicator highlights", function()
    tabline.define_worktree_highlights()
    local idle = vim.api.nvim_get_hl(0, { name = "NeoviaWt_idle", link = false })
    local responding = vim.api.nvim_get_hl(0, { name = "NeoviaWt_responding", link = false })
    local attn = vim.api.nvim_get_hl(0, { name = "NeoviaWt_needs_attention", link = false })
    local unknown = vim.api.nvim_get_hl(0, { name = "NeoviaWt_unknown", link = false })
    assert.is_not_nil(idle.fg)
    assert.is_not_nil(responding.fg)
    assert.is_not_nil(attn.fg)
    assert.is_not_nil(unknown.fg)
  end)
end)

------------------------------------------------------------------------
-- build (tabline string builder)
------------------------------------------------------------------------

describe("build", function()
  it("returns empty string for 0 entries", function()
    assert.equals("", tabline.build({}))
  end)

  it("renders a single current entry with NeoviaWtSel highlight", function()
    local result = tabline.build({
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
    })
    assert.is_truthy(result:find("main"))
    assert.is_truthy(result:find("%%#NeoviaWtSel#"))
    assert.is_truthy(result:find("%%#TabLineFill#"))
  end)

  it("renders non-current entries with NeoviaWt highlight", function()
    local entries = {
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    }
    local result = tabline.build(entries)
    assert.is_truthy(result:find("%%#NeoviaWt#"))
  end)

  it("includes powerline separator", function()
    local entries = {
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    }
    local result = tabline.build(entries)
    assert.is_truthy(result:find("\u{e0b0}", 1, true))
  end)

  it("uses transitional highlights between entries", function()
    local entries = {
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    }
    local result = tabline.build(entries)
    assert.is_truthy(result:find("NeoviaWtSel_to_wt", 1, true))
    assert.is_truthy(result:find("NeoviaWt_to_fill", 1, true))
  end)

  it("wraps non-current entries with click handler", function()
    local entries = {
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    }
    local result = tabline.build(entries)
    assert.is_truthy(result:find("@NeoviaWorktreeSwitch@"))
    assert.is_truthy(result:find("%%T"))
  end)

  it("shows alert icon for needs_attention", function()
    local entries = {
      { branch = "attn", status = "needs_attention", current = true, path = "/proj/attn" },
    }
    local result = tabline.build(entries)
    assert.is_truthy(result:find("󰀦", 1, true))
  end)

  it("shows braille spinner for responding", function()
    local entries = {
      { branch = "busy", status = "responding", current = true, path = "/proj/busy" },
    }
    local result = tabline.build(entries)
    local braille = { "⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾" }
    local found = false
    for _, frame in ipairs(braille) do
      if result:find(frame, 1, true) then found = true; break end
    end
    assert.is_true(found)
  end)

  it("prefixes branch with PR icon when pr field is set", function()
    local entries = {
      { branch = "feat", status = "idle", current = true, path = "/proj/feat",
        pr = { state = "open", number = 42, url = "" } },
    }
    local result = tabline.build(entries)
    assert.is_truthy(result:find("\u{f407} feat", 1, true))
  end)

  it("registers click paths for non-current entries", function()
    local entries = {
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
      { branch = "attn", status = "needs_attention", current = false, path = "/proj/attn" },
    }
    tabline.build(entries)
    local click_paths = I.get_click_paths()
    assert.equals(2, vim.tbl_count(click_paths))
    local paths = vim.tbl_values(click_paths)
    table.sort(paths)
    assert.are.same({ "/proj/attn", "/proj/feat" }, paths)
  end)

  it("resets click paths on each call", function()
    local entries = {
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    }
    tabline.build(entries)
    assert.equals(1, vim.tbl_count(I.get_click_paths()))
    tabline.build(entries)
    assert.equals(1, vim.tbl_count(I.get_click_paths()))
  end)
end)

------------------------------------------------------------------------
-- handle_tabline_click
------------------------------------------------------------------------

describe("handle_tabline_click", function()
  it("calls the click handler with the resolved path", function()
    local switched_to = nil
    tabline.set_click_handler(function(path) switched_to = path end)

    tabline.build({
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    })

    I.handle_tabline_click(1)
    assert.equals("/proj/feat", switched_to)
    tabline.set_click_handler(nil)
  end)

  it("is a no-op for unknown click IDs", function()
    local switched_to = nil
    tabline.set_click_handler(function(path) switched_to = path end)
    tabline.build({
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
    })
    I.handle_tabline_click(999)
    assert.is_nil(switched_to)
    tabline.set_click_handler(nil)
  end)
end)

------------------------------------------------------------------------
-- build_picker_entries
------------------------------------------------------------------------

describe("build_picker_entries", function()
  it("returns parallel arrays of entries and paths", function()
    local worktrees = {
      { path = "/proj/main", branch = "main" },
      { path = "/proj/feat", branch = "feat-a" },
    }
    local state = {
      ["/proj/main"] = { status = "idle" },
      ["/proj/feat"] = { status = "responding" },
    }
    local entries, paths = tabline.build_picker_entries(worktrees, "/proj/main", state)
    assert.equals(2, #entries)
    assert.equals(2, #paths)
    assert.equals("/proj/main", paths[1])
    assert.equals("/proj/feat", paths[2])
  end)

  it("marks current worktree with *", function()
    local worktrees = {
      { path = "/proj/main", branch = "main" },
      { path = "/proj/feat", branch = "feat-a" },
    }
    local state = {
      ["/proj/main"] = { status = "idle" },
      ["/proj/feat"] = { status = "responding" },
    }
    local entries, _ = tabline.build_picker_entries(worktrees, "/proj/main", state)
    local stripped = entries[1]:gsub("\27%[[%d;]*m", "")
    assert.is_truthy(stripped:find("%*"))
  end)

end)

------------------------------------------------------------------------
-- reset (reload contract)
------------------------------------------------------------------------

describe("reset", function()
  it("clears click paths", function()
    tabline.build({
      { branch = "main", status = "idle", current = true, path = "/proj/main" },
      { branch = "feat", status = "idle", current = false, path = "/proj/feat" },
    })
    assert.is_true(vim.tbl_count(I.get_click_paths()) > 0)
    I.reset()
    assert.equals(0, vim.tbl_count(I.get_click_paths()))
  end)

  it("resets spinner index", function()
    I.status_char("responding")
    I.status_char("responding")
    I.reset()
    local frame = I.status_char("responding")
    assert.equals("⣷", frame)
  end)
end)
