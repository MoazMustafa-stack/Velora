# Velora

> [!WARNING]
> **Work in progress.** Velora is an early experimental prototype. Its APIs,
> visual direction, and Linux integrations are expected to change.

[![Status: work in progress](https://img.shields.io/badge/status-work_in_progress-f59e0b)](#project-status)
[![Phase: pixel hub](https://img.shields.io/badge/phase-pixel_hub-41d6c3)](#current-status)
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

Phase 1.01–1.05 provides a Godot 4.7 pixel-perfect foundation, a 16 px tile
hub, eight-direction movement with four-direction facing, sprinting, physical
room and object boundaries, and a facing-aware workstation interaction.

The visuals are generated from an original restrained palette at runtime, so
the prototype stays tiny and does not ship copied game artwork. A separate Rust
core remains in the repository; Godot deliberately reports it as offline until
the native Unix-socket transport is implemented in Phase 2.

## Run

```bash
./scripts/run-velora.sh
```

The default window is 960 × 540, rendered from a 320 × 180 internal canvas with
integer nearest-neighbour scaling. Install Godot 4.7 first if needed.

## Controls

- `WASD` or arrow keys: move
- `Shift`: sprint
- `E` or `Enter`: interact
- `Escape`: menu hint (full menu is planned)

## Validate

```bash
./scripts/check-godot.sh
./scripts/check.sh
```

The Godot check boots the main scene headlessly and runs acceptance tests for
the P1.01–P1.05 foundation, hub, controller, collisions, and interaction.

See [development documentation](docs/development.md) for checks and the
[Omarchy integration notes](docs/omarchy-integration.md) for safety boundaries.

## Contributing

Contributions are welcome once the initial prototype has settled. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and report security-sensitive issues using
[SECURITY.md](SECURITY.md), not a public issue.
