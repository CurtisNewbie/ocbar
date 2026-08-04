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

- Every 10s: scans `ps aux` for `opencode --port <N>` processes
- Every 200ms: polls `GET /session/status` on each discovered port
- No workflow change needed — works with your normal `opencode` terminal sessions

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- [OpenCode](https://opencode.ai) installed

## Build & run

```bash
cd ocbar
./build.sh
open ocbar.app
```
