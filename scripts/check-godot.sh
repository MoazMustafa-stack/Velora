#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
"$script_dir/build-bridge.sh"

velora_check_dir="$(mktemp -d /tmp/velora-godot-check.XXXXXX)"
trap 'rm -rf "$velora_check_dir"' EXIT

export XDG_DATA_HOME="$velora_check_dir/data"
export XDG_CONFIG_HOME="$velora_check_dir/config"
export XDG_CACHE_HOME="$velora_check_dir/cache"
export XDG_RUNTIME_DIR="$velora_check_dir/runtime"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

project_dir="$(cd "$script_dir/../frontend/godot" && pwd)"
run_godot() {
  local name="$1"
  shift
  local godot_log="$velora_check_dir/$name.log"

  set +e
  godot --headless --disable-crash-handler --path "$project_dir" "$@" 2>&1 | tee "$godot_log"
  local godot_status=${PIPESTATUS[0]}
  set -e

  if (( godot_status != 0 )); then
    echo "Godot $name validation exited with status $godot_status." >&2
    return "$godot_status"
  fi
  if rg -q 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Failed loading resource' "$godot_log"; then
    echo "Godot $name validation reported a script or resource error." >&2
    return 1
  fi
}

run_godot scene --quit-after 5

echo "Godot scene validation passed."
run_godot phase1 --script res://tests/phase1_validation.gd
run_godot stations --script res://tests/station_validation.gd
run_godot launch-ux --script res://tests/launch_ux_validation.gd
run_godot backend-client --script res://tests/backend_client_validation.gd
run_godot workspace-map --script res://tests/workspace_map_validation.gd
run_godot session-binding --script res://tests/session_binding_validation.gd
run_godot notification-feed --script res://tests/notification_validation.gd
