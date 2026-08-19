# Velora

> [!WARNING]
> **Work in progress.** Velora is an early experimental prototype. Its APIs,
> visual direction, and Linux integrations are expected to change.

[![Status: work in progress](https://img.shields.io/badge/status-work_in_progress-f59e0b)](#project-status)
[![Phase: native IPC](https://img.shields.io/badge/phase-native_IPC-41d6c3)](#current-status)
[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e)](LICENSE)

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

Phase 1.01–1.10 provides a Godot 4.7 pixel-perfect foundation, a 16 px tile
hub, eight-direction movement with four-direction facing, sprinting, physical
room and object boundaries, and facing-aware application stations. A working
pause/help overlay freezes world input and keeps controls visible in-game.

Phase 2 begins with a native Rust GDExtension that carries protocol v2 messages
over a user-only Unix socket. The frontend performs a hello/welcome handshake,
heartbeat, and reconnect without blocking the Godot main thread. Application
discovery and real launching remain disabled until the next reviewed change.

## Run

Start the core and frontend in separate terminals:

```bash
./scripts/velora.sh core
./scripts/velora.sh run
```

The default window is 960 × 540, rendered from a 320 × 180 internal canvas with
integer nearest-neighbour scaling. Install Godot 4.7 and Rust first if needed.

The unified development runner exposes the common workflows:

```bash
./scripts/velora.sh edit          # build the bridge and open Godot
./scripts/velora.sh build-bridge  # compile the Rust GDExtension
./scripts/velora.sh ipc-check     # live core ↔ Godot handshake test
./scripts/velora.sh check         # Godot acceptance tests + Rust workspace
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
./scripts/velora.sh perf
```

The IPC check builds the ignored native library, starts the core on an isolated
temporary socket, and validates handshake plus ping/pong from headless Godot.
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

Contributions are welcome once the initial prototype has settled. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and report security-sensitive issues using
[SECURITY.md](SECURITY.md), not a public issue.
