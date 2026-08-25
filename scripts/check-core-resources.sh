#!/usr/bin/env bash
# P3.12 release gate: measure idle Core CPU and RSS against the Phase 3
# budgets (Core idle below 1% of one CPU; no sustained memory growth).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}
require_command cargo

runtime_dir="$(mktemp -d)"
socket_path="$runtime_dir/velora-resources.sock"
samples_dir="$runtime_dir/samples"
mkdir -p "$samples_dir"
core_pid=""

cleanup() {
  if [[ -n "$core_pid" ]] && kill -0 "$core_pid" 2>/dev/null; then
    kill "$core_pid" 2>/dev/null || true
    wait "$core_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

echo "Building Core (release profile for representative idle cost)..."
( cd "$repo_dir" && cargo build --release -p velora-core --quiet )

XDG_RUNTIME_DIR="$runtime_dir" \
HYPRLAND_INSTANCE_SIGNATURE= \
VELORA_SOCKET="$socket_path" \
  "$repo_dir/target/release/velora-core" &
core_pid=$!

for _ in $(seq 1 100); do
  [[ -S "$socket_path" ]] && break
  sleep 0.1
done
[[ -S "$socket_path" ]] || { echo "Core socket never appeared" >&2; exit 1; }

sample() {
  local label="$1"
  local stat status
  stat="$(cat "/proc/$core_pid/stat")"
  status="$(cat "/proc/$core_pid/status")"
  local utime stime rss
  utime="$(awk '{print $14}' <<<"$stat")"
  stime="$(awk '{print $15}' <<<"$stat")"
  rss="$(awk '/VmRSS/ {print $2}' <<<"$status")"
  printf '%s %s %s\n' "$utime" "$stime" "$rss" > "$samples_dir/$label"
}

sleep 1
sample early
sleep 5
sample late
sleep 1
sample final

clock_ticks=$(getconf CLK_TCK)
read -r u1 s1 r1 < "$samples_dir/early"
read -r u2 s2 r2 < "$samples_dir/late"
read -r _ _ r3 < "$samples_dir/final"

cpu_ticks=$(( (u2 - u1) + (s2 - s1) ))
interval_seconds=5
cpu_percent=$(( 100 * cpu_ticks / (clock_ticks * interval_seconds) ))

rss_kib_early="$r1"
rss_kib_late="$r2"
growth_kib=$(( rss_kib_late - rss_kib_early ))

echo "Core idle CPU: ${cpu_percent}% of one core over ${interval_seconds}s"
echo "Core RSS: early=${rss_kib_early} KiB late=${rss_kib_late} KiB final=${r3} KiB"
echo "Core RSS growth over sample window: ${growth_kib} KiB"

if (( cpu_percent > 1 )); then
  echo "P3.12 gate failed: idle CPU ${cpu_percent}% exceeds the 1% budget" >&2
  exit 1
fi
if (( growth_kib > 2048 )); then
  echo "P3.12 gate failed: RSS grew by ${growth_kib} KiB while idle" >&2
  exit 1
fi
if (( rss_kib_late > 65536 )); then
  echo "P3.12 gate failed: idle RSS ${rss_kib_late} KiB exceeds the 64 MiB ceiling" >&2
  exit 1
fi

echo "PASS: P3.12 core resource budgets hold at idle."
