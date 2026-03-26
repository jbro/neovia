# Ideas

Future ideas and spikes that haven't been scheduled yet.

## Spikes

### Embedded OpenCode TUI in Neovim

Try [opencode.nvim](https://github.com/nickjvandyke/opencode.nvim) and running
`opencode tui` inside Neovim's built-in terminal. Research alternatives.

Key concern: **window management** -- does the TUI render correctly inside
Neovim's terminal buffer? Focus on layout, reflows, and interaction quality.

Motivation: the tool output in the current OpenCode framework (SSE/buffer
approach) is mediocre. An embedded TUI might give a better experience if
rendering works well.

### Strip keybindings to view-only defaults

Unbind all Neovim and plugin keybindings, then selectively add back only what
supports a **view-only** workflow: navigation and window management.

This aligns with decision 0002 (user orchestrates, OpenCode writes). Most
editing bindings are dead weight and add cognitive noise. A minimal keymap
makes the read/navigate/direct loop faster.
