# Workshop implementation and review

## R6.02–R6.05 implementation checkpoint — 2026-10-17

Owner approved the native warm palette, typography, icons and state markers
before world integration. R6.02's contact sheet is accepted; R6.03–R6.05 are
implemented and in review, not yet accepted as a release. Combined graphical
gate is pending on the integrated head; focused checks below actually passed.
No R6.06 dispatcher, quick launcher, filesystem feature or panel-wide redesign
was added. Nothing from this implementation session has been pushed or merged.

Production now uses 640×360 with a 24-pixel header, a 320×128 unscaled world
view enlarged 2× into (0,24)..(640,280), and an 80-pixel persistent inspector.
The 320×192 physics room, 16-unit tiles, spawn (160,136), speeds 48/72,
seven object positions, collision and facing distances remain unchanged.
Existing modal shells retain their behavior, with compact padding and 2×
placement inside the world band. They do not shade or obscure the inspector.
The historical 320 HUD/proof fixtures explicitly bypass production composition;
they are comparison coverage, not claims that the new interface passed.

Focused evidence: byte-identical legacy art cleanup (22 images), semantic
contrast/silhouette/state checks, 20 selection-model checks, 36 inspector-view
checks, actual seven-object physics routes, integrated keyboard/remapping/
late-close checks, and fake-bridge registry/session/launch/restart integration.
All are registered in the headless harness. The native production fixture
exported synthetic 640-native, grayscale and 720p/1080p integer frames with all
seven objects reached and visible; final combined-head rendering/performance
must still be rerun. The first native review found forced collision-debug tint
in the old scene; 1121176 removes it with a failing-then-passing regression.

Key commits: 609080e mechanical cleanup; fd2b3ce selection model; f40103c
visual system; 52d4202 native sheet; 30317d8 composition; cbcfa64 test typing;
4eb280b independent state/focus decoration; ed3bd7f application art; c30bc41
capability/environment art; 5580979 inspector view; cd12beb remappable action;
3f52f4a context wiring; 21ba625 accepted backend feedback; 1121176 debug tint;
240b67b shared bounded text; 01fba09 production capture/performance metadata.

F is the default focus-inspector action, conflict-checked and remappable with
validated defaults for older settings. Escape restores the prior useful input
context. Inspector visibility does not lock movement; explicit focus does.
World activation uses only Player.active_interactable, never retained selection.
Inspector confirmation returns to the world; it does not launch. BackendClient
continues to own request IDs, transport/reconnect and accepted snapshot order.
Running observations reuse SessionBinding and the accepted cached snapshot;
stale observations and launch acceptance are labelled honestly.

Remaining owner checks: room/art identity and grayscale, all seven actual
keyboard approaches/collisions, F/Back and remapped focus/confirm, modal input
recovery, and a real-session Core restart while paused. The native art-sheet
approval does not automatically approve those later behaviors. No CI result
or physical fullscreen benchmark at both export sizes is claimed.

## R6.01 native density proof — accepted historical checkpoint

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
inspector**. At that checkpoint R6.02–R6.05 were unstarted; production
project.godot, design tokens, world art and physics remained unchanged.
Initial candidate renders, all seven approach/visibility checks and
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
The 2026-10-16 publication-only task stopped there. The owner separately
authorized implementation continuation on 2026-10-17, as recorded above.

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

Publication review of f660337...5fe0b05 found one non-blocking consistency
issue: the proof runner's final message still called the density choice pending.
It now prints a decision-neutral proof-only reminder. This is a message-only
shell change; runtime fixture behavior and benchmark thresholds are unchanged.
Fresh headless geometry/isolation, Bash syntax and ShellCheck checks pass. The
full graphical results above remain attributed to code head 41f01ec, not a
claim that the entire suite was rerun for the subsequent documentation/message.

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
