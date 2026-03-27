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
