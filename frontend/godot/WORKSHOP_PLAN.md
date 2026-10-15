# Workshop redesign implementation plan

Decision date: 2026-10-16. Status: direction accepted; R6.01 isolated proof is
implemented and locally validated, awaiting owner density/layout choice.
R6.02–R6.10 production implementation has not started. See WORKSHOP_REVIEW.md.
This document supersedes the old Phase 6 visual target, not its implementation
history or security/regression requirements. New cards use R6 identifiers so
existing D6.01–D6.13 cards and evidence remain intelligible.

## 1. Product and direction

Build a compelling keyboard-only systems/Rust portfolio prototype that is also
understandable to its author. Do not claim parity with conventional desktop
tools or replace Hyprland. The selected direction combines the **walkable pixel
workshop** with a **persistent application inspector**: spatial identity plus
clear, readable application state. Not an ASCII-only UI or a launcher-only desk.

The original browser studies are primary visual references on the separate
`visual-direction-prototypes` branch, verdict commit `d2528f1`. They are mock
interactions, not native layout, collision, performance or launch evidence.
Do not merge their HTML, switcher or preview runner into production.

Selected: world-first composition, distinct app silhouettes, persistent status.
Not selected automatically: a permanent left application rail, CRT effects,
browser font sizes, a particular canvas resolution, or a new theme matrix.
Use semantic color, shape and text together; decorative animation stays optional.

## 2. Retain versus rework

| Retain and regression-test | Rework deliberately |
| --- | --- |
| Rust Core, protocol v5, native bridge, launch policy | World composition, art and object identity |
| Reconnect, bounded messages and snapshot ordering | Selected-app presentation and launch feedback |
| Existing registry, session, telemetry, media/feed models | HUD density and information hierarchy |
| Overlay coordinator, safe preferences, list primitives | Explicit world/inspector/launcher input ownership |
| Remapping, station mapping, reduced motion, local audio | Panel skins, onboarding and help wording |

No Core/protocol rewrite is needed for this visual change. Keep application
launch authority in Core, never paths or commands supplied by UI. Keep existing
controller code untouched; keyboard acceptance is required, physical controller
acceptance is not. No filesystem scanning, new Linux integrations or compositor
configuration edits in this milestone.

## 3. Native layout decision before detailed art

R6.01 compares the existing **320×180** canvas with a **640×360 candidate** using
the same synthetic content. 640×360 is a recommendation to test, not an accepted
resolution: it supports integer scaling at 720p and 1080p but has four times as
many internal pixels. Measure it; do not infer equal performance.

Keep the world dominant. Compare a compact lower/right inspector placement,
showing app identity, availability, running state, last action and one contextual
keyboard hint. The inspector must not cover reachable objects or the player.
A permanent application rail is not required; direct selection is a temporary
keyboard drawer. Do not develop two permanent resolution modes. Select one
after native owner review; if 640 fails, simplify the inspector at 320 instead.

Record the relationship between world coordinates, camera, tile/art size and UI
coordinates. Preserve collision and interaction distances deliberately; changing
canvas size must not accidentally enlarge the playable physics area or change
movement speed. Avoid an engine/renderer change or speculative rendering layer.

## 4. Interaction contract to implement and verify

These are proposed production defaults, not claims about the browser mockup:

1. **Nearby object**, **selected application**, and keyboard focus are separate.
   Walking near an application selects it for inspection. Walking away may keep
   its last useful status visible; this does not authorize a remote world action.
2. World interaction activates only the current reachable object. No nearby
   object means no launch. Capability objects open their existing domain panels.
3. The inspector is non-modal by default and never silently steals movement.
   A named focus-inspector action explicitly enters its keyboard actions; back
   restores world input. Its exact default key is chosen against existing
   bindings during R6.04, documented, remappable and conflict-checked.
4. The quick launcher is modal and owned by OverlayCoordinator. Confirming a
   row explicitly launches that row once through the same launch dispatcher.
   The event is consumed: it cannot also activate a world object. Back cancels
   and restores the prior useful selection and focus.
