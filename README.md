# ocbar

macOS menubar app that monitors [OpenCode](https://opencode.ai) sessions across all your terminals.

## What it does

Shows a live status indicator in your menubar so you know when agents finish without watching the terminal.

**Menubar label:** `● 2 busy · 1 idle`

**Icon color:**
- Orange — all sessions busy (agent working)
- Green — at least one session idle (agent finished, needs your attention)
- Red — at least one session errored
- Gray — no OpenCode running

**Click** the icon to see each session by project name and status.

**Notification** fires when any session transitions from busy → idle.

## How it works

- Every 1s: scans `ps aux` for `opencode` processes; port from `--port` flag, else discovered via `lsof` listening sockets
- Every 200ms: polls `GET /session/status` on each discovered port

> **Limitation:** sessions must be started with `--port` — bare `opencode` starts no HTTP server, so it cannot be monitored. `opencode --port 0` works (auto-selects a port).

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- [OpenCode](https://opencode.ai) installed

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

**4. Allow notifications** when macOS prompts — required for idle alerts.

**To rebuild after code changes:**

```bash
./build.sh && open ocbar.app
```

> Note: If macOS blocks the app ("unidentified developer"), go to **System Settings → Privacy & Security** and click **Open Anyway**.
