# Contributing to Velora

First off — thanks for wanting to help. Velora is a small, open-source
project run by a handful of maintainers. Outside contributions are very
welcome.

This project is early and stage-gated, so a few ground rules keep it healthy
for everyone. Please read the whole page before opening an issue or PR.

## House rules

- **Be nice.** This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
  Harassment, trolling, and hostile review aren't welcome.
- **Code quality is non-negotiable.** Every change must keep `./scripts/check.sh`
  green: `cargo fmt`, `cargo check`, `cargo clippy -D warnings`, and `cargo test`.
  CI enforces this automatically.
- **Small, focused changes win.** A PR does one thing well. Giant
  everything-changes PRs are hard to review and hard to merge.
- **Keep the safety boundary intact.** The core must stay non-destructive:
  never overwrite Omarchy/Hyprland config and never add arbitrary shell-command
  IPC. If a change touches that, expect extra scrutiny.
- **Attribution.** Velora is [BSD-3-Clause](LICENSE). By contributing you agree
  your changes are licensed under it. A `CONTRIBUTORS.md` entry is added at
  merge time so your work is credited.

## How to contribute

### 1. Find or open an issue

Start with an issue so we agree on direction before code. Check the roadmap and
existing issues first — there may already be discussion.

- **Bugs:** use the bug report template.
- **Ideas / features:** use the feature request template.

### 2. Fork and work on a branch

```
git clone https://github.com/MoazMustafa-stack/Velora.git
git checkout -b my-feature
```

Keep changes on a branch off `main`. Match the existing style and run the
checks locally before pushing (see [Development](#development)).

### 3. Open a pull request

Open a PR against `main` using the PR template. Link the issue it fixes.
CI will run `./scripts/check.sh` automatically; ensure it passes. A maintainer
will review — small, scoped PRs get reviewed fastest.

When a PR is merged, the contributor's name is added to
[CONTRIBUTORS.md](CONTRIBUTORS.md) so the work is credited.

## Development

Velora is Rust (native Core + GDExtension bridge) with a Godot frontend.

```bash
./scripts/check.sh   # Rust: fmt, check, clippy, test — runs in CI
./scripts/velora.sh dev   # full local system (Core + Godot)
```

Godot acceptance/performance checks (`./scripts/velora.sh gate`, `all`) need a
working desktop/display and are run locally by maintainers; they're not part of
headless CI.

## Getting help

If you're unsure where to start, open an issue with a question or tag it
`good first issue`. No question is too basic.
