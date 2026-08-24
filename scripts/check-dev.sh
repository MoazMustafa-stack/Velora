#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d /tmp/velora-dev-check.XXXXXX)"
dev_pid=""

cleanup() {
  if [[ -n "$dev_pid" ]] && kill -0 "$dev_pid" 2>/dev/null; then
    kill -TERM "$dev_pid" 2>/dev/null || true
    wait "$dev_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$test_dir/runtime"
export XDG_DATA_HOME="$test_dir/data"
export XDG_DATA_DIRS="$test_dir/system-data"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_CACHE_HOME="$test_dir/cache"
export VELORA_SOCKET="$XDG_RUNTIME_DIR/velora.sock"
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_DATA_DIRS" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

write_fake_godot() {
  local mode="$1"
  local fake_godot="$test_dir/fake-godot-$mode"

  if [[ "$mode" == "exit" ]]; then
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'test -S "$VELORA_SOCKET"' \
      'exit 0' \
      >"$fake_godot"
  else
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'test -S "$VELORA_SOCKET"' \
      'printf "%s\\n" "$$" >"$VELORA_DEV_TEST_GODOT_PID"' \
      'while true; do sleep 1; done' \
      >"$fake_godot"
  fi
  chmod 755 "$fake_godot"
  printf '%s\n' "$fake_godot"
}

fake_godot="$(write_fake_godot exit)"
VELORA_DEV_GODOT_BIN="$fake_godot" "$script_dir/velora.sh" dev
if [[ -e "$VELORA_SOCKET" ]]; then
  echo "P2.11 normal Godot exit left a Core socket behind." >&2
  exit 1
fi
echo "PASS: P2.11 waits for Core before starting Godot and cleans up on normal exit"

fake_godot="$(write_fake_godot signal)"
export VELORA_DEV_TEST_GODOT_PID="$test_dir/fake-godot.pid"
VELORA_DEV_GODOT_BIN="$fake_godot" "$script_dir/velora.sh" dev >"$test_dir/dev.log" 2>&1 &
dev_pid=$!

for _attempt in {1..200}; do
  [[ -S "$VELORA_SOCKET" && -s "$VELORA_DEV_TEST_GODOT_PID" ]] && break
  if ! kill -0 "$dev_pid" 2>/dev/null; then
    cat "$test_dir/dev.log" >&2
    echo "P2.11 development supervisor exited before starting its children." >&2
    exit 1
  fi
  sleep 0.05
done

if [[ ! -S "$VELORA_SOCKET" || ! -s "$VELORA_DEV_TEST_GODOT_PID" ]]; then
  cat "$test_dir/dev.log" >&2
  echo "P2.11 development supervisor did not start both children." >&2
  exit 1
fi

fake_godot_pid="$(<"$VELORA_DEV_TEST_GODOT_PID")"
set +e
kill -TERM "$dev_pid"
wait "$dev_pid"
dev_status=$?
set -e
dev_pid=""

if (( dev_status != 143 )); then
  cat "$test_dir/dev.log" >&2
  echo "P2.11 development supervisor returned $dev_status after TERM; expected 143." >&2
  exit 1
fi
if [[ -e "$VELORA_SOCKET" ]]; then
  echo "P2.11 signal cleanup left a Core socket behind." >&2
  exit 1
fi
if kill -0 "$fake_godot_pid" 2>/dev/null; then
  echo "P2.11 signal cleanup left Godot running." >&2
  exit 1
fi

echo "PASS: P2.11 signal cleanup stops only the development children"
