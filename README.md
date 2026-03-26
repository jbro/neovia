# neovia

Neovim as the complete AI-driven coding environment. One config, one command.

Neovim >= 0.11 with [OpenCode](https://github.com/sst/opencode) as the AI
assistant. Native LSP, treesitter, git integration, and a minimal plugin set
tuned for a workflow where OpenCode writes the code and you orchestrate.

## Install

```sh
git clone https://github.com/jbr/neovia ~/.config/neovia
```

Add to your `.zshrc`:

```sh
source ~/.config/neovia/neovia.zsh
```

Then open a project:

```sh
neovia .
```

Your existing Neovim config is untouched -- `NVIM_APPNAME=neovia` isolates
everything under neovia-namespaced XDG paths.

## Dependencies

These must be installed separately:

- [neovim](https://neovim.io) (>= 0.11)
- [opencode](https://github.com/sst/opencode)
- [fzf](https://github.com/junegunn/fzf)
- [ripgrep](https://github.com/BurntSushi/ripgrep)
- [fd](https://github.com/sharkdp/fd)
- [git](https://git-scm.com)
- [tree-sitter-cli](https://github.com/tree-sitter/tree-sitter/tree/master/cli)
