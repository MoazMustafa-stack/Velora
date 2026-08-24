#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
godot_project="$repo_dir/frontend/godot"
godot_bin="${VELORA_DEV_GODOT_BIN:-godot}"
core_bin="${VELORA_DEV_CORE_BIN:-$repo_dir/target/debug/velora-core}"
core_pid=""
godot_pid=""

socket_path() {
  if [[ -n "${VELORA_SOCKET:-}" ]]; then
    printf '%s\n' "$VELORA_SOCKET"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    printf '%s/velora.sock\n' "$XDG_RUNTIME_DIR"
  elif [[ -n "${UID:-}" ]]; then
    printf '/tmp/velora-%s.sock\n' "$UID"
  else
    echo "VELORA_SOCKET, XDG_RUNTIME_DIR, or UID is required for the Core socket." >&2
    return 1
  fi
}

stop_child() {
  local name="$1"
  local pid="$2"
  local signal="$3"

  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping Velora $name (pid $pid)..."
    kill "-$signal" "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  stop_child "Godot" "$godot_pid" TERM
  stop_child "Core" "$core_pid" INT
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_socket() {
  local path="$1"
  local attempt

  for attempt in {1..200}; do
    [[ -S "$path" ]] && return 0
    if ! kill -0 "$core_pid" 2>/dev/null; then
      wait "$core_pid" || true
      echo "Velora Core exited before creating $path." >&2
      return 1
    fi
    sleep 0.05
  done

  echo "Timed out waiting for Velora Core socket: $path" >&2
  return 1
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "Required command not found: cargo" >&2
  exit 1
fi
if ! command -v "$godot_bin" >/dev/null 2>&1; then
  echo "Required command not found: $godot_bin" >&2
  exit 1
fi

core_socket="$(socket_path)"
"$script_dir/build-bridge.sh"
cargo build --manifest-path "$repo_dir/Cargo.toml" -p velora-core

echo "Starting Velora Core..."
"$core_bin" &
core_pid=$!
wait_for_socket "$core_socket"

echo "Starting Godot after Core socket is ready..."
"$godot_bin" --path "$godot_project" &
godot_pid=$!

set +e
wait "$godot_pid"
godot_status=$?
set -e
godot_pid=""
exit "$godot_status"
