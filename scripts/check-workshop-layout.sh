#!/usr/bin/env bash
# R6.01: native blockout evidence, never production resolution acceptance.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
if (( $# != 0 )); then echo "Usage: $0" >&2; exit 2; fi
if [[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
  echo "R6.01 requires a graphical session; headless geometry is not visual acceptance." >&2
  exit 2
fi
output="${VELORA_WORKSHOP_REPORT_DIR:-$(mktemp -d /tmp/velora-workshop-layout.XXXXXX)}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
display_args=()
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then display_args=(--display-driver wayland --rendering-driver opengl3); fi
"$script_dir/build-bridge.sh"
run_fixture() {
  local name="$1" script="$2"
  local log="$output/$name.log"
  set +e
  timeout --signal=TERM --kill-after=5s 180s godot \
    --disable-crash-handler --audio-driver Dummy "${display_args[@]}" \
    --resolution 1280x720 --path "$repo_dir/frontend/godot" --script "$script" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  if (( status != 0 )); then return "$status"; fi
  if rg -q 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script|Failed loading resource' "$log"; then
    echo "R6.01 $name fixture has a script/resource error." >&2
    return 1
  fi
}
for width in 320 640; do
  mkdir -p "$output/$width"
  export VELORA_WORKSHOP_WIDTH="$width"
  VELORA_WORKSHOP_REPORT_DIR="$output/$width" run_fixture "layout-$width" res://tests/workshop_visual_fixture.gd
  for workload in movement crowded; do
    VELORA_WORKSHOP_WORKLOAD="$workload" VELORA_PHASE_SIX_PERF_REPORT="$output/$workload-$width.json" \
      run_fixture "$workload-$width" res://tests/workshop_performance.gd
  done
done
echo "PASS: isolated R6.01 native layout/physics/performance evidence: $output"
echo "PENDING: owner density choice; no production resolution or art acceptance."
