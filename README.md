# ocbar

macOS menubar app that monitors [OpenCode](https://opencode.ai) sessions across all your terminals.

> **OpenCode v2 required.** ocbar targets OpenCode v2 only. v1 is no longer supported — v1 users should use git tag `oc_v1` (`git checkout oc_v1`), the last v1-compatible version.

## What it does

Shows a live status indicator in your menubar so you know when agents finish without watching the terminal.

**Menubar label:** For one through the configured maximum of 1–10 sessions (default 4), each session shows its colored status icon followed by its project folder name only — never the session title. Sessions that share a folder name render identically (no disambiguation suffix). For zero or sessions above the configured maximum, the existing aggregate label is used, such as `● 2 busy · 1 idle`.

**Icon color:**
- Orange — all sessions busy (agent working)
- Green — at least one session idle (agent finished, needs your attention)
- Red — at least one session errored
- Gray — no OpenCode running

**Click** the icon to see each session by project name and status. Menu → "Show session time" adds each session's age (time since it was created). Menu → "Show session titles" chooses whether menu rows that share a folder are told apart by the session title or by a short id suffix. The same toggle controls whether the bubble's subtitle line shows the session title (falling back to the status word). The menubar itself never shows session titles.

**Context usage (off by default).** Menu → "Context usage" → "Show context usage" adds an indented second line under each session with how full its context window is, for example `57.6k / 968k tokens · 6%`. The numbers come from that session's most recent completed assistant turn, measured against the ceiling OpenCode itself uses to decide when to compact, so the percentage is the same one that drives compaction. "Display" picks the format (percent, tokens used, or both), and "Warn at" / "Critical at" set the thresholds where the percentage turns orange or red and gains a warning glyph. Nothing is fetched while the feature is off.

**Notification** fires when any session transitions from busy → idle.

**Bubble** — when a session transitions busy → idle or → waiting, a speech-bubble pops up below the menubar icon with a tail pointing at it: the title line shows the project folder name and the subtitle line shows the session title when "Show session titles" is on and the session has a title, otherwise it shows the status word ("Ready" with a green checkmark or "Needs input" with a blue question mark). It pops in, holds 10 seconds, then fades out. Click the bubble to focus that session's tmux pane and dismiss it; click the small × at its top-right to dismiss without focusing. The menubar icon bounces at the same time to draw the eye. On additional screens (no visible icon there), the bubble position is configurable via menu → "Bubble position": top center, top left, top right, bottom left, or bottom right. Menu → "Alert sound" picks an optional sound to play alongside the bubble — Off by default, or "System alert" (your configured alert sound) or one of the macOS system sounds.

**Island (on by default).** A CodeIsland-style status surface at the very top of a notched display: a black capsule sitting in the notch area, showing **one small dot per session** — the dot's colour is that session's state, so the strip tells you at a glance how many sessions there are and what each is doing, with no legend needed. The dots sit in the two slivers of capsule that flank the physical notch (nothing can be drawn in the cutout itself); up to four fit, and more than four shows three dots and an ellipsis instead. Hover it (or click it) and it grows into a rounded card listing every session — status glyph, project name and age — and clicking a row focuses that session's tmux pane, exactly like a menu row. It collapses when the pointer leaves, and whenever the menu opens. Menu → "Show island" turns it off. On a display without a notch it falls back to a compact centred capsule, and it is only ever shown on the screen that has the notch (falling back to the main display). The island is additive: the menubar icon and the bubble keep working exactly as before.

## How it works

- Reads `~/.local/state/opencode/service.json` (url, pid, version, password) to locate the shared OpenCode v2 service
- Authenticates with HTTP Basic auth (username `opencode`, password from that file)
- Every 2s: `GET /api/info` to check the service is up
- Every 0.5s: `GET /api/session/active` for busy sessions and `GET /api/session?limit=100&order=desc` for the session list and project directory
- When context usage is on: `GET /api/model` (cached 5 minutes) for each model's context ceiling, and `GET /api/session/<id>/message?limit=10` for the newest completed turn's token counts, refreshed at most once every 2s per session
- `GET /api/form` and `GET /api/permission/request`, scoped by `location[directory]=<dir>`, for pending user input. Only directories with active or recently active sessions are checked
- A session is shown only while its exact id is bound to a live `opencode` client (TUI or CLI) — client-less orphaned sessions are ignored
- Only root sessions (top-level sessions you interact with, not subagent children) are shown, labeled by project folder name. The menubar shows folder names only, so duplicate folders render identically; in the dropdown menu, several roots can share a directory, each shown as its own row, and rows that share a folder are told apart by the session title (or a short id suffix when titles are off or the session has no title)
- Binding comes from the `ocbar-bridge` TUI plugin, which runs inside each OpenCode client and reports, live, the session that client is actually driving (pid ↔ session); ocbar prefers that report. Parsing the client's command line (`opencode --session <id>`, via `ps` argv) is only a fallback for clients without the plugin. Either way there is no directory-level fallback: a client that is in no session, or carries no id and has no plugin report, is simply not bound (see Limitations)
- A session is listed while its own or a descendant's work is busy/waiting. Once a client has viewed it, it stays listed until 15 minutes after the later of its last view and its last activity. Unviewed sessions (for example a headless `opencode run`) are therefore only listed while they are busy or waiting

## Limitations

- **Precise per-session binding comes from the `ocbar-bridge` TUI plugin.** OpenCode v2's HTTP API exposes no client identity — a session carries no pid, and its events carry only a session id and directory — so the pid↔session mapping has to come from the client side. The bridge plugin (`plugin/ocbar-bridge/tui.js`, which `build.sh` installs to `~/.config/opencode/plugins/ocbar-bridge/tui.js`) runs inside each OpenCode 2.x TUI client and reports the session it is currently driving, live. ocbar prefers that report, and only falls back to parsing the client's command line (`ps` argv, looking for `--session <id>`) when the plugin is absent — so a client started with an explicit id still gets exact binding. A bare `opencode` or `opencode run` that is in no session is never shown at all.
- **Switching sessions inside a TUI is tracked live by the bridge plugin.** `/clear`, `/new`, `/sessions`, `ctrl+o`, `<leader>l`, `<leader>1..9` and session tabs change which session the process drives without changing its argv; with the `ocbar-bridge` plugin installed (`build.sh` does this), ocbar follows the session actually being driven, so the terminal re-binds as you switch — including the brand-new session created by sending a message after `/clear`. Without the plugin, ocbar falls back to the argv snapshot and the old symptom returns: it keeps binding that terminal to the session it was launched with and silently drops the one actually running, so relaunch with an explicit `opencode --session <id>` to re-bind.
- **A client appears only after its first message.** OpenCode creates the session lazily, so a terminal that is open but idle is not listed until you send a prompt.
- **Bubbles and notifications are keyed by project.** One popup per project directory, even when several sessions in it change state.

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- [OpenCode](https://opencode.ai) v2 installed

## Build & run

**1. Install Xcode Command Line Tools** (if not already installed):

```bash
xcode-select --install
```

**2. Clone and build:**

```bash
git clone https://github.com/CurtisNewbie/ocbar.git
cd ocbar
./build.sh
```

This compiles the Swift sources and produces `ocbar/ocbar.app`.

**3. Run:**

```bash
open ocbar/ocbar.app
```

The app runs as a menubar-only app (no Dock icon). You'll see the status indicator appear in your menubar immediately.

**To find it with Spotlight (⌘+Space), copy it to your Applications folder:**

```bash
cp -R ocbar/ocbar.app /Applications/
```

(Or `~/Applications/` for a per-user install.) Note: rebuilding with `./build.sh` overwrites only the project copy — recopy to `/Applications` after each rebuild. If Spotlight doesn't show it right away, run `mdimport /Applications/ocbar.app`.

**4. Allow notifications** when macOS prompts — required for idle alerts.

**To rebuild after code changes:**

```bash
./build.sh && open ocbar/ocbar.app
```

> Note: If macOS blocks the app ("unidentified developer"), go to **System Settings → Privacy & Security** and click **Open Anyway**.
