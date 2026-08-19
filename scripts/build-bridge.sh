#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
profile="${1:-debug}"

case "$profile" in
  debug)
    cargo_args=()
    cargo_profile="debug"
    ;;
  release)
    cargo_args=(--release)
    cargo_profile="release"
    ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 2
    ;;
esac

cargo build --manifest-path "$repo_dir/Cargo.toml" -p velora-bridge "${cargo_args[@]}"
install -Dm755 \
  "$repo_dir/target/$cargo_profile/libvelora_bridge.so" \
  "$repo_dir/frontend/godot/bin/libvelora_bridge.so"

echo "Built Velora bridge: frontend/godot/bin/libvelora_bridge.so"
