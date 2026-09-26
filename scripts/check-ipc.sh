#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
project_dir="$repo_dir/frontend/godot"
test_dir="$(mktemp -d /tmp/velora-ipc-check.XXXXXX)"
core_pid=""
godot_pid=""

cleanup() {
  if [[ -n "$godot_pid" ]] && kill -0 "$godot_pid" 2>/dev/null; then
    kill "$godot_pid" 2>/dev/null || true
    wait "$godot_pid" 2>/dev/null || true
  fi
  if [[ -n "$core_pid" ]] && kill -0 "$core_pid" 2>/dev/null; then
    kill -INT "$core_pid" 2>/dev/null || true
    wait "$core_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$test_dir/runtime"
export XDG_DATA_HOME="$test_dir/data"
export XDG_DATA_DIRS="$test_dir/system-data"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_CACHE_HOME="$test_dir/cache"
export VELORA_IPC_TEST_DIR="$test_dir"
export VELORA_MEDIA_ENABLED=false
export VELORA_NOTIFICATIONS_ENABLED=false
mkdir -p \
  "$XDG_RUNTIME_DIR" \
  "$XDG_DATA_HOME/applications" \
  "$XDG_DATA_DIRS/applications" \
  "$XDG_CONFIG_HOME" \
  "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

printf '%s\n' \
  '[Desktop Entry]' \
  'Type=Application' \
  'Name=Velora Test Application' \
  'Exec=/usr/bin/velora-test-never-launch %F' \
  'Icon=utilities-terminal' \
  'Categories=Utility;Test;' \
  'Terminal=false' \
  >"$XDG_DATA_HOME/applications/velora-test.desktop"

for application_number in $(seq -w 1 34); do
  printf '%s\n' \
    '[Desktop Entry]' \
    'Type=Application' \
    "Name=Pagination Fixture $application_number" \
    "Exec=/usr/bin/velora-page-never-launch --fixture $application_number" \
    'Categories=Utility;Test;' \
    'Terminal=false' \
    >"$XDG_DATA_HOME/applications/velora-page-$application_number.desktop"
done

"$script_dir/build-bridge.sh"
cargo build --manifest-path "$repo_dir/Cargo.toml" -p velora-core

start_core() {
  local log_name="$1"
  "$repo_dir/target/debug/velora-core" >"$test_dir/$log_name" 2>&1 &
  core_pid=$!

  for _attempt in {1..200}; do
    [[ -S "$XDG_RUNTIME_DIR/velora.sock" ]] && return 0
    if ! kill -0 "$core_pid" 2>/dev/null; then
      cat "$test_dir/$log_name" >&2
      return 1
    fi
    sleep 0.05
  done

  cat "$test_dir/$log_name" >&2
  echo "Velora Core did not create its test socket." >&2
  return 1
}

wait_for_marker() {
  local marker="$1"
  for _attempt in {1..300}; do
    [[ -f "$test_dir/$marker" ]] && return 0
    if ! kill -0 "$godot_pid" 2>/dev/null; then
      cat "$test_dir/godot.log" >&2
      echo "Godot exited before creating $marker." >&2
      return 1
    fi
    sleep 0.05
  done

  cat "$test_dir/godot.log" >&2
  echo "Timed out waiting for Godot marker $marker." >&2
  return 1
}

start_core "core-first.log"

godot \
  --headless \
  --disable-crash-handler \
  --path "$project_dir" \
  --script res://tests/ipc_validation.gd \
  >"$test_dir/godot.log" 2>&1 &
godot_pid=$!

wait_for_marker "frontend-ready"

kill -INT "$core_pid"
wait "$core_pid"
core_pid=""

if [[ ! -S "$XDG_RUNTIME_DIR/velora.sock" ]]; then
  echo "Core shutdown cleaned its temporary socket."
else
  echo "Core shutdown left its temporary socket behind." >&2
  exit 1
fi

wait_for_marker "frontend-reconnecting"
start_core "core-second.log"

set +e
wait "$godot_pid"
godot_status=$?
set -e
godot_pid=""
cat "$test_dir/godot.log"
if (( godot_status != 0 )); then
  cat "$test_dir/core-first.log" >&2
  cat "$test_dir/core-second.log" >&2
  exit "$godot_status"
fi

echo "Native IPC restart integration validation passed without launching an application."