5. Selection and feedback are keyed by desktop ID, not row index. A response
   for application A must never become application B's feedback after selection
   changes. Core reconnect invalidates old pending actions through existing
   connection-local request handling; no replay or auto-retry of launches.
6. Distinguish available, unavailable, launching, launch accepted, launch failed,
   observed running and Core offline. Spawn acceptance is not window readiness.
   Retry is explicit and offered only when appropriate. Repeat confirmation
   while a launch is pending must not enqueue duplicates.
7. Opening a modal panel freezes world input; backend updates continue without
   taking focus. Escape/back has one owner and restores the correct context.
   New shortcuts must use InputMap and the existing remapping validation.
8. Start with the current three mapped application stations and four capability
   objects. Do not turn every registry entry into a physical object. The quick
   launcher exposes the bounded eligible registry subset; report its cap.
9. Inspector selection and live app/window/media/feed contents stay session-only.
   Preferences remain UI-only and bounded. Default-disabled notifications,
   truthful save failures, reduced motion and silent background updates survive.

## 5. Module responsibilities and implementation seams

Existing `scripts/backend_client.gd` remains the transport adapter and source
of accepted snapshots and correlated request results. Do not duplicate its
state machine inside the inspector or refactor its internals speculatively.

Proposed `scripts/application_selection.gd` owns nearby/selected identity and
context transitions, with a small interface accepting target/registry changes
and exposing a view state. It owns no socket, scene discovery or launch policy.
Tests cross that interface with synthetic targets and registry changes.

Proposed `scripts/application_actions.gd` centralizes explicit launch dispatch
from world, inspector and quick launcher. Its interface accepts a desktop ID and
reports accepted/pending/rejected intent; an injected transport adapter makes
zero/one-request assertions possible. Core remains the final authority. The
module earns its keep by removing duplicate checks and event handling from
three real callers; do not add layers that merely rename a BackendClient call.

Proposed `ui/application_inspector.gd` renders bounded view state and emits user
intent. Proposed `ui/quick_launcher.gd` uses existing list/panel primitives and
stable desktop-ID selection. Neither directly parses IPC or executes programs.

`scripts/main.gd` wires signals rather than becoming the home of all new state.
`ui/overlay_coordinator.gd` owns modal/focus lifecycle, extended for inspector
focus and quick launch only as needed. A visible inspector is not another modal.
`scripts/workstation.gd` keeps world object presentation/interaction; its app
binding still uses registry desktop IDs. Reuse existing session binding.

`ui/design_tokens.gd`, `ui/hud_layout.gd`, `scripts/pixel_art.gd`, `scripts/hub.gd`
and `scenes/main.tscn` own the visual migration. Asset generation remains
deterministic/local. Update the inventory and licenses; no runtime downloads or
untrusted external SVG/icon parsing in the first pass. Curated icons plus
recognizable category and unknown-app fallbacks are sufficient.

These new filenames/interfaces are proposals to refine against code while
implementing. Prefer locality and deletion of superseded paths over a second
parallel UI system or a generic multi-renderer architecture.

## 6. Kanban cards

R6.01 is **In Review** after its native proof and full local gate; owner density
choice remains pending. R6.02–R6.10 remain **Todo**. No card is done because a
corresponding mockup or old implementation exists. Each card includes
focused tests with its implementation, not a testing phase deferred to the end.

### R6.01 — Native composition and density proof · Medium

- Depends on: accepted direction; starts from the current experience baseline.
- Work: capture pre-change synthetic frames and rendered performance; build a
  native blockout of world + inspector at both candidate densities. Record tile,
  camera, text, HUD and collision coordinate assumptions. No final sprite work.
- Touch: project.godot, hud_layout, main scene and a synthetic visual fixture;
  keep candidate settings isolated until the choice is made.
- Verify: 720p/1080p integer scaling, long names/errors, modal-open view,
  grayscale, all seven reachable objects, no player occlusion, existing movement
  and crowded benchmarks. Record actual environment and max-frame outliers.
