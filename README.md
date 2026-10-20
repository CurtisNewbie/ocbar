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

**Click** the icon to see each session by project name and status. Menu → "Show session time" adds each session's time since its last activity. Menu → "Show session titles" chooses whether menu rows that share a folder are told apart by the session title or by a short id suffix. The same toggle controls whether the bubble's subtitle line shows the session title (falling back to the status word). The menubar itself never shows session titles.

**Notification** fires when any session transitions from busy → idle.

**Bubble** — when a session transitions busy → idle or → waiting, a speech-bubble pops up below the menubar icon with a tail pointing at it: the title line shows the project folder name and the subtitle line shows the session title when "Show session titles" is on and the session has a title, otherwise it shows the status word ("Ready" with a green checkmark or "Needs input" with a blue question mark). It pops in, holds 10 seconds, then fades out. Click the bubble to focus that session's tmux pane and dismiss it; click the small × at its top-right to dismiss without focusing. The menubar icon bounces at the same time to draw the eye. On additional screens (no visible icon there), the bubble position is configurable via menu → "Bubble position": top center, top left, top right, bottom left, or bottom right.

## How it works

- Reads `~/.local/state/opencode/service.json` (url, pid, version, password) to locate the shared OpenCode v2 service
- Authenticates with HTTP Basic auth (username `opencode`, password from that file)
- Every 2s: `GET /api/info` to check the service is up
- Every 0.5s: `GET /api/session/active` for busy sessions and `GET /api/session?limit=100&order=desc` for the session list and project directory
- `GET /api/form` and `GET /api/permission/request`, scoped by `location[directory]=<dir>`, for pending user input. Only directories with active or recently active sessions are checked
- A session is shown only while a live `opencode` client (TUI or CLI) is attached in its directory — client-less orphaned sessions are ignored
- Only root sessions (top-level sessions you interact with, not subagent children) are shown, labeled by project folder name. The menubar shows folder names only, so duplicate folders render identically; in the dropdown menu, several roots can share a directory, each shown as its own row, and rows that share a folder are told apart by the session title (or a short id suffix when titles are off or the session has no title)
- When a client is started with an explicit session id (`opencode --session <id>`, as the `oc` / `oct` / `occ` shell helpers do), ocbar reads that id from the client's command line (`ps` argv) and binds the row to the exact client pid; clients started without one fall back to the first attached client in the directory
- A session is listed while its own or a descendant's work is busy/waiting. Once a client has viewed it, it stays listed until 15 minutes after the later of its last view and its last activity. Unviewed sessions (for example a headless `opencode run`) are therefore only listed while they are busy or waiting

## Limitations

- **Precise per-session binding needs an explicit session id.** OpenCode v2's HTTP API exposes no client identity — a session carries no pid, and its events carry only a session id and directory. So ocbar recovers the pid↔session mapping from the client process's command line (`ps` argv, looking for `--session <id>`). Start clients with an explicit id (for example the `oc` / `oct` / `occ` shell helpers) to get exact binding; a bare `opencode` or `opencode run` exposes no id, so ocbar falls back to the first attached client in that directory — and if two such sessions share a directory, it cannot tell which terminal hosts which row.
- **A `--session` client appears only after its first message.** OpenCode creates the session lazily, so a terminal that is open but idle is not listed until you send a prompt.
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
