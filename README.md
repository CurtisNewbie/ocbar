# ocbar

macOS menubar app that monitors [OpenCode](https://opencode.ai) sessions across all your terminals.

> **OpenCode v2 required.** ocbar targets OpenCode v2 only. v1 is no longer supported — v1 users should use git tag `oc_v1` (`git checkout oc_v1`), the last v1-compatible version.

## What it does

Shows a live status indicator in your menubar so you know when agents finish without watching the terminal.

**Menubar label:** For one through the configured maximum of 1–10 sessions (default 4), each session shows its colored status icon followed by its project/session name. For zero or sessions above the configured maximum, the existing aggregate label is used, such as `● 2 busy · 1 idle`.

**Icon color:**
- Orange — all sessions busy (agent working)
- Green — at least one session idle (agent finished, needs your attention)
- Red — at least one session errored
- Gray — no OpenCode running

**Click** the icon to see each session by project name and status.

**Notification** fires when any session transitions from busy → idle.

**Bubble** — when a session transitions busy → idle or → waiting, a speech-bubble pops up below the menubar icon with a tail pointing at it: "`project` ready" (green checkmark) or "`project` needs input" (blue question mark). It pops in, holds 10 seconds, then fades out. The menubar icon bounces at the same time to draw the eye. On additional screens (no visible icon there), the bubble position is configurable via menu → "Bubble position": top center, top left, top right, bottom left, or bottom right.

## How it works

- Reads `~/.local/state/opencode/service.json` (url, pid, version, password) to locate the shared OpenCode v2 service
- Authenticates with HTTP Basic auth (username `opencode`, password from that file)
- Every 2s: `GET /api/info` to check the service is up
- Every 0.5s: `GET /api/session/active` for busy sessions and `GET /api/session?limit=100&order=desc` for the session list and project directory
- `GET /api/form` and `GET /api/permission/request`, scoped by `location[directory]=<dir>`, for pending user input. Only directories with active or recently active sessions are checked
- A session is shown only while a live `opencode` client (TUI or CLI) is attached in its directory — client-less orphaned sessions are ignored
- Only root sessions (top-level sessions you interact with, not subagent children) that are active/waiting or updated within the last 30 minutes are shown, labeled by project folder name

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
cd ocbar/ocbar
./build.sh
```

This compiles the Swift sources and produces `ocbar.app` in the same directory.

**3. Run:**

```bash
open ocbar.app
```

The app runs as a menubar-only app (no Dock icon). You'll see the status indicator appear in your menubar immediately.

**To find it with Spotlight (⌘+Space), copy it to your Applications folder:**

```bash
cp -R ocbar.app /Applications/
```

(Or `~/Applications/` for a per-user install.) Note: rebuilding with `./build.sh` overwrites only the project copy — recopy to `/Applications` after each rebuild. If Spotlight doesn't show it right away, run `mdimport /Applications/ocbar.app`.

**4. Allow notifications** when macOS prompts — required for idle alerts.

**To rebuild after code changes:**

```bash
./build.sh && open ocbar.app
```

> Note: If macOS blocks the app ("unidentified developer"), go to **System Settings → Privacy & Security** and click **Open Anyway**.
