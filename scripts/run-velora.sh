#!/usr/bin/env bash
set -euo pipefail
if ! command -v godot >/dev/null 2>&1; then
  echo "Godot 4 is required. Install it with: omarchy pkg add godot" >&2
  exit 1
fi
cd "$(dirname "$0")/../frontend/godot"
exec godot --editor project.godot
