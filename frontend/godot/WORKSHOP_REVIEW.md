# Workshop implementation and review

## R6.02–R6.05 implementation checkpoint — 2026-10-17

Owner approved the native warm palette, typography, icons and state markers
before world integration. R6.02's contact sheet is accepted; R6.03–R6.05 are
implemented and in review, not yet accepted as a release. The combined graphical
gate passed on integrated code head 307a2bb; results below are actual local runs.
No R6.06 dispatcher, quick launcher, filesystem feature or panel-wide redesign
was added. The owner authorized frequent pushes on 2026-10-17; implementation
and evidence notes are published on workshop-foundation. No PR or merge was
requested or performed. Subsequent evidence/documentation changes do not imply
another full gate run; the functional validation head remains 307a2bb.

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
also passed after fixes. The first native review found forced collision-debug tint
in the old scene; 1121176 removes it with a failing-then-passing regression.

Key commits: 609080e mechanical cleanup; fd2b3ce selection model; f40103c
visual system; 52d4202 native sheet; 30317d8 composition; cbcfa64 test typing;
4eb280b independent state/focus decoration; ed3bd7f application art; c30bc41
capability/environment art; 5580979 inspector view; cd12beb remappable action;
3f52f4a context wiring; 21ba625 accepted backend feedback; 1121176 debug tint;
240b67b shared bounded text; 01fba09 production capture/performance metadata.
307a2bb records the implementation checkpoint. Later documentation commits
record final gate evidence and owner review instructions, not extra runtime work.

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

## Combined implementation validation — code head 307a2bb

All three requested commands passed locally with exit 0:

```bash
./scripts/velora.sh check
./scripts/velora.sh ipc-check
VELORA_PHASE_SIX_REPORT_DIR=/tmp/velora-workshop-visual.cMisi4/gate-rendered \
VELORA_WORKSHOP_REPORT_DIR=/tmp/velora-workshop-visual.cMisi4/gate-proof \
  ./scripts/velora.sh gate
```

The cumulative gate includes 226 Rust tests, strict Clippy, frontend regressions,
temporary-socket IPC restart, owned-child cleanup, static security, private-bus
fixtures/resource budgets, legacy rendered comparisons, the new visual sheet,
seven-object production layout/physics routes, and both historical density proofs.
No real application launches, Desktop scanning or production buses/sockets were
used by those automated fixtures. Synthetic production captures include empty,
offline, long Unicode/failure, explicit inspector focus, modal and reconnect states.

Godot 4.7.2, Wayland Compatibility/OpenGL 3, Mesa 26.2.2, Intel UHD CML GT2;
600 sampled frames after 120 warmup frames per benchmark:

| Production 640×360 workload | Average FPS | p95 ms | Maximum ms |
| --- | --- | --- | --- |
| Movement, static synthetic UI | 60.00 | 17.08 | 17.75 |
| Crowded UI and retained inspector | 57.97 | 17.24 | 49.87 |

Both meet >=55 FPS average and <=25 ms p95. The crowded fixture includes 603
synthetic registry entries (three mapped and 600 fake), a chooser capped at 512,
32 notifications, 16 media players, 20 workspaces and repeated state updates.
The maximum shows an outlier; passing the budget is not a zero-hitch claim.
These are UI-bound measurements, not live IPC throughput or a like-for-like
optimization comparison against older workloads. Core idle CPU was 0.0% over
5 seconds, with 20 KiB RSS growth; private-bus idle CPU was 0.0%, with 1564 KiB
fixed RSS overhead and 0 KiB growth over the sample window.

The isolated 320/640 historical proofs also passed again (movement/crowded:
60.00/57.51 FPS at 320, 60.00/57.23 FPS at 640; p95 17.15/17.33 and 17.18/17.34
ms; maxima 17.91/83.23 and 20.83/67.02 ms). These remain blockout coverage,
not additional production UI modes. Hyprland tiled the requested window to
960×1043. Native images are true SubViewport renders; 720p/1080p images are
integer exports, not physical fullscreen performance measurements. The known
libdecor GTK and missing xdg-toplevel-icon warnings occurred without a failed
fixture. No GitHub CI result is claimed.

Evidence: `/tmp/velora-workshop-visual.cMisi4/{check.log,ipc-check.log,gate.log}`,
`gate-rendered/frames/production-layout.json`, the native/grayscale/scaled PNGs,
`gate-rendered/{movement,crowded}-performance.json`, and `gate-proof/`. A durable
copy is retained privately, excluded from Git. Captures inspected here contain
synthetic application labels only, not private desktop windows or files.

## Independent implementation review — fixed head 307a2bb versus f660337

### Standards

No documented-standard violations or blocking findings. One non-blocking
maintainability follow-up: WorkshopView currently reaches into PanelShell's
child hierarchy to compact legacy modal rows. When R6.08 harmonizes panels,
move that adaptation behind a PanelShell-owned interface and cover hierarchy
changes there. No broad panel refactor is added to this R6.01–R6.05 scope.

### Spec

No actionable findings. Nearby target, retained identity and input ownership
remain separate; inspector focus/remapping, identity-keyed feedback, accepted
backend state reuse and later-card boundaries match the requested contract.
The read-only reviews did not themselves run tests or supply owner approval.
R6.03–R6.05 still require the manual native room/input checks below.

## Owner review commands — R6.03–R6.05

Run only after automated/rendered measurements finish, so two Velora instances
do not compete during benchmarking. Normal development uses:

```bash
./scripts/velora.sh dev
```

1. Walk with WASD/arrows to the three applications and four capabilities.
   Check walls/plinths, facing, silhouettes, readable prompts and no HUD overlap.
2. Approach an app, then leave. Its inspector should remain useful, but E/Enter
   away from every object must do nothing. Approach a different app: identity,
   icon, availability and feedback must follow that app, not a row index.
3. F explicitly focuses inspection and locks movement. Escape or the named
   confirm action returns to the world without launching. Visibility alone
   must never steal movement. Inspector launch controls are not implemented.
4. From inspection, open a modal with Tab/M, N or P; Back restores inspection,
   then Back again restores movement. Rapid transitions must not strand input.
5. In pause Settings → Controls, remap focus-inspector and confirm to unused
   keys. Check the new keys/hints work and the old keys cannot dismiss or launch
   through inspection. Reset bindings afterwards if desired.
6. Launch an installed, safe mapped app from its nearby station. Read “launch
   accepted” separately from observed running; try a missing app and recovery.
7. Quit normally and confirm the runner cleans up its own Core; Hyprland and
   Omarchy must remain unchanged.

For a controlled real-session restart without sharing a production socket,
run in terminal1 from the repo. The Core still uses real session integrations
for this **manual** test; notification monitoring remains default-disabled.

```bash
velora_manual_dir="$(mktemp -d /tmp/velora-workshop-review.XXXXXX)"
printf 'Second terminal: VELORA_SOCKET=%q ./scripts/velora.sh run\n' "$velora_manual_dir/core.sock"
VELORA_SOCKET="$velora_manual_dir/core.sock" ./scripts/velora.sh core
```

Copy the printed command into terminal2. Pause Godot, stop Core with Ctrl+C in
terminal1, then repeat terminal1's final command. Confirm retained identity,
stale/reconnecting feedback and fresh state recovery without leaving the modal
or restarting Godot. Exit Godot, stop that Core, then clean up only the empty
owned directory with `rmdir -- "$velora_manual_dir"`. Do not use pkill or remove
someone else's socket. Record actual pass/failure and any warnings; this
checklist is not evidence that manual acceptance has already happened.

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
