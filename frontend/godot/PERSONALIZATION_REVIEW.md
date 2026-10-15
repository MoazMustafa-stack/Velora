# D6.05 and D6.10–D6.12 review

Implemented on `cohesive-hub-experience` from the published `8531764` experience
slice. Implementation and six audit fixes were pushed through `793feb9` on
October 8. D6.13 automation is a later local change; no merge is implied.
The owner reported testing most of the previous slice on October 8, 2026;
this is partial acceptance, not a recorded complete checklist. D6.13 now has
local cumulative automation and a crowded-UI benchmark; see
[the current release checklist](RELEASE_REVIEW.md). Phase 6 is not released or complete.

Product-scope correction: the target is keyboard-only. Existing experimental
controller code is left untouched for the owner to handle; physical-controller
review is not a release blocker for this milestone. Historical controller tests
below are evidence about that code, not a product-support promise.

## What changed and where

| Card | Responsibilities |
| --- | --- |
| D6.05 | `pixel_art.gd` caches distinct station/capability silhouettes. `hub_object.gd` builds one shared physical interactable archetype. `hub.gd` supplies clear approach lanes; `observatory.gd` shows aggregate telemetry. Main routes capability interactions to the existing modal coordinator. |
| D6.10 | `ui_audio.gd` generates five finite, quiet cues and owns three reusable voices on the app-only VeloraUI bus. Main applies saved mute/volume; only explicit UI actions and their correlated feedback request cues. Live data updates stay silent. |
| D6.11 | `key_bindings.gd` validates complete active contexts before applying keyboard changes. Pause owns capture/cancel UI; Main owns persistence. `input_actions.gd` supplies fixed generic pad mappings, threshold-edge navigation, active-input labels and device-specific release on disconnect. |
| D6.12 | `station_mappings.gd` accepts fixed slots and known desktop IDs, with a 512-choice UI cap. Pause renders the registry-only chooser; Main applies saved IDs to stations. Unknown IDs block launch, malformed IDs visibly fall back, and real Core registry/launch policy remain authoritative. |

The station chooser shows the selected desktop ID so duplicate application names
are distinguishable. Names are single-line and clipped. Registry updates preserve
chooser selection by ID; station running state is recomputed from the last useful
session snapshot. Unrelated preference changes do not erase launch feedback.
No Exec strings, metadata, commands, media or notifications enter the settings file.

There are no new Rust Core commands or protocol changes, system mixer operations,
Omarchy/Hyprland configuration edits or downloaded asset dependencies. Generated
audio attribution/bounds are in `AUDIO_ASSETS.md`; script UID metadata is tracked
alongside sources, while caches, native binaries and private evidence stay ignored.

## Actual validation — October 8, 2026

- Cumulative `./scripts/velora.sh gate`: 224 Rust tests (197 Core, 24 protocol,
  3 bridge), strict Clippy, all old/new Godot tests, static security and private
  D-Bus/resource checks pass on code head `76a4460`.
- Physics walkthroughs reach all seven objects with actual default/remapped key
  events and synthetic controller events. Facing, collision, stable targeting
  and capability modal interactions pass; opening input cannot leak into a new modal.
- Audio tests cover finite assets, bounded voices, no-device/missing cue fallback,
  independent mute/volume, immediate stop, cleanup and restart persistence.
  Background snapshot updates produce no cues. Audible quality is still manual.
- Keyboard tests cover conflicts, reserved Escape, capture cancellation, startup
  fallback, reset, persistence and a complete remapped world walkthrough.
- Controller tests cover all action bindings, button/stick navigation, deadzone,
  no repeated same-direction queue, label switching, modal ownership and hot-plug
  release without clearing held keyboard input. Zero physical controllers detected;
  these are synthetic tests, not hardware acceptance.
- Mapping tests use a temporary preference file and fake bridge: known IDs send
  exactly an ID-only launch request; unknown/malformed/removed IDs cannot launch.
  They also cover visible fallback, running-state refresh and independent reset.
