#!/usr/bin/env bash
# P5.12 cumulative release gate: retain every Phase 4 check, then enforce the
# private-bus resource budget introduced by Phase 5.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

"$script_dir/check-phase-four.sh"
"$script_dir/check-dbus-resources.sh"

echo "PASS: P5.12 Phase 5 release gate"
