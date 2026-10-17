# Phase 6 prototype acceptance

This is an evidence checklist, not a declaration that Phase 6 is complete.
The 2026-10-16 [workshop redesign plan](WORKSHOP_PLAN.md) supersedes the former
visual target. Keep the behavioral checks below; re-run them on the redesign.
Native density choice, inspector/quick-launcher input ownership and updated art
require new evidence. Do not approve the obsolete UI as a prerequisite to work,
or treat a previous gate result as acceptance of new code.
The product target is keyboard-only. Controller code already exists and is
being left untouched for the owner to handle; physical-controller acceptance
is **not** a requirement for this prototype milestone. Existing synthetic
controller checks remain regression protection, not a supported-product claim.

## Automated gate

R6.02 visual-sheet approval is recorded for 2026-10-17. R6.03–R6.05 production
work is implemented; the full local graphical gate passed on 307a2bb. Owner
room/keyboard review remains pending. See [WORKSHOP_REVIEW.md](WORKSHOP_REVIEW.md)
for per-card evidence. F focuses inspection by default (remappable); E/Enter still acts only
on a physically nearby object. Inspector launch actions are not implemented.

Run from the repository root in a graphical session:

```bash
./scripts/velora.sh gate
```

The cumulative gate includes Rust formatting/tests/strict Clippy, all Godot
regressions, static security, Core/private-D-Bus resource budgets, temporary
socket IPC restart, owned-child supervisor cleanup, rendered layout captures,
and movement plus crowded-UI benchmarks. Frontend fixtures have a 120-second
timeout (override with VELORA_TEST_TIMEOUT_SECONDS, integer 1–600); IPC and
supervisor harnesses have separate deadlines. A timeout is a failure.

For a machine without a display:

```bash
./scripts/velora.sh gate --headless
```

This reports **headless automated subset**, not full rendering or release
acceptance. The full gate refuses to silently skip rendering. For rendered-only
rechecks and an explicit evidence directory:

```bash
VELORA_PHASE_SIX_REPORT_DIR=/tmp/velora-release-review \
  ./scripts/check-phase-six-rendered.sh
```

Inspect `frames/`, `movement-performance.json`, `crowded-performance.json`, and
their logs. Defaults create a unique directory under /tmp and print its path.
Captures are synthetic viewport images, never desktop screenshots. Fixtures
disable live transport, preference IO, and audio; IPC tests own temporary
sockets and never create real application processes. Resource tests use a
private bus or disable integrations, not the production bus.

Both rendered benchmarks require at least 55 FPS average and at most 25 ms p95.
The crowded fixture measures movement, overlay transitions, nullable telemetry,
32 feed rows, 16 players, 20 workspaces and a 603-entry registry (three mapped
plus 600 fake) capped to 512 chooser entries, with repeated snapshot/registry
refreshes while paused. Its data deliberately stresses UI bounds;
it does not measure live IPC throughput
or replace protocol wire-size validation. Report the adapter and workload with
any performance claim, including maximum-frame outliers.

The current GitHub workflow runs Rust checks only. A local full-gate pass does
not mean GitHub CI or a human review passed; do not describe it that way.

## Manual keyboard acceptance — pending owner evidence

Use `./scripts/velora.sh dev` in your normal session. Keep personal notifications
disabled unless deliberately testing opt-in. Do not publish real filenames,
window titles, notifications, player metadata or terminal logs.

For each item record: date, code commit, environment, action, expected result,
actual result, PASS/FAIL, and evidence path. A blank item is **pending**, not PASS.

| Check | Expected result | Result |
| --- | --- | --- |
| Default keyboard path | Reach all seven objects; facing, collision, prompts and Escape work; no controller needed | Pending |
| Remapped keyboard path | Reject conflicting keys; cancel capture; remap, restart, use and reset bindings; Escape recovery remains usable | Pending |
| Native/scaled visuals | Validate the canvas selected in R6.01 and integer-scaled views; long text clips; player and objects remain distinct in grayscale | Pending |
| Inspector ownership | Persistent selected-app state does not steal movement; explicit focus/back and late launch feedback remain correct | Pending |
| Quick launcher | Bounded stable-ID selection; one launch per confirmation; cancel restores focus; no input leaks to world | Pending |
| Offline/reconnect | Start frontend first; start Core; stop/restart only the test Core; useful state returns without restarting Godot | Pending |
| Pause updates | Core/media/feed/telemetry changes do not erase modal ownership or strand player input; closing restores useful prompts | Pending |
| Empty/unavailable states | Distinguish empty registry, no players, no notifications, notifications disabled, monitor unavailable/restricted and Core offline | Pending |
| Station mapping | Map a known application, restart, and explicitly launch it; unknown/unavailable IDs show failure; reset safely | Pending |
| Audio | Cues are quiet and useful; background changes silent; mute/zero-volume/persistence/reset work without changing system/media volume | Pending |
| Preferences | Change/restart/reset UI settings; errors are truthful; no live content is persisted | Pending |
| Reduced motion | No flashing or motion-only status; reduced-motion setting persists and remains readable | Pending |
| Clean exit | Exit Velora; the runner removes its Core child; normal desktop and shortcuts still work | Pending |
| Public demo | Show keyboard interaction, one safe launch, Core recovery and clean exit without exposing private data | Pending |

Manual application launches are explicit owner actions, not automated tests.
Physical-controller checks are optional future work and must not be conflated
with this keyboard acceptance list.

## Known scope and deferrals

- Application chooser is intentionally capped at 512 eligible desktop IDs;
  applications outside that subset are not selectable there. No search or
  chooser pagination is claimed. ID-based launch policy remains authoritative.
- Folder traversal, Desktop-file discovery, document opening, file-type sprites,
  arbitrary executable launch and Windows compatibility are not implemented by
  this milestone. They are not implied by existing application stations.
- Next proposed file-world: direct Desktop files, no folder recursion, browsing
  and opening only. Installed applications and ordinary files need different
  authority paths. Executable meaning and hidden/symlink policy remain unsettled;
  do not silently implement these during the feature freeze.
- No autostart, system configuration edits or replacement desktop claim.

Phase 6 is accepted only after the automated gate and the required owner
keyboard/visual/audio checklist have recorded passing evidence. Do not mark
pending manual checks complete merely because the code or this file exists.