- Done: owner selects one native layout; >=55 FPS and <=25 ms p95 on the Intel
  UHD baseline. If unavailable, mark the comparison blocked, not accepted.
- Commits: baseline/fixture; native blockout; selected resolution/layout decision.

### R6.02 — Visual tokens, typography and icon grammar · Medium

- Depends on: R6.01. Define world/UI palette, spacing, type sizes, outlines,
  selection/focus markers and ready/waiting/failure markers at the chosen canvas.
- Touch: design_tokens, pixel_art and ASSET_INVENTORY. Separate mechanical token
  migration from visual changes. Avoid individual panels inventing new colors.
- Verify: unknown/long-name app, three mapped apps, all four capabilities,
  selected/disabled/offline/pending/failure states, grayscale and reduced motion.
- Done: approved sprite/contact sheet and native text examples; license/source
  inventory complete; no status depends on color alone.
- Commits: tokens/type; icon family and deterministic generation; inventory.

### R6.03 — Walkable workshop world · Large

- Depends on: R6.01–02. Replace room composition and station silhouettes while
  retaining the current capability set and station mapping behavior.
- Touch: hub, pixel_art, workstation, player, main scene as necessary.
- Verify: deterministic spawn; every object reachable; walls/collision/facing;
  object interaction bounds; no invisible blockers; no object hidden by HUD.
- Done: native owner visual review plus synthetic world layout/art checks pass.
- Commits: geometry; station art; capability objects/environment; review fixes.

### R6.04 — Selection and keyboard context · Medium

- Depends on: R6.01; can progress alongside world art. Implement the interaction
  contract, explicit focus-inspector action and restoration through modal panels.
- Touch: application_selection (new), main, player, overlay_coordinator,
  InputMap/remapping/help/settings definitions where required.
- Verify: near A → walk away → interact does not launch A; A → B selection;
  late panel close; rapid modal transitions; offline/reconnect while paused;
  remapped keys and settings missing new actions receive validated defaults.
- Done: one context owns each key event, no double activation or stranded player.
- Commits: selection model/tests; context wiring; named action/default migration.

### R6.05 — Persistent application inspector · Large

- Depends on: R6.02, R6.04. Render app identity, category/fallback icon, desktop
  ID when useful, availability, observed running state and contextual action.
- Touch: application_inspector (new), HUD layout, main, existing session binding.
- Verify: no selection; first empty registry; missing mapped app; long/unusual
  Unicode labels; selection removed during refresh; offline/stale/waiting;
  modal overlay open; focus and world input behavior.
- Done: inspector is readable at the chosen native scale and non-modal until
  explicitly focused; last useful state survives pause and recoverable errors.
- Commits: view-state rendering; focus/action surface; native state fixtures.

### R6.06 — Unified launch intent and truthful feedback · Medium

- Depends on: R6.04–05. Route station and inspector intent through one dispatcher
  and existing BackendClient request correlation, preserving Core policy.
- Touch: application_actions (new), main, workstation, inspector, focused client
  wiring only if necessary. Remove the old parallel launch call site.
- Verify: zero requests for unknown/offline targets; one request for repeated
  pending confirms; A's result after B is selected; Core restart while pending;
  permanent versus retryable failure; spawn accepted with no observed window.
- Done: all launch states visible without claiming window readiness, no replay,
  duplicate requests, command/path IPC or unexpected workspace/focus changes.
- Commits: dispatcher with fake adapter tests; caller migration; feedback tests.

### R6.07 — Bounded keyboard quick launcher · Medium

- Depends on: R6.04–06. Add a temporary selector, not a permanent C-style rail.
  Reuse PanelShell/ListCursor, stable IDs and the existing eligible registry cap.
- Touch: quick_launcher (new), overlay coordinator, InputMap/remapping/help,
  inspector/selection wiring. No persistence of registry contents.
