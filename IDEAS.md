# Ideas

Future ideas and spikes that haven't been scheduled yet.

## Worktree diff review cycle

Review AI-generated diffs and feed structured comments back to the OpenCode
session in one pass. Inspired by [tuicr](https://github.com/agavra/tuicr).

The agent already handles PR creation (`gh` CLI) and merging (git). The gap
is the review-and-feedback loop: batch-review changes after OpenCode finishes,
leave comments, send them to the agent, re-review after fixes.

### Workflow

1. Open diffview for the current worktree's diff against main (`<leader>wr`)
2. Navigate the diff, leave comments on lines/ranges
3. Submit review -- comments are formatted as structured markdown and sent
   to the worktree's OpenCode session via `api_client:create_message()`
4. Agent works through the comments; re-review if needed

### What exists

- **diffview.nvim** (installed) -- handles diff rendering, file panel,
  hunk navigation. No commenting support, but has hooks and a Lua API.
- **opencode API** -- `api_client:create_message(session_id, params)` can
  send structured text to any session programmatically. No UI interaction
  needed.
- **neovia.worktree** -- already tracks per-worktree state and session IDs.
- Nothing in the Neovim ecosystem does local code review with commenting.

### Design

A `neovia.review` module on top of diffview.nvim:

- **Comments:** attach to lines/ranges in diff buffers via extmarks/virtual
  text. Keymaps: `c` for line comment, `v`+`c` for range comment, `dd` to
  delete, `i` to edit. Optional comment types (issue/suggestion/note) for
  agent prioritisation -- not required for v1.
- **Storage:** in-memory per-worktree, keyed by file path + line range.
  Persist to `stdpath("state")/review/<hash>.json` so comments survive
  Neovim restarts.
- **Submit:** format all comments as numbered markdown with file:line
  anchors, send to the worktree's OpenCode session. The agent receives a
  single message like:
  ```
  Review comments on your changes. Address each one:
  1. src/foo.lua:42 - this will break on nil input
  2. src/bar.lua:15-20 - extract this into a helper
  ```
- **Auto-resolution:** listen to `on_file_edited(file)` and
  `OpencodeEvent:session.idle` from opencode.nvim. When the agent edits a
  file, check if review comments on that file are still relevant by
  re-diffing the line ranges. On `session.idle`, do a full pass: comments
  on lines that changed since submission are marked "addressed"; comments
  on unchanged lines persist. No need for the agent to explicitly
  reference comment numbers -- the file edits are the signal.
- **Re-review:** after auto-resolution, refresh diffview. Remaining
  (unresolved) comments are still visible. User can submit another round
  or approve.

