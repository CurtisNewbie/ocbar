# AGENTS.md

ocbar is a macOS menubar app (Swift/AppKit, no SwiftUI) that monitors OpenCode v2 sessions across terminals. App code is in `ocbar/`.

## Build and verify

```bash
./build.sh    # swiftc compile -> ocbar/ocbar_bin, bundle ocbar/ocbar.app, install the TUI plugin, install + launch ~/Applications/ocbar.app
```

- **`build.sh` is the only build path** — Xcode is not used. It also quits and relaunches the running app, so a rebuild is immediately live.
- **A new `.swift` file must be added in two places or it is silently not compiled**: the hardcoded list in `build.sh`, and `ocbar/ocbar.xcodeproj/project.pbxproj`. Top-level executable code is only allowed in `main.swift`, which stays last in that list.
- arm64-only, target `macos13.0`; requires the Xcode Command Line Tools.
- **No tests, no CI, no linter.** The only verification is a successful `./build.sh`.

## Where the detail lives

Each file below is a decision record: the invariant, the number that is not derivable, and the alternative that was rejected. Read the one that covers what you are changing.

- [`docs/session-monitoring.md`](docs/session-monitoring.md) — service discovery, the HTTP endpoints, which sessions appear, and the pid↔session binding (the `ocbar-bridge` TUI plugin, the argv fallback).
- [`docs/context-usage.md`](docs/context-usage.md) — the optional context-window readout: its keys, where the numbers come from, and the presentation the dropdown and the island share.
- [`docs/island.md`](docs/island.md) — the island window, one panel per screen, the expanded card, and the three UI traps that were real bugs here.
- [`docs/island-pill.md`](docs/island-pill.md) — the collapsed pill's geometry, and `IslandRing`, the app's one running mark.
- [`docs/island-alert.md`](docs/island-alert.md) — the unprompted alert, what owns its fold while it is open, and its three exits.
- [`docs/menubar-and-reminders.md`](docs/menubar-and-reminders.md) — the menubar label and the reminder chain: bubble, island, alert sound.