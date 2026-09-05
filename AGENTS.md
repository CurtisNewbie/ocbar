# AGENTS.md

macOS menubar app (Swift/AppKit, no SwiftUI) that monitors OpenCode sessions across terminals. App code lives in `ocbar/`.

## Build & run
- **Canonical build is `build.sh`, not Xcode.** From `ocbar/`:
  ```bash
  ./build.sh                # swiftc compile -> ocbar_bin, bundles ocbar.app
  ./build.sh && open ocbar.app   # rebuild + launch after code changes
  ```
- Requires Xcode Command Line Tools (`xcode-select --install`). Builds **arm64-only**, target `macos13.0`.
- App is `LSUIElement` (menubar-only, no Dock icon). Notifications permission prompt appears on first run.
- If macOS blocks the app: System Settings → Privacy & Security → Open Anyway.
- Project copy is `ocbar/ocbar.app`; if you also copied to `/Applications`, `cp -R ocbar.app /Applications` again after each rebuild.
- `ocbar_bin` and `ocbar.app` are gitignored build artifacts.

## Adding / editing Swift files
- `build.sh` compiles an **explicit hardcoded file list** in order. A new `.swift` file is silently not compiled until added there (and to `ocbar.xcodeproj/project.pbxproj` to keep Xcode builds working).
- Top-level executable code is only allowed in `main.swift` (Swift rule) — keep it last in the list.
- No tests, no CI, no linter. Verify with a successful `./build.sh`.

## Architecture
- `main.swift` → `AppDelegate` (status item, menu, bubble, UserDefaults config) → `SessionMonitor` (`@MainActor`, owns 1s scan + 200ms poll timers and `AppState`) → `ProcessScanner` / inline HTTP.
- `ProcessScanner` discovers servers via `ps aux` shell + `lsof` (ports + cwd for project dirs).
- HTTP polling hits `http://127.0.0.1:<port>` endpoints: `/global/health`, `/project/current`, `/session/status`, `/question`.
- **`OpenCodeClient.swift` is currently dead code** — nothing references it; `SessionMonitor` inlines its own HTTP calls. Don't extend it expecting it to be wired in.
- busy → idle/waiting transitions drive notifications + speech bubble. Only sessions started with `opencode --port <n>` are monitorable (bare `opencode` starts no HTTP server).
- Menubar shows per-session labels up to a cap (default 4, configurable 1–10 via menu → "Projects shown", UserDefaults key `ocbar.projectsShown`).
