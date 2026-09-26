# Fixed-canvas visual inventory

Baseline: merged Phase 5 `5bdf1dc`, 320 × 180, nearest integer scaling,
Godot Compatibility renderer. No downloaded art or fonts are introduced.

| Surface | Source and visual contract |
| --- | --- |
| Floor, walls, path, threshold | `scripts/pixel_art.gd`: generated 64 × 16 atlas of four 16 × 16 tiles; hub builds boundary/collisions |
| Player | Generated 16 × 24 sprites, four directions × two steps; player caches textures |
| Application stations | Generated workstation texture; three registry-backed objects and state markers |
| HUD and pause | `scenes/main.tscn`, `ui/hud.gd`; fixed status/connection/prompt regions, scene-local styles |
| Notification feed | Four fixed two-line rows; `!! CRIT`, `! NORM`, `. LOW`; 32 tracked entries |
| Media console | Three fixed two-line rows; `+ PLAY`, `= PAUSE`, `. STOP`; 16 tracked players, capability-specific controls |
| Workspace map | Five-column, maximum 20-cell grid; active `>`, urgent `!`, special `~` markers |
| Typography | Godot default font; body 7 px, title/counter 8 px; clipped fixed-region labels |
| Spacing | 4 px base, 16 px tile; list panels at (40,24), width 240; map at (40,30) |

`ui/design_tokens.gd` owns shared semantic colors, geometry and font sizes.
Ready cyan, waiting amber and failure red supplement labels and symbols.
World amber/text retain their slightly different original values, intentionally.
Sprite-local skin, clothing and texture-detail shades are not UI palette roles.
Scene-authored HUD styles remain serialized scene resources, not panel constants.

Rendered baseline on Intel UHD (CML GT2), Wayland: 60.00 FPS average,
18.43 ms p95, 600 frames. Resource baseline: 0.0% sampled idle Core CPU,
20 KiB RSS growth; private-D-Bus overhead 1752 KiB, 0 KiB growth.
Synthetic baseline images are private local evidence, not live session captures.

The token-only migration was byte-identical across hub, notification feed,
empty media and workspace fixtures. The later workspace primitive migration
deliberately gives cells a readable fixed width and tighter vertical margins;
all 20 cells and the footer now fit inside the canvas. Selection follows the
workspace handle rather than jumping back to the active workspace on updates.

For reproducible synthetic visual review (requires a graphical session):

```bash
capture_dir="$(mktemp -d /tmp/velora-visual.XXXXXX)"
VELORA_VISUAL_DIR="$capture_dir" godot --path frontend/godot \
  --script res://tests/visual_foundation_fixture.gd
```

The fixture disables backend auto-connect and exports native and scaled
frames for populated, empty, waiting, unavailable, stale, and crowded views.
It reads no live notifications, media or compositor data. Review these frames
alongside `./scripts/velora.sh gate` and `./scripts/velora.sh perf`.
