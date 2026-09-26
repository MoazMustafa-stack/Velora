#!/usr/bin/env bash
# P5.12 resource gate: compare Core with D-Bus integrations disabled and
# enabled on a private session bus. The test never contacts the live bus.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
test_dir="$(mktemp -d /tmp/velora-dbus-resources.XXXXXX)"
bus_pid=""
core_pid=""

cleanup() {
  if [[ -n "$core_pid" ]] && kill -0 "$core_pid" 2>/dev/null; then
    kill -INT "$core_pid" 2>/dev/null || true
    wait "$core_pid" 2>/dev/null || true
  fi
  if [[ -n "$bus_pid" ]] && kill -0 "$bus_pid" 2>/dev/null; then
    kill "$bus_pid" 2>/dev/null || true
    wait "$bus_pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

command -v dbus-daemon >/dev/null 2>&1 || {
  echo "missing dependency: dbus-daemon" >&2
  exit 1
}

mkdir -p "$test_dir/runtime" "$test_dir/data/applications" "$test_dir/system-data/applications"
chmod 700 "$test_dir/runtime"

dbus-daemon --session --nofork --print-address=1 >"$test_dir/bus-address" 2>"$test_dir/bus.log" &
bus_pid=$!
for _attempt in {1..100}; do
  [[ -s "$test_dir/bus-address" ]] && break
  kill -0 "$bus_pid" 2>/dev/null || { cat "$test_dir/bus.log" >&2; exit 1; }
  sleep 0.02
done
[[ -s "$test_dir/bus-address" ]] || { echo "private D-Bus did not publish an address" >&2; exit 1; }
bus_address="$(head -n 1 "$test_dir/bus-address")"

(cd "$repo_dir" && cargo build --release -p velora-core --quiet)

start_core() {
  local mode="$1"
  local media_enabled="$2"
  local notifications_enabled="$3"
  local socket_path="$test_dir/runtime/velora-$mode.sock"

  XDG_RUNTIME_DIR="$test_dir/runtime" \
  XDG_DATA_HOME="$test_dir/data" \
  XDG_DATA_DIRS="$test_dir/system-data" \
  HYPRLAND_INSTANCE_SIGNATURE= \
  VELORA_SOCKET="$socket_path" \
  VELORA_SESSION_BUS_ADDRESS="$bus_address" \
  VELORA_TELEMETRY_ENABLED=false \
  VELORA_MEDIA_ENABLED="$media_enabled" \
  VELORA_NOTIFICATIONS_ENABLED="$notifications_enabled" \
    "$repo_dir/target/release/velora-core" >"$test_dir/core-$mode.log" 2>&1 &
  core_pid=$!

  for _attempt in {1..100}; do
    [[ -S "$socket_path" ]] && return 0
    kill -0 "$core_pid" 2>/dev/null || { cat "$test_dir/core-$mode.log" >&2; return 1; }
    sleep 0.05
  done
  cat "$test_dir/core-$mode.log" >&2
  return 1
}

rss_kib() {
  awk '/VmRSS/ {print $2}' "/proc/$core_pid/status"
}

stop_core() {
  kill -INT "$core_pid"
  wait "$core_pid"
  core_pid=""
}

start_core baseline false false
sleep 1
baseline_rss="$(rss_kib)"
stop_core

start_core active true true
sleep 1
active_rss_early="$(rss_kib)"
read -r active_utime_early active_stime_early < <(awk '{print $14, $15}' "/proc/$core_pid/stat")
sleep 5
active_rss_late="$(rss_kib)"
read -r active_utime_late active_stime_late < <(awk '{print $14, $15}' "/proc/$core_pid/stat")
stop_core

clock_ticks="$(getconf CLK_TCK)"
cpu_ticks=$(( (active_utime_late - active_utime_early) + (active_stime_late - active_stime_early) ))
cpu_basis_points=$(( 10000 * cpu_ticks / (clock_ticks * 5) ))
dbus_overhead_kib=$(( active_rss_late - baseline_rss ))
active_growth_kib=$(( active_rss_late - active_rss_early ))

echo "Private-bus idle CPU: $((cpu_basis_points / 100)).$((cpu_basis_points % 100))% of one core"
echo "Core RSS: baseline=${baseline_rss} KiB active=${active_rss_late} KiB overhead=${dbus_overhead_kib} KiB"
echo "Active D-Bus RSS growth: ${active_growth_kib} KiB"

if (( cpu_basis_points > 50 )); then
  echo "P5.12 gate failed: idle D-Bus CPU exceeds 0.50%" >&2
  exit 1
fi
if (( dbus_overhead_kib > 3072 )); then
  echo "P5.12 gate failed: fixed D-Bus RSS overhead exceeds the measured 3 MiB ceiling" >&2
  exit 1
fi
if (( active_growth_kib > 1024 )); then
  echo "P5.12 gate failed: active D-Bus RSS grew by more than 1 MiB" >&2
  exit 1
fi

echo "PASS: P5.12 media/notification resource budgets hold on a private bus"
