# R6.01 native density proof — accepted

Branch: workshop-foundation, from documentation head f660337 / experience
baseline fc9ce6e. On 2026-10-16 the owner approved the 640×360 native canvas
with the lower inspector after reviewing the native comparison. Final artwork
and production inspector/input behavior are not accepted by this decision.
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

R6.01's native proof and density decision are accepted: **640×360 with the lower
inspector**. R6.02–R6.05 remain unstarted. Production project.godot, design
tokens, world art and physics remain
unchanged. Initial candidate renders, all seven approach/visibility checks and
both benchmark workloads pass. Final combined-code-head validation at 41f01ec:
`check`, `ipc-check` and the full graphical `gate` all PASS. 226 Rust tests,
strict Clippy, all frontend/static-security/private-bus/resource checks, owned
child cleanup, IPC restart, old rendered fixtures and both new native proofs.

| Final candidate workload | Average FPS | p95 ms | Maximum ms |
| --- | --- | --- | --- |
| 320×180 movement / static synthetic UI | 101.90 | 17.02 | 20.85 |
| 320×180 crowded + mock inspector | 82.03 | 17.65 | 83.16 |
| 640×360 movement / static synthetic UI | 60.00 | 17.33 | 18.53 |
| 640×360 crowded + mock inspector | 58.25 | 17.65 | 66.54 |

All meet >=55 FPS / <=25 ms p95. Scheduling and presentation differ, so these
are not an optimization claim; retain the maximum outliers. The original
movement/crowded fixtures also pass (60.00 / 58.82 FPS, 17.21 / 17.33 ms p95).
Core idle CPU is 0.0% with 20 KiB RSS growth. Private-bus idle CPU is 0.0%,
1888 KiB fixed RSS overhead, 0 KiB growth. No GitHub CI result is claimed.

Synthetic evidence is retained privately with native, grayscale, 720p/1080p
exports for each state and all seven approaches. No real apps, production
sockets/buses, preferences or personal desktop contents were used. The proposed
640×360 canvas/lower inspector is now owner-approved for subsequent work.
All broader manual release checks and later-card implementation remain pending.

This approval closes the R6.01 density-proof card only. It does not assert that
the production frontend already uses the new canvas or that Phase 6 is complete.
The owner requested review and branch publication for now; do not start R6.02
or later as part of that publication task.

## Reproduce

```bash
./scripts/velora.sh check
./scripts/velora.sh ipc-check
./scripts/velora.sh gate
# Focused native layout/performance proof (real graphical session required):
./scripts/check-workshop-layout.sh
```

`check-godot.sh` includes the headless composition bounds/isolation test. The
graphical gate also calls the focused runner, so the new native proof is not an
unregistered test. Set VELORA_WORKSHOP_REPORT_DIR to a fresh evidence directory
to retain output at a chosen location. Each rendered case has a 180-second
deadline. A failure or timeout fails the runner, never a skipped PASS.

The compositor did not honor the requested 1280×720 window: Hyprland tiled it
to 960×1043. Reports record actual window and logical content sizes. Native
renders are true 320×180 / 640×360 SubViewport images, not downsampled desktop
screenshots. 1280×720 and 1920×1080 files are nearest/integer exports of those
images, not claims of physical fullscreen rendering at both output sizes.
No window-manager rules or configuration were changed to force a size.

## Independent review — fixed code head 41f01ec versus f660337

### Standards

No actionable documented-standard or practical code-smell findings. Benchmark
hooks have concrete reuse; candidate rendering stays outside production code.

### Spec

No blocking implementation defect or later-card scope expansion found. Two
coverage limits must remain explicit:

- The `reduced-motion` image is an idle/static sample, not animation evidence.
  The fixture leaves reduced motion enabled for all subsequent physical routes;
  the separate `tests/reduced_motion_validation.gd` regression directly checks
  animation suppression, unchanged movement/facing/speed, persistence and reset.
  Both are included in the cumulative checks; do not claim the still image alone
  establishes motion behavior.
- The production HUD is hidden in the blockout. Approach images prove full
  player/object sprite visibility against the candidate header and mock lower
  strip. Production proximity prompts and inspector interaction still require
  R6.04–R6.05 integration and native review. This proof does not accept that
  future HUD/input behavior.

The first rendered route attempt was interrupted after it stopped progressing
following one object; it is not a passing run. The route helper now always
yields a physics frame even on zero-distance legs. Corrected runs reach all
seven objects with progress logs and bounded deadlines. Known libdecor/xdg icon
warnings do not prevent rendering; retain them in logs rather than hiding them.
