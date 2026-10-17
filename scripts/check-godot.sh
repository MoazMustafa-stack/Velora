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
# An inherited production override must not bypass the isolated runtime dir.
export VELORA_SOCKET="$XDG_RUNTIME_DIR/velora.sock"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

project_dir="$(cd "$script_dir/../frontend/godot" && pwd)"
test_timeout="${VELORA_TEST_TIMEOUT_SECONDS:-120}"
if [[ ! "$test_timeout" =~ ^[1-9][0-9]*$ ]] || (( test_timeout > 600 )); then
  echo "VELORA_TEST_TIMEOUT_SECONDS must be an integer from 1 to 600." >&2
  exit 2
fi
run_godot() {
  local name="$1"
  shift
  local godot_log="$velora_check_dir/$name.log"

  set +e
  timeout --signal=TERM --kill-after=5s "${test_timeout}s" \
    godot --headless --disable-crash-handler --path "$project_dir" "$@" 2>&1 | tee "$godot_log"
  local godot_status=${PIPESTATUS[0]}
  set -e

  if (( godot_status != 0 )); then
    echo "Godot $name validation exited with status $godot_status (124 means timeout)." >&2
    return "$godot_status"
  fi
  if rg -q 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Failed loading resource' "$godot_log"; then
    echo "Godot $name validation reported a script or resource error." >&2
    return 1
  fi
}

run_godot scene --quit-after 5
run_godot design-tokens --script res://tests/design_tokens_validation.gd
run_godot workshop-layout --script res://tests/workshop_layout_validation.gd
run_godot workshop-art --script res://tests/workshop_art_validation.gd
run_godot workshop-view --script res://tests/workshop_view_validation.gd
run_godot application-selection --script res://tests/application_selection_validation.gd
run_godot panel-primitives --script res://tests/panel_primitives_validation.gd
run_godot settings --script res://tests/settings_validation.gd
run_godot overlays --script res://tests/overlay_validation.gd
run_godot input-actions --script res://tests/input_actions_validation.gd
run_godot hud-layout --script res://tests/hud_layout_validation.gd
run_godot telemetry-ui --script res://tests/telemetry_ui_validation.gd
run_godot empty-states --script res://tests/empty_states_validation.gd
run_godot onboarding --script res://tests/onboarding_validation.gd
run_godot pause --script res://tests/pause_validation.gd
run_godot preferences-ui --script res://tests/preferences_ui_validation.gd
run_godot preferences-failure --script res://tests/preferences_failure_validation.gd
run_godot accessibility --script res://tests/accessibility_validation.gd
run_godot reduced-motion --script res://tests/reduced_motion_validation.gd
run_godot world-art --script res://tests/world_art_validation.gd
run_godot world-layout --script res://tests/world_layout_validation.gd
run_godot audio --script res://tests/audio_validation.gd
run_godot audio-wiring --script res://tests/audio_wiring_validation.gd
run_godot remapping --script res://tests/remapping_validation.gd
run_godot controller --script res://tests/controller_validation.gd
VELORA_TEST_CONTROLLER=1 run_godot controller-world --script res://tests/world_layout_validation.gd
VELORA_TEST_REMAPPED=1 run_godot remapped-world --script res://tests/world_layout_validation.gd
run_godot mapping-model --script res://tests/station_mapping_model_validation.gd
run_godot mapping-ui --script res://tests/station_mapping_ui_validation.gd
run_godot phase-six-acceptance --script res://tests/phase_six_acceptance.gd

echo "Godot scene validation passed."
bash "$script_dir/check-bridge-worker.sh"
bash "$script_dir/check-bridge-worker.sh" backlog
run_godot phase1 --script res://tests/phase1_validation.gd
run_godot stations --script res://tests/station_validation.gd
run_godot launch-ux --script res://tests/launch_ux_validation.gd
run_godot backend-client --script res://tests/backend_client_validation.gd
run_godot restart-state --script res://tests/restart_state_validation.gd
run_godot workspace-map --script res://tests/workspace_map_validation.gd
run_godot session-binding --script res://tests/session_binding_validation.gd
run_godot notification-feed --script res://tests/notification_validation.gd
run_godot media-client --script res://tests/media_client_validation.gd
run_godot media-console --script res://tests/media_validation.gd
