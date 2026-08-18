#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
godot_project="$repo_dir/frontend/godot"

usage() {
  cat <<'EOF'
Velora development runner

Usage: ./scripts/velora.sh [command]

Commands:
  run     Launch the pixel hub directly (default)
  edit    Open the project in the Godot editor
  check   Run Godot acceptance tests and Rust checks
  perf    Run the rendered integrated-graphics benchmark
  all     Run acceptance, Rust, and performance checks
  core    Run the Rust core daemon
  help    Show this help
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    return 1
  fi
}

command_name="${1:-run}"

case "$command_name" in
  run)
    require_command godot
    exec godot --path "$godot_project"
    ;;
  edit)
    require_command godot
    exec godot --editor --path "$godot_project"
    ;;
  check|test)
    "$script_dir/check-godot.sh"
    "$script_dir/check.sh"
    ;;
  perf|performance)
    "$script_dir/check-performance.sh"
    ;;
  all)
    "$script_dir/check-godot.sh"
    "$script_dir/check.sh"
    "$script_dir/check-performance.sh"
    ;;
  core)
    exec "$script_dir/run-core.sh"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $command_name" >&2
    usage >&2
    exit 2
    ;;
esac
