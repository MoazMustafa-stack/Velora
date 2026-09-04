#!/usr/bin/env bash
# P4.12 release gate: deterministic Phase 4 telemetry validation.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
cd "$repo_dir"

cargo fmt --all --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
"$script_dir/check-godot.sh"
"$script_dir/check-security.sh"
"$script_dir/check-core-resources.sh"

echo "PASS: P4.12 Phase 4 release gate"
