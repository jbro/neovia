# neovia.zsh -- source this from .zshrc
# Provides the `neovia` command that launches Neovim with isolated config.

neovia() {
  NVIM_APPNAME=neovia nvim "$@"
}
