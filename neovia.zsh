#!/usr/bin/env zsh
# neovia.zsh -- launch Neovim with the neovia config.
# Starts an opencode server (if not already running) so it survives
# Neovim restarts. The server port is persisted to a state directory
# keyed by the git repo so multiple repos each get their own server.

set -euo pipefail

# ── State directory ──────────────────────────────────────────────────
# Must match the hash in lua/neovia/server.lua:state_dir().
_neovia_state_dir() {
  local git_common_dir="$1"
  local hash=$(printf '%s' "$git_common_dir" | shasum -a 256 | cut -c1-16)
  local base="${XDG_STATE_HOME:-$HOME/.local/state}/neovia/server/$hash"
  echo "$base"
}

# ── PID liveness check ──────────────────────────────────────────────
_neovia_pid_alive() {
  kill -0 "$1" 2>/dev/null
}

# ── Ensure the opencode server is running ────────────────────────────
_neovia_ensure_server() {
  local git_common_dir
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0

  # Resolve to absolute path
  [[ "$git_common_dir" = /* ]] || git_common_dir="$PWD/$git_common_dir"
  git_common_dir=$(cd "$(dirname "$git_common_dir")" && echo "$PWD/$(basename "$git_common_dir")")
  # Strip trailing slash
  git_common_dir="${git_common_dir%/}"

  local state_dir
  state_dir=$(_neovia_state_dir "$git_common_dir")
  mkdir -p "$state_dir"

  local port_file="$state_dir/port"
  local pid_file="$state_dir/pid"
  local log_file="$state_dir/server.log"

  # Check for existing server
  if [[ -f "$pid_file" ]] && [[ -f "$port_file" ]]; then
    local existing_pid=$(< "$pid_file")
    if _neovia_pid_alive "$existing_pid"; then
      # Server already running
      export NEOVIA_SERVER_PORT=$(< "$port_file")
      return 0
    fi
    # Stale files, clean up
    rm -f "$port_file" "$pid_file"
  fi

  # Start the server
  echo "neovia: starting opencode server..."

  # Use a fifo to capture the URL from stdout while backgrounding
  local fifo="$state_dir/startup.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"

  # Launch server, tee stdout to fifo and log, stderr to log
  opencode serve --port 0 > >(tee "$fifo" >> "$log_file") 2>> "$log_file" &
  local server_pid=$!
  disown "$server_pid" 2>/dev/null

  # Read the listening URL from the fifo (with timeout)
  local line=""
  local port=""
  if read -t 10 line < "$fifo"; then
    port=$(echo "$line" | grep -oE '[0-9]+$')
  fi
  rm -f "$fifo"

  if [[ -z "$port" ]]; then
    echo "neovia: failed to start opencode server" >&2
    return 1
  fi

  # Persist server info
  echo "$port" > "$port_file"
  echo "$server_pid" > "$pid_file"
  export NEOVIA_SERVER_PORT="$port"

  echo "neovia: opencode server running on port $port (pid $server_pid)"
}

# ── Main ─────────────────────────────────────────────────────────────
_neovia_ensure_server
NVIM_APPNAME=neovia nvim "$@"
