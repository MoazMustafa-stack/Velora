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
and volume (0–1), up to four keyboard keys per named action, and fixed
editor/browser/terminal slots containing syntactically validated desktop IDs.
Missing values use defaults; invalid files use all defaults; unknown fields
are ignored and never written back. No live system data is stored.

The pause menu now exposes onboarding replay/dismissal, reduced motion and
local audio preferences, plus a confirmed UI-only reset. Generated local cues
use only the app's `VeloraUI` bus, never the system mixer or MPRIS volume.
The controls page captures keyboard remaps, rejects active-context conflicts
and preserves Escape as cancellation/recovery. Experimental controller code is
still present and can change prompts when a pad is used, but controller support
is outside the current keyboard-only product acceptance. Invalid persisted key
conflicts restore defaults without trapping input. Modified chords are not
supported; plain Shift/Ctrl/Alt keys are allowed.

The station chooser maps editor/browser/terminal slots to IDs from Core's
current registry, with at most 512 choices. Duplicate names are disambiguated
by the selected desktop ID. Missing saved IDs remain unavailable; malformed
IDs fall back to defaults with visible warnings. A stored desktop ID must still
resolve against the live trusted registry before a launch can be requested.
It is never a command, path, argument list, or permission to bypass Core.

Scene tests disable preference IO or inject unique temporary paths. Startup
reads but does not write; completing/dismissing onboarding or an explicit
settings action saves only allowlisted UI preferences. Reset preserves the
existing in-memory settings if removing the owned file fails. A save failure
is shown inside the settings overlay; no runtime snapshots enter the file.
Valid changes still apply for the current session when saving fails; the modal
explicitly says APPLIED / NOT SAVED instead of claiming persistence.

Core's registry and launch policy remain the final authority. No commands,
Exec strings, window metadata, media content or notification contents are
written into preferences. Resetting keys or station mappings affects only
those preferences; the confirmed whole-UI reset restores all UI defaults.
