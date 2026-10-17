# Velora roadmap

Velora remains an experimental keyboard-driven interface inside an existing
Linux desktop, not a replacement compositor or file manager. Implemented code,
automated evidence and owner acceptance are separate milestones.

## Current milestone: Phase 6 workshop redesign

The owner selected a walkable pixel workshop with a persistent application
inspector on 2026-10-16. The previous UI is not visually accepted; do not require
approval of it before replacing it. Preserve its functioning systems and tests.
See the [revised implementation plan](frontend/godot/WORKSHOP_PLAN.md) for scope,
module responsibilities, dependencies, commit/review slices and acceptance.

- Phases 1–5: merged foundations, application registry/launch policy,
  Hyprland state/actions, aggregate telemetry, media and opt-in notifications.
- D6.01–D6.04: merged UI tokens, primitives, settings and overlay foundation.
- D6.05–D6.12: implemented experience, local audio, keyboard remapping and
  station mapping; final owner acceptance remains in review.
- D6.13: cumulative automated gate and rendered crowded-UI benchmark are
  implemented. Complete the [owner checklist](frontend/godot/RELEASE_REVIEW.md)
  together with the redesign acceptance before claiming Phase 6 complete or
  merging a release. Historical gate results do not validate the new design.

Existing D6 card numbers are retained as implementation history. R6.01's isolated
native proof and full local gate pass; the owner approved 640×360 with the lower
inspector on 2026-10-16. R6.02's native visual sheet was approved on 2026-10-17.
R6.03–R6.05 are implemented with passing focused checks and a full graphical
gate on 307a2bb, pending final owner room/input review. R6.06–R6.10 remain Todo.
See the
[implementation review](frontend/godot/WORKSHOP_REVIEW.md)
for measurements and limitations; accepting a direction does not complete cards.

| Card | Implementation |
| --- | --- |
| R6.01 | Native composition and density proof: compare 320×180 / 640×360 |
| R6.02 | Visual tokens, typography and icon grammar |
| R6.03 | Walkable workshop world |
| R6.04 | Selection and keyboard context |
| R6.05 | Persistent application inspector |
| R6.06 | Unified launch intent and truthful feedback |
| R6.07 | Bounded keyboard quick launcher |
| R6.08 | Harmonize panels, onboarding and preferences |
| R6.09 | Cumulative regression and performance gate |
| R6.10 | Owner review, demonstration and release decision |

The production native canvas is now 640×360 with a lower inspector; the world
remains an unscaled 320×128 view enlarged 2×. R6.01's original proof alone did
not implement this migration; R6.03–R6.05 now apply it.
Retain Core, bridge, protocol v5, launch policy and existing capability models.
The redesign adds no filesystem authority or new Linux integration.

Keep this milestone focused on reproducibility, safe failure/reconnect behavior,
clear architecture, bounded resources and a clean keyboard demonstration.
Controller code currently exists but is experimental, not part of the product
acceptance target. Its future handling remains separate work.

## Phase 7 proposal: flat Desktop-file world

After current milestone acceptance, plan a bounded read-only index of files
directly on Desktop, with file-type sprites and explicit open interactions.
No folder recursion or file creation, rename, move, overwrite or deletion.
Document opening is a new capability, not something current application launch
IPC already supports. Applications must retain their separate registry-backed
authority path.

Still to decide before implementation: supported file/executable categories,
hidden entries, symlink handling, default-opener policy and how an ambiguous
Desktop directory is rejected safely. Do not imply that Windows executables or
arbitrary programs can be launched through ordinary file objects.

Proposed sequence: root policy → bounded index → explicit file-list/open
protocol → file objects → safe opener → bounded refresh → automated gate →
owner review. These cards are not implementation-ready until the policies above
are resolved. See the implementation plan for the F7.01–F7.08 outline.

## Phase 8 discovery: directory-backed world traversal

Directory-backed worlds that can be traversed seamlessly, with applications as
tools inside those spaces. Broader traversal, filesystem mutations, deeper
desktop replacement and controller support are not promises for the current
prototype. Each needs a separate design, security boundary and acceptance plan.
