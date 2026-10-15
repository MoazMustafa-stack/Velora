# D6.06–D6.09 experience review

Historical checkpoint: D6.06–D6.09 was implemented and locally validated from
merged foundation `57cfcb6`, then pushed through `8531764` on October 6.
On October 8, D6.05 and D6.10–D6.12 were implemented and the new artwork was
rechecked in native/grayscale fixtures. See [the current review](PERSONALIZATION_REVIEW.md)
for current evidence and remaining acceptance. The owner reported testing most
of the previous slice; this is not a complete recorded acceptance checklist.
Phase 6 is not complete or merged.

## Implementation map

| Card | Responsibility and verification |
| --- | --- |
| D6.06 | `hud_layout.gd` reserves top status/connection and exclusive footer regions. `hud.gd` enforces modal > failure > prompt > telemetry priority, clipped labels and useful-state restoration. HUD and rendered bounds fixtures cover this. |
| D6.07 | `empty_states.gd` distinguishes offline, waiting, empty, disabled and unavailable states with next actions. Backend correlation identifies the existing protocol-v5 disabled-notification response. `onboarding.gd` records useful actions in any order; only completion/dismissal is persisted. |
| D6.08 | `pause_panel.gd` owns bounded keyboard pages, composed from PanelShell/ListCursor. Main owns preference IO, reset and diagnostics wiring; OverlayCoordinator still owns modal focus/player lock. Help and every action hint read live InputMap bindings. |
| D6.09 | `player.gd` immediately freezes decorative walk frames under reduced motion without changing speed, facing or collision. Station check/!/cross and independent workspace selection/status markers survive grayscale. |

No Core/protocol authority changes, system configuration writes or live-data
persistence were introduced. Disabled notification content and its cached
count remain hidden even after disconnect. Reset requires confirmation and
only removes the UI preference file. Local audio preferences are editable,
but the UI truthfully identifies audio cues as future D6.10 work. Stored key
bindings and station mappings are not applied by this slice.

## Actual local evidence — 2026-10-06

- `./scripts/velora.sh gate`: passed 224 Rust tests (197 Core, 24 protocol,
  3 bridge), strict Clippy, all old/new frontend suites, static security and
  private-D-Bus/resource budgets.
- Core idle CPU 0.0%, RSS growth 20 KiB over five seconds. Private-bus idle
  CPU 0.0%, 1808 KiB fixed RSS overhead, 0 KiB growth.
- Rendered worst-case fixture: 23 synthetic views, each exported native,
  scaled and grayscale. All panels and clipped labels fit 320 × 180. Native
  pause/settings/diagnostics, crowded workspaces and notification grayscale
  captures inspected. No live content, desktop capture or production socket.
- Wayland Intel UHD CML GT2 / Compatibility: 59.99 FPS average, 17.33 ms p95,
  600 sampled frames. Budget: at least 55 FPS, at most 25 ms p95.
- Rendered pause/input and reduced-motion fixtures also pass on Wayland.
- Wayland logs contain libdecor GTK and missing optional window-icon protocol
  warnings; rendering and all fixtures complete successfully.
- No new GitHub CI run was requested. Historical PR #9 CI could not start
  because of account billing; local evidence must not be called a CI pass.

## Reproduce

From the repository root:

```bash
./scripts/velora.sh gate
./scripts/velora.sh perf
capture_dir="$(mktemp -d /tmp/velora-experience-review.XXXXXX)"
VELORA_VISUAL_DIR="$capture_dir" godot --display-driver wayland \
  --rendering-driver opengl3 --path frontend/godot \
  --script res://tests/experience_visual_fixture.gd
```

Tests use no real applications, notifications, media players or compositor
data. Tests that exercise persistence inject their own temporary file and
remove it. Scene/performance fixtures disable preference IO and auto-connect.
Synthetic/rendered evidence supplements, but does not replace, owner input
and visual acceptance in a real session.

## Remaining owner review

Run `./scripts/velora.sh dev` inside Hyprland. Then:

1. Move, face a station and interact; hints progress without blocking control.
2. Open Escape → Help/Diagnostics/Settings using arrows and Enter. Back from
   accessibility/audio/reset returns Settings, then Home, then the world.
3. Change reduced motion while paused. Resume: facing/movement still work,
   decorative walk frames stop. Restart to confirm the preference survives.
4. Skip hints from Settings; restart and confirm dismissal. Replay from Home.
5. Enter reset, cancel, then re-enter and confirm. Only UI preferences reset;
   onboarding resumes and system/Core settings stay untouched.
6. Verify default-disabled feed, opt-in available/empty feed and unavailable
   media/Hyprland states give the right cause/action. Do not publish live data.
7. Stop/restart Core while paused and confirm diagnostics update, no stale
   banner blocks recovery, and closing restores the useful status/prompt.
8. Inspect native text and grayscale markers for readability. Re-run this
   accessibility review after D6.05's art/layout redesign.

Keep D6.06–D6.08 in Review until owner acceptance. D6.09 also has an explicit
D6.05 dependency, now implemented and awaiting final owner visual acceptance.
Audio, keyboard remapping and station UI are implemented; see the current
[release checklist](RELEASE_REVIEW.md). Existing controller code is experimental,
not a requirement for the keyboard-only milestone. The original implementation
evidence above is historical, not the latest gate result.

## Focused commit ledger

- `4ce2236`: HUD regions and modal priority
- `1a96d9e`: capability empty states and notification policy
- `29aee7e`: contextual onboarding and isolated preferences
- `51a0eee`: shared pause/help/live diagnostics
- `aedff32`: safe settings navigation and live action hints
- `1a6c318`: grayscale state/selection markers and privacy regression
- `e5b4053`: persisted reduced-motion application and tests
- `92e01aa`: rendered/grayscale fixtures and scene/performance isolation
- `58474ef`: actual post-layout HUD bounds and theme minimum-padding fix
