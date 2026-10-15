# R6.01 native density proof — in progress

Branch: workshop-foundation, from documentation head f660337 / experience
baseline fc9ce6e. No native resolution or final artwork has been accepted.
This blockout is not R6.05's production inspector and sends no launch intents.

## Fresh pre-change baseline — 2026-10-16

Existing rendered layout and both performance fixtures passed before changes.
Godot 4.7.2, Mesa 26.2.2, Wayland Compatibility, Intel UHD Graphics CML GT2:

| Existing workload | Average FPS | p95 ms | Maximum ms |
| --- | --- | --- | --- |
| Movement | 62.15 | 17.66 | 23.32 |
| Crowded UI | 135.97 | 14.46 | 40.28 |

600 sampled frames after 120 warmup frames per workload. Required average
>=55 FPS and p95 <=25 ms. Window/compositor scheduling affects FPS; these are
synthetic UI measurements, not live transport or a zero-hitch claim. Logs,
JSON and synthetic native/scaled/grayscale frames are retained privately.

## Coordinate contract for the comparison

- Existing room is 20×12 tiles at 16 world units: 320×192, not 320×180.
- Existing camera limits remain (0,0)..(320,192); it follows the player.
- Existing player starts at (160,136), walks at 48 units/s, sprints at 72.
  Body is 10×8; detector is 14×12 with existing facing offsets unchanged.
- Existing app stations: (96,48), (160,48), (224,48). Capabilities:
  (64,104), (112,104), (208,104), (256,104). No bodies or room roots scaled.
- Both blockouts use the SAME 320×128 world viewport. The compact view follows
  the player; it does not show every object at once. Reachability and visibility
  at each approach must be verified, not inferred from a single spawn frame.
- Native 320: 12-pixel header, 128-pixel world, 40-pixel inspector blockout.
- Native 640: 24-pixel header, 256-pixel displayed world, 80-pixel inspector.
  The world texture alone is enlarged exactly 2×; physics/FOV are identical.
- This makes art's screen footprint comparable at the same output size while
  allowing different native text density. Body text is 7 versus 12 native pixels;
  detailed tokens/art remain R6.02 after owner approval.
- Inspector is a separate lower region, never an overlay on the world. Modal
  samples cover world content deliberately, not the inspector. No inspector
  controls, selection model or real actions are implemented by this proof.

## Acceptance

Pending: rendered comparison, both candidate benchmarks, approach visibility,
owner native density/layout choice. R6.02–R6.05 remain unstarted. Production
project.godot, design tokens, world art and physics remain unchanged.