- Real Wayland controller/remapping/mapping scripts pass with dummy audio. Native,
  scaled and grayscale captures cover 34 scenarios (102 images), including a
  500-entry registry, remap capture, pad labels and observatory full/stale states.
  Every active panel and fixed label fits 320 × 180. Native/grayscale world,
  chooser, controller help, capture and observatory images were inspected.
- Intel UHD CML GT2 / Wayland Compatibility: 60.00 FPS average, 17.20 ms p95,
  19.09 ms maximum over 600 frames. Required budget: at least 55 FPS / at most
  25 ms p95. Core idle CPU 0.0%, RSS growth 16 KiB; private-bus CPU 0.0%, fixed
  overhead 1940 KiB and growth 0 KiB, all resource budgets pass.
- Optional libdecor GTK/window-icon warnings occur, with no failing rendering
  or script errors in final validation. Earlier test/parser/layout issues were
  fixed and retested. No GitHub CI run was requested or claimed to pass.

The performance run covers the new world and services; the final follow-up fix
only changes station refresh/chooser presentation. Synthetic scenes disable
preference IO and backend timers, or inject their own temporary paths/bridge.
Tests never launch real applications or connect to the production socket.

## Reproduce

From the repository root:

```bash
./scripts/velora.sh gate
./scripts/velora.sh perf
capture_dir="$(mktemp -d /tmp/velora-personalization-review.XXXXXX)"
VELORA_VISUAL_DIR="$capture_dir" godot --display-driver wayland \
  --rendering-driver opengl3 --path frontend/godot \
  --script res://tests/experience_visual_fixture.gd
```

## Owner manual acceptance

Start with `./scripts/velora.sh dev` inside your normal Hyprland session:

1. Walk to all seven objects with the keyboard; confirm silhouettes, labels,
   approach lanes and collisions are readable at native and integer-scaled sizes.
2. Check the observatory's live/stale/offline states; repeat grayscale/reduced-motion
   review against the new art. Core restart must still restore useful state.
3. Listen to navigation, interaction, confirmation, rejection and media cues.
   Mute while a cue plays, restart, test zero volume, and verify media-player/system
   volume did not change. Background feed/media changes must remain silent.
4. Settings → Controls: select an action, Enter, then press a new key. Reject a
   conflict, cancel with Escape, remap the critical path and restart. Reset keys.
   Escape remains protected; modified chords are not supported.
5. Optional future controller work, not milestone acceptance: D-pad/left stick move and navigate; A interacts/
   confirms, B backs, Start pauses, Y opens map, LB feed, RB media, L3 sprints.
   In media: A toggles, D-left/right previous/next, Y stops, X plays, L3 pauses.
   LT/RT page, R3 first, Select last. Unplug while moving and while paused;
   keyboard fallback and focus must remain usable.
6. Settings → Station Mappings: choose an installed application for a fixed slot,
   restart and interact. Test an unavailable saved ID and registry removal;
   neither may send a launch. Reset the slot/all mappings and whole preferences.

Leave the new cards in Review until this evidence is recorded. D6.09's former
missing-art dependency is now implemented and agent-rechecked, but final owner
visual acceptance remains. D6.13 is now the cumulative validation work; do not
start a new filesystem integration until current milestone acceptance.

## Focused code/test ledger

- `17f5364`: cached grayscale-distinct object art
- `7a2aa31`: physical capability objects, observatory and reachable layout
- `b81038f`: bounded generated local audio service
- `514c15e`: user-action audio wiring and persistent preferences
- `79035a1`: safe context-aware keyboard remapping
- `5f2846d`: controller bindings, labels, hot-plug and interaction ownership
- `c3dcff6`: registry-only mapping model and bounded choices
- `bbcc17f`: slot chooser, ID-only launch path and visible malformed fallback
- `17db71a`: physical remapped-key world walkthrough
- `600ea1b`: stable script UID source metadata
- `42bb03e`: personalized rendered fixtures, observatory bounds and timer isolation
- `76a4460`: cached running-state refresh, pending feedback preservation and ID detail