- Verify: 0/1/600 registry rows, 512-entry cap disclosure; removal/reordering of
  selected row; key repeat; confirm consumed once; cancel/focus recovery;
  backend refresh while open; disabled/unavailable app.
- Done: explicit keyboard opening, selection, launch and cancellation work without
  walking and without leaking input to the world. Search/pagination are deferred
  unless separately scoped; do not imply whole-registry reachability beyond cap.
- Commits: bounded selector/tests; context/action wiring; help/accessibility.

### R6.08 — Harmonize panels, onboarding and preferences · Medium

- Depends on: R6.02, R6.04–07. Update workspace map, media, feed, observatory,
  pause/help/settings to the same visual system. Keep domain behavior local.
- Verify: empty/waiting/stale/unavailable/populated states, first empty feed,
  disabled notifications, nullable telemetry, failed preference save, remapping,
  mute/reduced motion, rapid panel changes and live updates while paused.
- Done: no duplicate visual rules, hidden keyboard actions, clipped required
  controls or regressions to existing privacy and settings semantics.
- Commits: shared skin; domain-panel migrations in small groups; help/onboarding;
  remove dead APIs only after call-site checks.

### R6.09 — Cumulative regression and performance gate · Large

- Depends on: all preceding implementation; test additions start within each card.
- Touch: tests/, check-godot, rendered gate and release checklist.
- Verify: full existing gate, new selection/action/context fixtures and native
  frames for every inspector state. Retain restart, oversized-input, Terminal
  revalidation, empty-feed, crowded-list, resource and preferences regressions.
- Done: graphical full gate passes, movement AND crowded UI >=55 FPS / <=25 ms
  p95 on baseline hardware; record average/p95/max, CPU/RSS and workload. Compare
  before/after rather than inventing a new budget after a failure. Synthetic
  rendered frames contain no private content. Headless subset is not acceptance.
- Commits: fixture integration; performance/report updates; fixes by finding.

### R6.10 — Owner review, demonstration and release decision · Medium

- Depends on: R6.09 and owner review of native art/layout.
- Verify: keyboard-only path across seven objects, inspector and quick launcher;
  default/remapped inputs; one deliberate safe real launch; Core stop/restart;
  notifications disabled/opt-in; media controls; audio/mute; preferences; clean
  exit with normal Hyprland operation. No real app launch in automated tests.
- Done: dated PASS evidence tied to final commit for manual visual/input/audio
  review; full gate on that commit; review findings resolved; README/screenshots
  reflect actual code. Privacy-check any demo before publication.
- Commits: documentation/evidence references; small acceptance fixes. Publication
  and merge require explicit authorization. Mark Phase 6 Done only here.

## 7. Review and integration strategy

Start production work from `cohesive-hub-experience` at `fc9ce6e`, the existing
implemented and locally validated experience baseline, not stale main or the
throwaway prototype branch. Verify live Git state again before implementation.
Do not require approval of the obsolete visual target before replacing it.

Suggested review slices (names, not PR numbers or already-created branches):

| Branch / review slice | Cards | Review stop |
| --- | --- | --- |
| workshop-shell | R6.01–02 | Native density choice and visual grammar |
| workshop-world | R6.03 | Reachability, collision, native art |
| application-inspector | R6.04–06 | Context ownership and real request semantics |
| keyboard-launcher | R6.07 | Bounded direct launch without event leakage |
| workshop-panels | R6.08 | Existing capabilities retained consistently |
| workshop-validation | R6.09–10 | Full gate plus owner acceptance |

Use stacked review against the experience integration branch until the accepted
redesign is ready; do not silently merge incomplete slices to main. Re-run tests
on the final combined head, not just each branch. Keep commits narrow: model,
wiring, visual migration and regression fixes separately. Reconfirm explicit
authorization before push, PR creation or merge. Never commit caches, private
docs or brag-output/. Do not claim CI passed from local results; the recorded
workflow is Rust-only and current GitHub status must be checked when publishing.

## 8. Evidence and acceptance commands

Run existing focused fixtures via the documented harness as each slice lands:

