#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/../frontend/godot" && pwd)"
report_path="${VELORA_PERF_REPORT:-/tmp/velora-performance.json}"
display_args=()
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  display_args=(--display-driver wayland --rendering-driver opengl3)
fi

echo "Running the rendered P1.10 benchmark; a Godot window will open briefly."
VELORA_PERF_REPORT="$report_path" godot \
  "${display_args[@]}" \
  --path "$project_dir" \
  --benchmark \
  --benchmark-file /tmp/velora-godot-benchmark.json \
  --script res://tests/performance_validation.gd

echo "Performance report: $report_path"
