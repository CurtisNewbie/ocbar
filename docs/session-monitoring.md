# Session monitoring

This file documents how ocbar finds the OpenCode service, decides which sessions to show, and binds each one to the terminal client driving it.

## Topology

- `main.swift` → `AppDelegate` (status item, menu, bubble, UserDefaults config) → `SessionMonitor` (`@MainActor`, owns 2s scan + 0.5s poll timers and `AppState`) → inline HTTP.

## Discovery and HTTP polling

- Discovery reads `~/.local/state/opencode/service.json` (url, pid, version, password) to locate the single shared OpenCode v2 service, and authenticates with HTTP Basic auth (username `opencode`, password from that file).
- Polling hits `GET /api/info` (health/identity), `GET /api/session/active` (busy sessions), `GET /api/session?limit=100&order=desc` (session list incl. project directory), and `GET /api/form` / `GET /api/permission/request` scoped by `location[directory]=<dir>` (pending user input).

## Which sessions appear

One rule, in three parts:

- **Root only.** Only root sessions (`parentID == nil`, not archived) are considered. Each root's status is derived from the union of itself and its descendants: waiting if any descendant is waiting, else busy if any is active, else error when the root's own `outcome == "failed"`, else idle.
- **Recently relevant.** A root appears while its own or a descendant's work is busy/waiting, or once it has been viewed and `max(viewed, updated)` is within `recentWindow` (43200s = 12 h). An unviewed session — for example a headless `opencode run` — therefore shows only while it is busy or waiting.
- **Bound.** A root appears only if a running client is bound to it by exact session id (`guard let pid = sessionIDToPID[id]` in `SessionMonitor.publish`'s fetch path). Client-less orphaned sessions — e.g. one blocked on a permission prompt with no terminal attached — are dropped here.

Sessions are never collapsed per directory: every bound root is emitted as its own row. A root that a visible session was forked from is hidden, so one project does not show two identical rows.

## Client ↔ session binding

- A client pid is bound to **exactly** the session it is driving. The primary source is the live binding the ocbar-bridge plugin publishes (`~/.local/state/ocbar/bindings/<pid>.json`, see below); if a live client pid has no fresh binding file, ocbar falls back to parsing that client's argv (`ps -Ao pid=,args= -ww`, accepting `--session <id>` / `-s <id>` / `--session=<id>` / `-s=<id>`, i.e. a client started with `opencode --session <id>`). Either way the binding is exact pid↔session — there is **no** directory-level fallback.
- **argv alone is only a launch-time snapshot — the plugin is what makes it live.** The v2 TUI can change which session it drives without touching its argv: `/clear`, `/new`, `/sessions` (aliases `/resume`, `/continue`), `ctrl+o`, `<leader>l`, `<leader>1..9` and session tabs all just `route.navigate` inside the process, so argv keeps naming the session the client was launched with. The plugin runs inside that same process and republishes the live route every 200ms, so these in-TUI switches update the binding in real time — in particular a `/clear` followed by a message (which creates a brand-new session B in the same directory) binds to B.
- A client with no session to report — empty live route, or no fresh binding and no argv id — is not bound at all, so it is dropped rather than misattributed to a stale launch id.

## The ocbar-bridge plugin

- Source `plugin/ocbar-bridge/tui.js`; `build.sh` installs it to `~/.config/opencode/plugins/ocbar-bridge/tui.js`. It runs inside the TUI client process, so `process.pid` there is the terminal client pid. Every 200ms it reads the live route (`ctx.ui.router.current()`) and atomically writes `{version, pid, sessionID, isRoot, directory, updatedAt}` to `~/.local/state/ocbar/bindings/<pid>.json` (temp file + rename, so ocbar never reads a half-written file); on teardown it deletes that file.
- ocbar's read priority per live client pid: a fresh binding file (<15s old) wins, and `sessionID: null` in it means the client is in no session (e.g. parked on the home page after `/clear`) and ocbar does **not** fall back to argv; only a pid with no fresh binding file falls back to argv parsing. A file is likewise ignored when its pid or `updatedAt` is missing, its `updatedAt` is stale, or its `isRoot` is explicitly `false`.
- Zero dependencies (only `node:fs`/`node:os`); `setup()` uses `setInterval` + a returned cleanup fn, since it runs outside a Solid owner.

## Shell helpers that pass an explicit id

- `~/dev/git/stuff/workspace.sh` holds `oc [args…]`, which mints a fresh random `ses_…` id and runs `opencode --session "$sid"`; `occ`, which runs `opencode --session <newest session id>` (falling back to `opencode --continue`); and `oct`, which creates `~/ocsession/<yyMMdd-HHmmss>-<rand>/`, `cd`s into it and launches a fresh random id there.
- Since the plugin binds by live route, the id these helpers pass is no longer needed for ocbar visibility — passing `--session <id>` still matters only when an id must be chosen *before* the session exists (pre-assigning an id for another consumer) or to jump straight to a specific existing id non-interactively. A bare `opencode` binds the same way once it enters a session, and the TUI's `/sessions` covers resuming interactively.
- These helpers are the maintainer's **personal** shell functions — nothing ships them, so keep them out of `README.md`, which should only ever say `opencode --session <id>`.

## Why the client side publishes

- OpenCode v2.1.0's **server** exposes **no** client↔session mapping (no client registry, no presence/attach endpoint; `/environment` and `/inbox` are empty; `session.viewed` is only an idle-ack watermark), so the pid↔session link has to come from the **client side** — the ocbar-bridge plugin above, with argv parsing kept only as the fallback for clients without it. The alternatives (accepting client-less busy sessions, or rebinding a pid by directory) were both tried and removed because they produce stale sibling rows.

## Dead code

- `OpenCodeClient.swift` is currently dead code — nothing references it; `SessionMonitor` inlines its own HTTP calls. Don't extend it expecting it to be wired in.

See also: [`context-usage.md`](context-usage.md), [`menubar-and-reminders.md`](menubar-and-reminders.md), [`island.md`](island.md), [`island-pill.md`](island-pill.md), [`island-alert.md`](island-alert.md), [`../AGENTS.md`](../AGENTS.md).