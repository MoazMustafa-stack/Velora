# ADR 0001: Keep Hyprland as compositor

Velora is a normal application inside Omarchy rather than a Wayland
compositor or replacement desktop session. This preserves the user's normal
desktop if Velora fails and allows incremental integration through public
interfaces.
