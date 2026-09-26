# Configuration boundaries

The old `default.toml` was never loaded and advertised protocol v1. It has
been removed; the current wire version is owned by `velora-protocol`, not
user configuration. Core runtime options remain the environment variables
documented in the root README.

Frontend UI preferences use `scripts/settings_store.gd` in the Godot project.
The store owns `user://velora-settings.json` with schema version 1 and a
16 KiB maximum. Loading or constructing the store never creates a file.
Only explicit save/reset operations write, and reset removes only that file.

Allowlisted preferences: onboarding completion, reduced motion, UI-audio mute
and volume (0–1), up to three keyboard keys per named action, and fixed
editor/browser/terminal slots containing syntactically validated desktop IDs.
Missing values use defaults; invalid files use all defaults; unknown fields
are ignored and never written back. No live system data is stored.

This is a foundation API, not a new settings UI or remapping feature.
Later Phase 6 cards consume these preferences. A stored desktop ID must still
resolve against the live trusted registry before a launch can be requested.
It is never a command, path, argument list, or permission to bypass Core.
