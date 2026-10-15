#!/usr/bin/env bash
# D6.13: cumulative automated evidence, not a substitute for owner acceptance.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
mode="${1:---rendered}"
if (( $# > 1 )); then
  echo "Usage: $0 [--rendered|--headless]" >&2
  exit 2
fi
case "$mode" in
  --headless|--rendered) ;;
  *) echo "Usage: $0 [--rendered|--headless]" >&2; exit 2 ;;
esac

# Check before running the slower suite. Never silently certify rendering
# when the environment cannot measure it.
if [[ "$mode" == --rendered && -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
  echo "D6.13 rendered checks require a graphical session." >&2
  echo "Use ./scripts/velora.sh gate --headless for the automated subset." >&2
  exit 2
fi

timeout --signal=TERM --kill-after=10s 900s "$script_dir/check-phase-five.sh"
timeout --signal=TERM --kill-after=10s 180s "$script_dir/check-ipc.sh"
timeout --signal=TERM --kill-after=10s 180s "$script_dir/check-dev.sh"

if [[ "$mode" == --headless ]]; then
  echo "PASS: D6.13 headless automated subset"
  echo "NOT RUN: rendered layout/performance and owner manual acceptance"
else
  "$script_dir/check-phase-six-rendered.sh"
  echo "PASS: D6.13 cumulative automated checks, including rendering"
  echo "PENDING: owner checklist in frontend/godot/RELEASE_REVIEW.md"
fi
