# Velora

Velora presents applications and desktop capabilities as a keyboard-navigable
world inside an existing Linux desktop.

## Language

**Workshop**:
A walkable room containing tools represented as world objects.

**World object**:
A positioned, identifiable object that can be approached and interacted with.

**Application station**:
A world object representing an installed application.
_Avoid_: File object, arbitrary command

**Capability object**:
A world object representing a desktop capability such as workspaces, media,
notifications or system information rather than an application.

**Nearby object**:
The reachable world object currently offered for interaction.
_Avoid_: Selected application

**Selected application**:
The application whose identity and state are being inspected, which need not
be the application nearest the player.
_Avoid_: Focused window, nearby object

**Application inspector**:
A persistent view of the selected application's identity, availability and
launch feedback.
_Avoid_: Notification log, modal launcher

**Quick launcher**:
A temporary keyboard-driven application selector that avoids requiring a walk
to an application station.

**Launch accepted**:
Confirmation that an application launch request was accepted, not confirmation
that a window is visible, ready or focused.
_Avoid_: Window ready, launch successful without qualification

**Running application**:
An application associated with an observed desktop window, independently of
whether its most recent launch request was accepted.

**File object**:
A world object representing a file rather than an installed application.

**Directory-backed world**:
A navigable space whose contents correspond to a deliberately chosen directory.
