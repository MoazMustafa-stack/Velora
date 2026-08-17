# ADR 0002: Use a Rust core daemon

Linux integration lives in a separate Rust process so Godot stays focused on
presentation and no Linux shell commands are spread through GDScript.
