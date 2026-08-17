# Velora

> [!WARNING]
> **Work in progress.** Velora is an early experimental prototype. Its APIs,
> visual direction, and Linux integrations are expected to change.

[![Status: work in progress](https://img.shields.io/badge/status-work_in_progress-f59e0b)](#project-status)
[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e)](LICENSE)

Velora is an experimental spatial 3D desktop interface for Linux. It runs
*inside* an existing Omarchy + Hyprland session, making applications, projects,
and system state feel tangible without replacing the desktop underneath.

## Why Velora?

Velora explores a desktop where spaces are navigable, applications are
interactive objects, and system state is visual—while conventional shortcuts,
launchers, and window management remain the fastest path when they matter.

## Project status

The project is currently a vertical-slice prototype. It is safe by design:
Hyprland stays in charge, Omarchy configuration is never overwritten, and the
normal desktop remains available if Velora exits.

## Current status

The v0.1 bootstrap provides a Godot 4 spatial-room prototype and a separate
Rust core daemon. The frontend has first-person movement, mouse look, a
raycast interaction prompt, and a VS Code terminal. The core exposes a
newline-delimited JSON protocol over a Unix socket with `ping` / `pong` and a
safe, semantic `launch_app` request.

Godot was not installed during the initial audit, so graphical validation is
pending. No Omarchy configuration was changed.

## Run

In separate terminals:

```bash
./scripts/run-core.sh
./scripts/run-velora.sh
```

Install Godot 4 first if needed: `omarchy pkg add godot`.

## Controls

`WASD` move, mouse look, `Shift` sprint, `E` interact, `Escape` releases or
recaptures the mouse.

See [development documentation](docs/development.md) for checks and the
[Omarchy integration notes](docs/omarchy-integration.md) for safety boundaries.

## Contributing

Contributions are welcome once the initial prototype has settled. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and report security-sensitive issues using
[SECURITY.md](SECURITY.md), not a public issue.
