-- neovia workaround module
-- Temporary workarounds for upstream bugs. Each section documents the
-- issue, the conditions for removal, and what to clean up.
--
-- ====================================================================
-- WORKAROUND: Force opencode.nvim output re-render on SSE events
-- ====================================================================
--
-- Bug:     opencode >= 1.14.42 introduced HTTP response compression
--          that kills the per-directory SSE /event stream immediately
--          after the initial server.connected event. opencode.nvim's
--          output renderer relies on that per-directory stream for
--          live message updates; without it, new assistant replies
--          never appear in the output window.
--
-- Issue:   https://github.com/anomalyco/opencode/issues/26697
-- Affects: opencode CLI 1.14.42+, opencode.nvim cef831d and earlier
--
-- What this does:
--   neovia connects to /global/event (which is unaffected by the bug)
--   for its own status tracking. This workaround piggybacks on those
--   events: when a status-relevant event arrives for the current
--   worktree, it calls opencode.nvim's render_output() to force the
--   output window to re-fetch messages via the REST API.
--
--   This is called from the SSE event processing path in sse.lua
--   after apply_event, so refreshes happen at the same cadence as
--   real events -- no polling, no timers.
--
-- When to remove:
--   Delete this file and its test (workaround_spec.lua) once EITHER:
--   (a) the upstream SSE bug is fixed (issue #26697 closed) and
--       opencode.nvim's per-directory /event stream works again, OR
--   (b) opencode.nvim itself migrates to /global/event for rendering.
--   After removal, also remove the `workaround.maybe_refresh_output`
--   call from worktree.lua's process_event function and the pcall
--   require of neovia.workaround.
-- ====================================================================

local M = {}

--- Event types that indicate content changed and the output window
--- should be refreshed. We intentionally exclude high-frequency
--- events like message.part.delta (text streaming deltas) to avoid
--- hammering render_output on every token.
local REFRESH_EVENTS = {
  ["message.updated"] = true,
  ["message.part.updated"] = true,
  ["permission.asked"] = true,
  ["permission.replied"] = true,
  ["question.asked"] = true,
  ["question.replied"] = true,
  ["question.rejected"] = true,
  ["session.idle"] = true,
  ["session.error"] = true,
}

--- Check whether the opencode output window currently has focus.
--- When focused the user is reading output; re-rendering would
--- reset their scroll position (render_full_session always calls
--- scroll_to_bottom). Skip the refresh and let the next event
--- after they leave the window catch up.
--- @return boolean
local function output_focused()
  local ok_st, oc_state = pcall(require, "opencode.state")
  if not ok_st or not oc_state then return false end
  local wins = oc_state.windows
  if not wins or not wins.output_win then return false end
  return wins.output_win == vim.api.nvim_get_current_win()
end

--- Force the opencode.nvim output window to re-fetch messages if the
--- event is relevant and the directory is the current worktree.
--- Skips when the output window is focused to preserve scroll position.
--- @param dir string|nil  Worktree directory from the SSE event.
--- @param event_type string  The SSE event type (e.g. "message.updated").
function M.maybe_refresh_output(dir, event_type)
  if not dir then return end
  if not REFRESH_EVENTS[event_type] then return end
  if dir ~= vim.fn.getcwd(-1, 0) then return end
  if output_focused() then return end

  local ok, ui = pcall(require, "opencode.ui.ui")
  if ok and ui and ui.render_output then
    pcall(ui.render_output)
  end
end

return M
