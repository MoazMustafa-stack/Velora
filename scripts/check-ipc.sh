#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
project_dir="$repo_dir/frontend/godot"
test_dir="$(mktemp -d /tmp/velora-ipc-check.XXXXXX)"
core_pid=""

cleanup() {
  if [[ -n "$core_pid" ]] && kill -0 "$core_pid" 2>/dev/null; then
    kill "$core_pid" 2>/dev/null || true
    wait "$core_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$test_dir/runtime"
export XDG_DATA_HOME="$test_dir/data"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_CACHE_HOME="$test_dir/cache"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

"$script_dir/build-bridge.sh"
cargo build --manifest-path "$repo_dir/Cargo.toml" -p velora-core
"$repo_dir/target/debug/velora-core" >"$test_dir/core.log" 2>&1 &
core_pid=$!

for _attempt in {1..200}; do
  [[ -S "$XDG_RUNTIME_DIR/velora.sock" ]] && break
  kill -0 "$core_pid" 2>/dev/null || {
    cat "$test_dir/core.log" >&2
    exit 1
  }
  sleep 0.05
done

if [[ ! -S "$XDG_RUNTIME_DIR/velora.sock" ]]; then
  cat "$test_dir/core.log" >&2
  echo "Velora Core did not create its test socket." >&2
  exit 1
fi

godot --headless --disable-crash-handler --path "$project_dir" --script res://tests/ipc_validation.gd
echo "Native IPC integration validation passed."
