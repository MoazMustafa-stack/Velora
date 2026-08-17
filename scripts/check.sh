#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../core"
cargo fmt --check
cargo check
cargo clippy -- -D warnings
cargo test
