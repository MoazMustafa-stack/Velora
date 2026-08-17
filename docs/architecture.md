# Velora architecture

Velora runs as two normal user processes inside Omarchy's existing
Hyprland session. Hyprland remains the compositor and Omarchy remains the
owner of desktop configuration.

```text
Omarchy + Hyprland
 ├── normal applications
 └── Velora Godot frontend ── JSON lines / Unix socket ── Velora Core
                                                        └── safe desktop APIs
```

Godot owns rendering, input, interaction, HUD, and spatial presentation. Rust
owns Linux integration and is the only component allowed to launch applications.
The frontend makes typed semantic requests; there is no arbitrary command IPC.

The v0.1 core has a deliberately narrow demo catalog (`code.desktop` and
`codium.desktop`). Application discovery and Hyprland IPC are planned work.
