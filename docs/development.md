# Development

Requirements: Rust stable and Godot 4. Godot was missing during the bootstrap
audit; install it through Omarchy when you are ready:

```bash
omarchy pkg add godot
```

Run the core and frontend separately:

```bash
./scripts/run-core.sh
./scripts/run-velora.sh
```

Validate Rust with:

```bash
./scripts/check.sh
```

For an isolated terminal test outside a graphical session, point the core at a
temporary socket with `VELORA_SOCKET=/tmp/velora-dev.sock cargo run`
from `core/`.

Godot validation after installation: open `frontend/godot/project.godot`, run
the main scene, confirm movement, mouse capture/release, terminal prompt,
backend-offline handling, then run the core and confirm `pong` in the HUD.
