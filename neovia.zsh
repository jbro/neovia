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

  # Resolve to absolute, symlink-free path (must match server.lua's
  # vim.uv.fs_realpath canonicalisation so the SHA-256 hashes agree).
  [[ "$git_common_dir" = /* ]] || git_common_dir="$PWD/$git_common_dir"
  git_common_dir=$(realpath "$git_common_dir" 2>/dev/null || echo "$git_common_dir")
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

  # Use a pipe to capture the first line (the URL) from stdout.
  # A wrapper reads one line, writes it to a temp file for the caller,
  # then redirects subsequent stdout directly to the log file.
  local url_file="$state_dir/startup_url"
  rm -f "$url_file"

  opencode serve --port 0 2>> "$log_file" | {
    # Read the first line (the listening URL)
    IFS= read -r first_line
    printf '%s' "$first_line" > "$url_file"
    # Drain remaining stdout to the log (no backpressure)
    cat >> "$log_file"
  } &
  local wrapper_pid=$!
  disown "$wrapper_pid" 2>/dev/null

  # Wait for the URL file to appear (with timeout)
  local elapsed=0
  while [[ ! -s "$url_file" ]] && (( elapsed < 10 )); do
    sleep 0.2
    elapsed=$((elapsed + 1))
  done

  local line=""
  local port=""
  [[ -s "$url_file" ]] && line=$(< "$url_file")
  rm -f "$url_file"
  [[ -n "$line" ]] && port=$(echo "$line" | grep -oE '[0-9]+$')

  # Resolve the actual server PID (the opencode process, not the wrapper).
  # The wrapper's child is the opencode process.
  local server_pid=""
  if [[ -n "$port" ]]; then
    # Find the opencode process listening on this port
    server_pid=$(lsof -ti :"$port" -sTCP:LISTEN 2>/dev/null | head -1)
    # Fallback: use the wrapper PID's child
    if [[ -z "$server_pid" ]]; then
      server_pid=$(pgrep -P "$wrapper_pid" 2>/dev/null | head -1)
    fi
  fi

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
