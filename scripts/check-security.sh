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

# Every untyped zbus Proxy call in production must use one of the audited
# read methods or the fixed six-verb MPRIS mapper. Typed DBusProxy and
# MonitoringProxy calls remain constrained by their generated interfaces.
if rg -nUP '\.call(?:<[^>]+>)?\(\s*(?!player_method\(verb\)|"(?:GetServerInformation|GetNameOwner|GetAll)")' \
  core/src/dbus.rs core/src/mpris.rs; then
  echo "P5.12 security gate failed: D-Bus method is outside the audited allowlist" >&2
  exit 1
fi

for method in Play Pause PlayPause Stop Next Previous; do
  if ! rg -q "MediaControlVerb::${method} => \"${method}\"" core/src/mpris.rs; then
    echo "P5.12 security gate failed: MPRIS allowlist mapping is incomplete for $method" >&2
    exit 1
  fi
done

echo "PASS: P5.12 cumulative static security boundary checks"
