# Velora

> [!WARNING]
> **Work in progress.** Velora is an early experimental prototype. Its APIs,
> visual direction, and Linux integrations are expected to change.

[![Status: work in progress](https://img.shields.io/badge/status-work_in_progress-f59e0b)](#project-status)
[![Phase: 4 — system telemetry](https://img.shields.io/badge/phase-4_system_telemetry-41d6c3)](#current-status)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-22c55e)](LICENSE)
[![CI](https://github.com/MoazMustafa-stack/Velora/actions/workflows/ci.yml/badge.svg)](https://github.com/MoazMustafa-stack/Velora/actions/workflows/ci.yml)
[![Buy me a coffee](https://img.shields.io/badge/Support-Ko--fi-ff5e5b)](https://ko-fi.com/moazmustafa)
[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-00457c)](https://paypal.me/MoazMustafa)

Velora is an experimental pixel-art desktop interface for Linux. It runs
*inside* an existing Omarchy + Hyprland session and represents applications,
projects, and system state as a small top-down world without replacing the
desktop underneath.

## Why Velora?

Velora explores a desktop where spaces are navigable, applications are
interactive objects, and system state is visual—while conventional shortcuts,
launchers, and window management remain available when they are faster.

## Project status

The project is currently a vertical-slice prototype. It is safe by design:
Hyprland stays in charge, Omarchy configuration is never overwritten, and the
normal desktop remains available if Velora exits.

## Current status

Phase 3 is complete. Phase 4 (system telemetry) is code-complete and being
actively developed and merged.

Phase 1.01–1.10 provides a Godot 4.7 pixel-perfect foundation, a 16 px tile
hub, eight-direction movement with four-direction facing, sprinting, physical
room and object boundaries, and facing-aware application stations. A working
pause/help overlay freezes world input and keeps controls visible in-game.

Phase 2 provides a native Rust GDExtension that carries protocol v2 messages
over a user-only Unix socket. The frontend performs a hello/welcome handshake,
heartbeat, and reconnect without blocking the Godot main thread. Core discovers
and parses XDG desktop entries, then sends the filtered application registry to
Godot in bounded pages. Application launches are requested by desktop ID only;
Core re-parses the registered desktop entry and applies its safety policy before
it can create a process.

Phase 3 adds a read-only Hyprland integration over protocol v3. Core probes
Hyprland capabilities without reading configuration or shelling out, normalizes
raw compositor output into validated workspace/window snapshots, and serves live
snapshots over IPC. The Godot frontend renders a keyboard-driven workspace map,
binds application stations to running state conservatively, and switches
workspaces and focuses windows in a fail-closed way using opaque handles —
never via raw commands.

Phase 4 adds a bounded system-telemetry service over protocol v4. A resource-safe
sampler reads CPU, memory, disk, and network activity from `/proc` and
`/sys/class/net`, caches the latest values, and publishes them to an observatory
HUD in the frontend. All sampling honors a user-facing privacy toggle
(`VELORA_TELEMETRY_ENABLED`), and the Phase 4 release gate enforces strict
CPU/RSS budgets so idle telemetry stays near zero cost.

## Run

For normal development, start the complete system with one command:

```bash
./scripts/velora.sh dev
```

It builds the native bridge and Core, waits for Core's socket, launches Godot,
and stops only that Core child when Godot exits or you press Ctrl+C.

You can still start the core and frontend in separate terminals:

```bash
./scripts/velora.sh core
./scripts/velora.sh run
```

The default window is 960 × 540, rendered from a 320 × 180 internal canvas with
integer nearest-neighbour scaling. Install Godot 4.7 and Rust first if needed.

The unified development runner exposes the common workflows:

```bash
./scripts/velora.sh dev           # supervised Core + Godot lifecycle
./scripts/velora.sh edit          # build the bridge and open Godot
./scripts/velora.sh build-bridge  # compile the Rust GDExtension
./scripts/velora.sh ipc-check     # live core ↔ Godot handshake test
./scripts/velora.sh check         # Godot acceptance tests + Rust workspace
./scripts/velora.sh gate          # deterministic security/release checks
./scripts/velora.sh perf          # rendered integrated-GPU benchmark
./scripts/velora.sh all           # all automated and rendered checks
```

## Controls

- `WASD` or arrow keys: move
- `Shift`: sprint
- `E` or `Enter`: interact
- `Escape`: open or close the pause/help menu

## Validate

```bash
./scripts/velora.sh check
./scripts/velora.sh ipc-check
./scripts/velora.sh gate
./scripts/velora.sh perf
```

The IPC check builds the ignored native library, starts Core with an isolated
desktop-entry fixture and temporary socket, then validates handshake, ping/pong,
application-registry transfer, a real Core shutdown, and frontend reconnection.
The performance check opens a rendered window and validates the integrated-GPU
baseline.

### Integrated graphics baseline

P1.10 passed on Intel UHD Graphics (Comet Lake GT2) with Mesa 26.1.7, native
Wayland, and the Godot Compatibility renderer. Across 600 rendered frames at a
960 × 540 window, the prototype averaged 60 FPS with a 17.05 ms p95 and 19.27
ms maximum frame. The repeatable gate requires at least 55 FPS average and at
most 25 ms p95.

Velora remains a normal application inside the existing desktop session and
does not modify Omarchy or Hyprland configuration.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and
the [Code of Conduct](CODE_OF_CONDUCT.md), then open an issue or pull request.
Use the issue templates for bug reports and feature requests. Report
security-sensitive issues using [SECURITY.md](SECURITY.md), not a public issue.

## Support

Velora is free and open source (BSD-3-Clause), and it stays that way — no ads,
no dark patterns, no paywalled pixels. If it's useful to you or just makes you
smile, a coffee keeps the pixels flowing and the dev caffeinated:

- [Ko-fi](https://ko-fi.com/moazmustafa)
- [PayPal](https://paypal.me/MoazMustafa)

Every tip is a mana potion for the project. Thanks for keeping independent,
open-source tinkering alive. ☕⚔️

## Reuse & attribution

Velora is released under the [BSD-3-Clause](LICENSE) license. You are free to
use, modify, and redistribute the code, including in commercial projects. As a
condition of the license, any redistribution (source or binary) must retain the
copyright notice and license text, so credit to Velora and its contributors is
always preserved. Where practical, we also appreciate a link back to this
repository.
