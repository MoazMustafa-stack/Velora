# D6.01–D6.04 foundation acceptance

Reviewed on 2026-09-26 against merged Phase 5 baseline `5bdf1dc`.
This records local evidence, not a claim that GitHub CI ran.

| Card | Evidence |
| --- | --- |
| D6.01 | Token tests; byte-identical before/after token-migration frames for hub, feed, empty media and workspace map; inventory in `ASSET_INVENTORY.md` |
| D6.02 | Existing notification/media suites retained; cursor tests for bounds, wrap, deletion and stable keys; workspace handle preservation; counters and 20-cell geometry regression tests |
| D6.03 | Temporary-file round trips, defaults, corrupt/oversized/unknown/partial files, malformed bindings/IDs, field allowlist, mutable-copy isolation, reset isolation; unused v1 config removed |
| D6.04 | 30 cycles through all modal states; late close rejection; live status while paused; real prompt restoration; actual viewport key events; context-specific media keys and InputMap substitution |

## Validation

- `./scripts/velora.sh gate`: passed, including 224 Rust tests, strict Clippy,
  all prior frontend tests, the five new foundation suites, security checks,
  and Core/private-D-Bus resource gates.
- `./scripts/check-ipc.sh`: passed isolated handshake/restart/reconnect.
- `./scripts/check-dev.sh`: passed normal-exit and signal child cleanup.
- `./scripts/velora.sh perf`: passed on Intel UHD (CML GT2), Wayland,
  Compatibility renderer, 600 frames. Before: 60.00 FPS, 18.43 ms p95.
  After: 60.00 FPS, 17.09 ms p95. These samples show no budget regression;
  they are not a claim of a statistically significant speedup.
- Core idle CPU: 0.0%, RSS growth 20 KiB. Private-D-Bus overhead: 1756 KiB,
  growth 0 KiB during the sample window.
- Input-action and overlay suites also passed with the real Wayland renderer.
- Agent inspected native 320 × 180 and integer-scaled synthetic frames:
  populated/empty feed, restricted state, populated/stale media, crowded
  workspaces and pause. No live data was captured.
- `git diff --check`: passed. No Core/protocol changes in this branch,
  no system configuration writes, no private docs or generated media staged.

## Review findings resolved

- Clipped counters were squeezed to zero width next to an expanding title:
  reserve a bounded counter region and test its width.
- Clipped workspace cells collapsed to unreadable strips: assign a fixed
  column width and preserve the selection by handle across updates.
- A full 20-cell map exceeded the canvas by six pixels: tighten cell vertical
  margins; verify the complete panel/footer fits within 180 px.
- A settings file could grow between its size check and read: bound both.

## Boundaries and follow-up

This is an implementation self-review, not an independent human approval.
Rendered keyboard tests use synthetic input; the owner's real-system Phase 5
acceptance is recorded on PR #8. No new live application launch is claimed.

Existing pause copy still says Phase 1 and its telemetry/HUD layering needs
the planned D6.06/D6.08 pass. The settings API deliberately does not introduce
a settings UI, apply remapping, or make saved station IDs launchable.
Those remain later cards, along with color/grayscale accessibility refinement.

Next: D6.05 — unified world-object art and hub layout. Phase 6 as a whole is
not complete; D6.05–D6.13 remain.
