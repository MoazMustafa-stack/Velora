# Fixed-canvas visual inventory

## R6.02 workshop family — native review pending (2026-10-17)

The owner-approved density is 640 × 360 with a lower 80-pixel inspector and
24-pixel header. `design_tokens.gd.Workshop` defines proposed warm ink, lavender
surfaces, brass/wood details, readable body/title typography (12/14 px), spacing,
outlines and semantic status colors. The root token constants remain the legacy
runtime contract until the reviewed world/inspector migration; there is no
production theme or resolution selector.

`scripts/workshop_art.gd`, accessed through `pixel_art.gd`, generates the proposed
family deterministically. World textures remain 32 × 32 **world pixels**; native
UI icons are 16 × 16 nearest-sampled from the same original geometry. The world
will still display at 2× without scaling physics, speed or interaction distances.

| Identity | Object / category fallback |
| --- | --- |
| Editor / development | Booked workbench with bracket monitor |
| Browser / network | Globe on a stand, distinct from the observatory telescope |
| Terminal / system | Low terminal rack with prompt glyph |
| Workspaces | Folded map |
| Media | Record deck |
| Notifications | Flagged postbox |
| Observatory | Angled telescope |
| Unknown application | Handled toolbox, never an inferred executable/icon path |

Ready uses a check; waiting an hourglass; failure an exclamation; offline a
cross; disabled a dash. Selected objects use corner brackets; explicit keyboard
focus uses a continuous doubled outline. Labels accompany status colors; tests
require distinct silhouettes/icons and monochrome state markers. Text/status
colors have at least 4.5:1 contrast against the proposed inspector panel. These
static assets introduce no animation, flashing or reduced-motion exceptions.

There are at most 8 × 7 cached object textures and 8 icons; unknown kind/state
strings normalize **before** lookup. No random seeds, runtime downloads,
external SVG/icon parsing, host files or live snapshots are involved. All pixel
geometry is original project source covered by the root BSD-3-Clause license.
Typography uses Godot's bundled default font; its upstream font and engine
licenses remain Godot's, not relicensed as project artwork. No font is copied
or downloaded into this repository.

The mechanical status-marker/accent consolidation at `609080e` preserved all
22 legacy generated image hashes (nine station states, four capabilities, tile
atlas, eight player frames). Intentional workshop art is a separate additive
API: the normal application still renders the existing room. Owner native
visual approval is required before R6.03 adopts this family.

For the synthetic native contact sheet (no Core, settings or private data):

```bash
style_dir="$(mktemp -d /tmp/velora-workshop-style.XXXXXX)"
VELORA_WORKSHOP_STYLE_DIR="$style_dir" godot --path frontend/godot \
  --script res://tests/workshop_style_capture.gd
```

The fixture exports true 640 × 360, grayscale and integer 720p/1080p images.
It is also registered in the graphical gate. Static images do not replace
world collision/input review, performance checks or the owner's art decision.

## Historical production inventory

Baseline: merged Phase 5 `5bdf1dc`, 320 × 180, nearest integer scaling,
Godot Compatibility renderer. No downloaded art or fonts are introduced.

| Surface | Source and visual contract |
| --- | --- |
| Floor, walls, path, threshold | `scripts/pixel_art.gd`: generated 64 × 16 atlas of four 16 × 16 tiles; hub builds boundary/collisions |
| Player | Generated 16 × 24 sprites, four directions × two steps; player caches textures |
| Application stations | Generated workstation texture; three registry-backed objects and state markers |
| Capability objects | `hub_object.gd` / `pixel_art.gd`: cached 32 × 32 folded map, media box, flagged inbox and telescope; facing-aware interaction and fixed collision archetype |
| Observatory panel | Four fixed two-line rows, aggregate telemetry and explicit stale/offline feedback; shared PanelShell |
| HUD and pause | `scenes/main.tscn`, `ui/hud.gd`, `ui/pause_panel.gd`; fixed priority regions and shared PanelShell keyboard pages |
| Notification feed | Four fixed two-line rows; `!! CRIT`, `! NORM`, `. LOW`; 32 tracked entries |
| Media console | Three fixed two-line rows; `+ PLAY`, `= PAUSE`, `. STOP`; 16 tracked players, capability-specific controls |
| Workspace map | Five-column, maximum 20-cell grid; active `>`, urgent `!`, special `~`, independent selected `*` markers |
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
  --script res://tests/experience_visual_fixture.gd
```

The current fixture disables backend auto-connect **and processing timers**,
preference IO and audio. It exports native/scaled/grayscale frames for populated,
empty, stale and crowded views, controller labels, remapping, a 500-entry
registry chooser and observatory states.
It reads no live notifications, media or compositor data. Review these frames
alongside `./scripts/velora.sh gate` and `./scripts/velora.sh perf`.

## Experience-pass motion and state audit (D6.06–D6.09)

The only animated world asset is the player's two-frame walk cycle in
`player.gd`. Reduced motion selects step zero immediately; velocity, facing,
collision and interactions remain unchanged. There are no tweens, flashing
status effects, sliding overlays or animated selection treatments. Transient
HUD expiry changes text once and restores the prior useful status.

Station LEDs now also use high-contrast check / exclamation / cross shapes
for ready / attention / offline. Workspace status markers compose `>` active,
`!` urgent and `~` special; `*` independently identifies the selected cell.
Feed urgency, media playback, waiting, disabled, failure and stale states retain
explicit text/markers. No status information requires color or animation.

The D6.05 art/layout pass now supplies all seven world objects with distinct
alpha silhouettes and a shared interaction tick. The lower approach lane and
central corridor remain unobstructed in default/remapped-keyboard and synthetic
controller physics tests. Native/grayscale captures are re-audited; owner final
keyboard/visual review remains. Controller code is experimental and not a
requirement for the current keyboard-only milestone. Local audio introduces no visual animation.
Original generated audio and its bounded voice policy are documented in
`AUDIO_ASSETS.md`.

Script `.gd.uid` files are tiny source resource identifiers, not import caches;
they are tracked alongside scripts. `.godot/`, binaries and private evidence
remain ignored. See Godot's [UID guidance](https://godotengine.org/article/uid-changes-coming-to-godot-4-4/).
