#!/usr/bin/env bash
# Capture synthetic viewports only; never record the desktop or live content.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
if [[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
  echo "D6.13 rendered validation requires a graphical session." >&2
  exit 2
fi

output_dir="${VELORA_PHASE_SIX_REPORT_DIR:-$(mktemp -d /tmp/velora-phase-six.XXXXXX)}"
mkdir -p "$output_dir/frames"
output_dir="$(cd "$output_dir" && pwd)"
display_args=()
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  display_args=(--display-driver wayland --rendering-driver opengl3)
fi

"$script_dir/build-bridge.sh"
run_fixture() {
  local name="$1"
  shift
  local log="$output_dir/$name.log"
  set +e
  timeout --signal=TERM --kill-after=5s 120s godot \
    --disable-crash-handler --audio-driver Dummy "${display_args[@]}" \
    --path "$repo_dir/frontend/godot" "$@" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  if (( status != 0 )); then return "$status"; fi
  if rg -q 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Failed loading resource' "$log"; then
    echo "Rendered $name fixture reported a script/resource error." >&2
    return 1
  fi
}

VELORA_VISUAL_DIR="$output_dir/frames" run_fixture layouts --script res://tests/experience_visual_fixture.gd
VELORA_WORKSHOP_STYLE_DIR="$output_dir/frames" run_fixture workshop-style --script res://tests/workshop_style_capture.gd
VELORA_WORKSHOP_PRODUCTION_DIR="$output_dir/frames" run_fixture workshop-production --script res://tests/workshop_production_fixture.gd
VELORA_PERF_REPORT="$output_dir/movement-performance.json" run_fixture movement --script res://tests/performance_validation.gd
VELORA_PHASE_SIX_PERF_REPORT="$output_dir/crowded-performance.json" run_fixture crowded --script res://tests/phase_six_performance.gd
bash "$script_dir/check-workshop-layout.sh"
echo "PASS: D6.13 synthetic rendered layout and performance checks"
echo "Retained evidence: $output_dir"
