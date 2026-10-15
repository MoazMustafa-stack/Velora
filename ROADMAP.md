# Velora roadmap

Velora remains an experimental keyboard-driven interface inside an existing
Linux desktop, not a replacement compositor or file manager. Implemented code,
automated evidence and owner acceptance are separate milestones.

## Current milestone: Phase 6 prototype acceptance

- Phases 1–5: merged foundations, application registry/launch policy,
  Hyprland state/actions, aggregate telemetry, media and opt-in notifications.
- D6.01–D6.04: merged UI tokens, primitives, settings and overlay foundation.
- D6.05–D6.12: implemented experience, local audio, keyboard remapping and
  station mapping; final owner acceptance remains in review.
- D6.13: cumulative automated gate and rendered crowded-UI benchmark are
  implemented. Complete the [owner checklist](frontend/godot/RELEASE_REVIEW.md)
  before claiming Phase 6 complete or merging a release.

Keep this milestone focused on reproducibility, safe failure/reconnect behavior,
clear architecture, bounded resources and a clean keyboard demonstration.
Controller code currently exists but is experimental, not part of the product
acceptance target. Its future handling remains separate work.

## Next proposed slice: flat Desktop-file world

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

## Longer-term direction

Directory-backed worlds that can be traversed seamlessly, with applications as
tools inside those spaces. Broader traversal, filesystem mutations, deeper
desktop replacement and controller support are not promises for the current
prototype. Each needs a separate design, security boundary and acceptance plan.
