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
godot_log="$velora_check_dir/godot.log"

set +e
godot --headless --disable-crash-handler --path "$project_dir" --quit-after 5 2>&1 | tee "$godot_log"
godot_status=${PIPESTATUS[0]}
set -e

if (( godot_status != 0 )); then
  exit "$godot_status"
fi

if rg -q 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Failed loading resource' "$godot_log"; then
  echo "Godot script or resource validation failed." >&2
  exit 1
fi

echo "Godot scene validation passed."
godot --headless --disable-crash-handler --path "$project_dir" --script res://tests/phase1_validation.gd

