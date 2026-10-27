# ocbar

macOS menubar app that monitors [OpenCode](https://opencode.ai) sessions across all your terminals.

> **OpenCode v2 required.** ocbar targets OpenCode v2 only. v1 is no longer supported — v1 users should use git tag `oc_v1` (`git checkout oc_v1`), the last v1-compatible version.

## What it does

Shows a live status indicator in your menubar so you know when agents finish without watching the terminal.

**Menubar label:** Up to the configured maximum (menu → "Projects shown", 0–10 sessions, default 4), each session shows its colored status icon followed by its project folder name only — never the session title. Sessions that share a folder name render identically (no disambiguation suffix). Above that maximum the active sessions are still named and the finished ones fold into a single `✓ n idle`. Choosing "0 (none)" drops project names altogether: the label becomes one glyph plus a count per state, most urgent first — for one errored, two running, one waiting and one finished session that is `!1 · ●2 · ?1 · ✓1`. With "Show island" also on, that duplicate is dropped and the label is just `ocbar` instead, since the island already carries the same counts.

**Icon color:**
- Orange — all sessions busy (agent working)
- Green — at least one session idle (agent finished, needs your attention)
- Red — at least one session errored
- Gray — no OpenCode running

**Click** the icon to see each session by project name and status. Menu → "Show session time" adds each session's age (time since it was created). On the island card the same toggle also adds, right beside that age, how long ago the session was last updated — `5h36m · 2m`, `now` in the first minute, and nothing at all for a session nobody has touched since it started. Menu → "Show session titles" chooses whether menu rows that share a folder are told apart by the session title or by a short id suffix. The same toggle controls whether the bubble's subtitle line shows the session title (falling back to the status word). The menubar itself never shows session titles.

**Context usage (off by default).** Menu → "Context usage" → "Show context usage" adds an indented second line under each session with how full its context window is, for example `57.6k / 968k tokens · 6%`. The numbers come from that session's most recent completed assistant turn, measured against the ceiling OpenCode itself uses to decide when to compact, so the percentage is the same one that drives compaction. "Display" picks the format (percent, tokens used, or both), and "Warn at" / "Critical at" set the thresholds where the percentage turns orange or red and gains a warning glyph. The island card shows the same readout on a second line under each session, so the two surfaces can never disagree. Nothing is fetched while the feature is off.

**Notification** fires when any session transitions from busy → idle or from any state → waiting.

**Bubble** — when a session transitions busy → idle or → waiting, a speech-bubble pops up below the menubar icon with a tail pointing at it: the title line shows the project folder name and the subtitle line shows the session title when "Show session titles" is on and the session has a title, otherwise it shows the status word ("Ready" with a green checkmark or "Needs input" with a blue question mark). It pops in, holds 10 seconds, then fades out. Click the bubble to focus that session's tmux pane and dismiss it; click the small × at its top-right to dismiss without focusing. The menubar icon bounces at the same time to draw the eye. Menu → "Show bubble" toggles the whole thing (on by default); turning it off also stops the icon bounce, and the island takes over the reminder instead (see "Island alerts" below). On additional screens (no visible icon there), the bubble position is configurable via menu → "Bubble position": top center, top left, top right, bottom left, or bottom right. Menu → "Alert sound" picks an optional sound — Off by default, or "System alert" (your configured alert sound) or one of the macOS system sounds. It belongs to neither surface, so it plays alongside whichever reminder is showing.

**Island (on by default).** A status surface at the very top of **every** display: on a notched screen a black capsule sitting in the notch area, on a screen without a cutout a matching capsule centred against the top edge. Its two visible slivers (the cutout itself has no pixels) each answer one question. Left: a small ring — orange and turning while any session is working, dim grey and still when none is — with the running count right beside it: the number alone, since the ring is that side's icon (`3`). The ring is always there, so that side of the pill is never blank, and it answers "is work happening right now" without a number; with Reduce Motion on it holds still in both states and the colour alone says which one it is. Right: one icon-and-count badge per remaining state that has sessions, most urgent first — red `!` errored, blue `?` waiting on you, green `✓` finished — so three running with two waiting and one finished reads `3` on the left and `? 2 ✓ 1` on the right. Every state has its own slot, so nothing is ever left out or rolled into a number that would misreport it. The running count appears beside the ring and nowhere else, deliberately: the ring says something is happening now, the number beside it says how many. The ring stops when nothing is running — and so does its animation timer, so a quiet pill costs nothing — and under Reduce Motion it stays still instead of turning. Hover it (or click it) and it grows into a wide dark card listing every session on three lines — project name with the age and, right beside it, how long ago the session was last updated, the session's own title, and the context readout when "Context usage" is on — and clicking a row focuses that session's tmux pane, exactly like a menu row. A list too long for the screen folds its tail into a single `+n more` line instead of running off the bottom. Each display's island expands on its own. It collapses when the pointer leaves, and whenever the menu opens. Menu → "Show island" turns them off. The island is additive: the menubar icon and the bubble keep working exactly as before.

**Island alerts.** With "Show bubble" off, the island becomes the reminder: on the same two transitions it opens its card by itself on every display, marks the row that just changed, and folds after the same 10 seconds the bubble would have stayed up. Clicking a row focuses that session and puts every display's card away; the **Hide** button on the card dismisses the alert without jumping anywhere. The card also puts itself away when the reason for it is gone — answer the question it was about and it closes — and whenever you open the menu.

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
- A session is listed while its own or a descendant's work is busy/waiting. Once a client has viewed it, it stays listed until 12 hours after the later of its last view and its last activity. Unviewed sessions (for example a headless `opencode run`) are therefore only listed while they are busy or waiting

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

`build.sh` compiles the Swift sources, bundles `ocbar/ocbar.app`, installs the `ocbar-bridge` TUI plugin, then installs the app to `~/Applications/ocbar.app` and opens it, quitting any running copy first. It is the only build path — Xcode is not used, and `build.sh` carries an explicit list of the sources it compiles.

The app is menubar-only (no Dock icon) and the status indicator appears immediately.

**3. Allow notifications** when macOS prompts — required for idle alerts.

**To rebuild after code changes:** run `./build.sh` again. It replaces the installed copy and relaunches the app.

Spotlight indexes `~/Applications`, so there is nothing to copy. If the app doesn't show up there, run `mdimport ~/Applications/ocbar.app`.

> Note: If macOS blocks the app ("unidentified developer"), go to **System Settings → Privacy & Security** and click **Open Anyway**.
