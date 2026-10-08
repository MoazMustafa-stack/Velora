#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_dir="$(mktemp -d /tmp/velora-bridge-worker.XXXXXX)"
peer_pid=""
cleanup() {
  if [[ -n "$peer_pid" ]]; then
    kill -TERM "$peer_pid" 2>/dev/null || true
    wait "$peer_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
mode="${1:-write}"
[[ "$mode" == "write" || "$mode" == "backlog" ]] || exit 2
python3 "$script_dir/bridge-peer-fixture.py" "$test_dir" "$mode" &
peer_pid=$!
for _attempt in {1..100}; do
  if [[ -S "$test_dir/peer.sock" ]] && { [[ "$mode" == "write" ]] || [[ -f "$test_dir/ready" ]]; }; then break; fi
  kill -0 "$peer_pid" 2>/dev/null || { echo "Bridge peer failed" >&2; exit 1; }
  sleep 0.02
done
[[ -S "$test_dir/peer.sock" ]] || { echo "Bridge peer did not bind" >&2; exit 1; }
export VELORA_BRIDGE_TEST_DIR="$test_dir"
export VELORA_BRIDGE_TEST_MODE="$mode"
export XDG_DATA_HOME="$test_dir/data"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_CACHE_HOME="$test_dir/cache"
set +e
timeout --kill-after=2s 6s godot --headless --disable-crash-handler \
  --path "$repo_dir/frontend/godot" --script res://tests/bridge_worker_validation.gd \
  >"$test_dir/godot.log" 2>&1
status=$?
set -e
cat "$test_dir/godot.log"
if (( status != 0 )); then
  echo "Bridge lifecycle regression failed or timed out (status $status)." >&2
  exit "$status"
fi
if rg -q 'SCRIPT ERROR|Parse Error|Compile Error|FAIL' "$test_dir/godot.log"; then exit 1; fi
