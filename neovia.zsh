#!/usr/bin/env zsh
# neovia.zsh -- launch Neovim with the neovia config.
# The opencode server is started by neovia.server.ensure_running()
# inside init.lua, so this wrapper only needs to set NVIM_APPNAME.

NVIM_APPNAME=neovia nvim "$@"
