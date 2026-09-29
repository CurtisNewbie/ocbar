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
- `main.swift` → `AppDelegate` (status item, menu, bubble, UserDefaults config) → `SessionMonitor` (`@MainActor`, owns 2s scan + 0.5s poll timers and `AppState`) → inline HTTP.
- Discovery: reads `~/.local/state/opencode/service.json` (url, pid, version, password) to locate the single shared OpenCode v2 service; authenticates with HTTP Basic auth (username `opencode`, password from that file). `ProcessScanner.swift` is deleted.
- HTTP polling hits the service endpoints: `GET /api/info` (health/identity), `GET /api/session/active` (busy sessions), `GET /api/session?limit=100&order=desc` (session list incl. project directory), and `GET /api/form` / `GET /api/permission/request` scoped by `location[directory]=<dir>` (pending user input).
- Visibility: the 2s scan matches running processes by executable name (`ps -Ao pid=,comm=`, last path component `opencode`, excluding the `service.json` pid) and collects their cwds via `lsof`. A session is shown only if its directory has an attached client, so client-less orphaned sessions (e.g. blocked on a permission prompt) are ignored.
- **`OpenCodeClient.swift` is currently dead code** — nothing references it; `SessionMonitor` inlines its own HTTP calls. Don't extend it expecting it to be wired in.
- busy → idle/waiting transitions drive notifications + speech bubble. App targets OpenCode v2 only: all sessions share one `opencode serve --service` process, so no per-terminal `--port` is needed. v1 users should use tag `oc_v1`.
- Only root sessions (top-level, not subagent children) that are active/waiting or updated within 30 min are shown, labeled by project folder name. Menubar shows per-session labels up to a cap (default 4, configurable 1–10 via menu → "Projects shown", UserDefaults key `ocbar.projectsShown`).
