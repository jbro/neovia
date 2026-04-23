# Ideas

Future ideas and spikes that haven't been scheduled yet.

## ~~Replace netrw with neo-tree + scratch buffer~~ (Done)

Implemented in decision 0010. See AGENTS.md.

## ~~Detach opencode server from Neovim~~ (Implemented -- decision 0010)

## GitHub PR status in worktree tabline

Show PR status per worktree in the tabline. If a worktree's branch has an
open PR, display the CI/review status alongside the opencode status indicator.

- **Data source:** `gh pr status` or GitHub API via `gh api`. Map branch
  name to PR, fetch check suite state and review decision.
- **States:** draft, review requested, approved, changes requested,
  checks passing/failing/pending, merged. Each gets its own icon/colour.
- **Polling:** periodic background fetch (e.g. every 60s) to avoid
  hammering the API. Cache per branch; invalidate on worktree switch.
- **Integration:** extend `TablineEntry` with a `pr` field. `build_tabline`
  renders it after the opencode status indicator.
- **Spike:** measure latency of `gh api` calls; decide whether to shell
  out per-worktree or batch all branches in one call.

## Spikes
