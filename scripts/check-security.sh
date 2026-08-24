#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
cd "$repo_dir"

reject_pattern() {
  local description="$1"
  local pattern="$2"
  shift 2
  if rg -n "$pattern" "$@"; then
    echo "P2.12 security gate failed: $description" >&2
    exit 1
  fi
}

reject_pattern "Godot must not execute OS commands" 'OS\.execute' frontend/godot --glob '*.gd'
reject_pattern "Rust must not spawn a shell" 'Command::new\([^)]*("|r#")?(sh|bash|zsh|fish)' core/src native
reject_pattern "Rust must not pass shell -c arguments" '\.arg\("-(c|lc)"\)' core/src native
reject_pattern "Velora must not edit Hyprland or Omarchy configuration" '(hyprctl[[:space:]]+keyword|\.config/(hypr|omarchy))' core native frontend scripts --glob '!check-security.sh'

echo "PASS: P2.12 static security boundary checks"
