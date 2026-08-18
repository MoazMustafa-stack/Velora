# Development

Requirements: Rust stable and Godot 4.7.

Install Godot through Omarchy if needed:

```bash
omarchy pkg add godot
```

## Pixel hub

Run the frontend from the repository root:

```bash
./scripts/run-velora.sh
```

The main scene is composed from ordinary Godot 2D nodes:

- `World` builds three `TileMapLayer`s: ground, blocking walls, and details.
- `Player` is a `CharacterBody2D` with a small feet collision shape.
- `InteractionDetector` is an `Area2D` moved in front of the current facing.
- `Workstation` is a `StaticBody2D` with a separate interaction area.
- `HUD` is a `CanvasLayer`, so prompts do not move with the world camera.
- `BackendClient` is an offline-safe boundary for the Phase 2 native transport.

All current art is generated deterministically in `pixel_art.gd`. The internal
canvas is 320 × 180 with 16 px tiles and nearest-neighbour integer scaling.

## Checks

Run the complete Godot Phase 1 acceptance suite:

```bash
./scripts/check-godot.sh
```

It boots the scene headlessly, then validates P1.01–P1.05: pixel settings,
scene construction, movement and sprint, room/object collision, and interaction.

Validate the Rust core separately:

```bash
./scripts/check.sh
```

For an isolated Rust test outside a graphical session, run the core from
`core/` with `VELORA_SOCKET=/tmp/velora-dev.sock cargo run`.

The pixel hub intentionally remains in offline mode during Phase 1. No Omarchy
configuration is changed and applications are not launched until the native
transport and command policy are reviewed in Phase 2.