```bash
./scripts/velora.sh check
./scripts/velora.sh ipc-check
./scripts/velora.sh gate
VELORA_PHASE_SIX_REPORT_DIR=/tmp/velora-workshop-review \
  ./scripts/check-phase-six-rendered.sh
./scripts/velora.sh dev
```

Use unique evidence directories when comparing runs. `gate --headless` is only
a subset. New test files must be wired into check-godot/gate, not merely added
to disk. Tests use temporary sockets, private D-Bus fixtures, synthetic snapshots
and injectable settings paths, never live desktop data or real app processes.

Historical baseline at `fc9ce6e`: 226 Rust tests and full local gate passed;
movement 60.00 FPS / 17.37 ms p95 / 20.31 ms maximum; crowded 59.21 FPS /
17.29 ms p95 / 33.50 ms maximum on Intel UHD CML GT2. These are previous evidence,
not this plan's test results or a zero-hitch/live-transport claim. Re-measure
before R6.01 and after the redesign. Owner acceptance remains pending.

## 9. Roadmap after accepted Phase 6

### Phase 7 — Flat Desktop-file world (proposed, not implementation-ready)

First resolve executable meaning, symlink/hidden-file policy, Desktop directory
resolution and safe default-opener behavior. Unknown policy is not consent.
Recommend failing closed on unsupported executables and ambiguous roots until
the owner decides; do not claim these recommendations are already accepted.

Then plan these ordered slices, with separate security review before opening:

1. F7.01 — Resolve and validate a deliberately scoped Desktop root; never fall
   back silently to scanning home or `/`.
2. F7.02 — Bounded, nonrecursive file index and typed metadata using temporary
   directory fixtures; ignore folders under the agreed first-slice scope.
3. F7.03 — Explicit file-list/open-file protocol design with opaque identity,
   message/page bounds and a version/compatibility decision. Keep app-launch
   and file-open authority separate; do not smuggle paths into LaunchApplication.
4. F7.04 — File-type sprite grammar and bounded keyboard layout; preserve the
   workshop's selection/inspector model without equating a file with an app.
5. F7.05 — Explicit open action through a mockable opener adapter; revalidate
   identity, current file and allowed scope at action time. Review replacement,
   traversal and symlink races. No shell commands or arbitrary executable IPC.
6. F7.06 — Bounded refresh/change handling, removed/stale-item behavior and
   reconnect recovery without unbounded watchers or queues.
7. F7.07 — Unit/integration/security/rendered/performance tests; no real app
   opens in automated tests and no actual Desktop scan in fixtures.
8. F7.08 — Owner acceptance with deliberately chosen files and clean demo;
   document supported categories and limitations before release.

Only browse/open files directly on Desktop. No folder traversal, recursion,
create/rename/move/overwrite/delete or automatic home indexing. PDFs/documents/
slides are intended categories; games/browsers may already be registry apps.
Windows `.exe` compatibility is not implied. Resolve that ambiguity explicitly.

### Phase 8 — Directory-backed world traversal (discovery only)

After Phase 7 acceptance: user-selected roots, read-only traversal, bounded room
generation/cache, explicit navigation/back semantics, selection restoration,
permissions/stale paths, and cross-room performance/security review. Do not
expand to a destructive file manager or a compositor. Define cards only after
learning from the flat Desktop slice rather than pretending detailed estimates
are already validated.

Controller support, broad mouse interaction, filesystem mutations, autostart and
desktop replacement are outside these commitments.

## 10. Learning track alongside implementation

Before new Rust filesystem work, trace one existing station launch through
BackendClient → native bridge → Unix socket → protocol → Core handler → registry
→ fresh launch policy → response. Explain processes, threads, file descriptors,
permissions, async ownership, typed messages and error propagation using actual
files/functions. Add a deliberately failing temporary-fixture test, then let the
owner implement a selected meaningful Rust slice and explain the fix back.
Agent-led UI/support work must not substitute for the owner's systems learning.
