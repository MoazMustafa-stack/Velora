# Omarchy integration audit

## Detected environment

- OS: Omarchy 4.0.0 (Arch-based), kernel `7.1.8-arch1-3`
- Session: Wayland / Hyprland; a Hyprland instance signature and runtime
  directory (`/run/user/1000`) are present.
- Rust/Cargo: 1.92.0; Git: 2.55.0.
- Godot: not installed at audit time.

`hyprctl` could not contact the compositor socket from the bootstrap process,
so live clients/workspaces and the exact Hyprland version were unavailable.
This is not a configuration conflict; it only blocks live IPC validation in
this process context.

## Configuration layout

`~/.config/hypr/hyprland.conf` sources Omarchy defaults from
`~/.local/share/omarchy/default/hypr/`, then explicitly sources personal files
in `~/.config/hypr/` including `bindings.conf`. A Lua configuration path also
loads `hypr.bindings` after Omarchy defaults. `~/.config/omarchy/` contains the
shell configuration, extension menu, hooks, and themes.

Velora must not overwrite any of those files, the active theme file, or
Omarchy package files. The present launcher/keybinding setup is retained as
the fast fallback; the user's personal binding file includes an example
reservation for `SUPER + H`, so no Velora binding is proposed yet.

## Compatibility assessment

**SAFE.** Velora is designed to run as an ordinary Godot client and Rust
user daemon. A crash cannot replace Hyprland or alter the session. The only
minor concern is missing Godot 4; install it before graphical testing.

## Supported future integration

Use `$XDG_RUNTIME_DIR` for the core socket, XDG desktop entries for apps, and
Hyprland IPC only when available. Any eventual convenience binding must be a
small, user-owned addition to the existing personal bindings file, after an
explicit collision check and user approval. Undoing current integration simply
means stop the two processes: no Omarchy integration currently exists.
