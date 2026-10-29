// ocbar TUI bridge plugin — publishes this client's (pid, session) binding so the
// ocbar menubar app can map a running TUI client to the session it is actually
// driving. A TUI plugin runs inside the client process, so process.pid here is the
// terminal client pid; ocbar reads ~/.local/state/ocbar/bindings/<pid>.json.
//
// Zero dependencies on purpose: only node:fs / node:path / node:os. setup() runs
// outside a Solid owner, so we use setInterval + a cleanup fn instead of signals.
import { mkdirSync, writeFileSync, renameSync, rmSync } from "node:fs";
import { homedir } from "node:os";

const PID = process.pid;
const DIR = `${homedir()}/.local/state/ocbar/bindings`;
const FILE = `${DIR}/${PID}.json`;
const TMP = `${FILE}.tmp`;

// The pane this client runs in, read from the environment tmux gave it: `TMUX_PANE` is the pane
// id, and the first comma-separated field of `TMUX` is the server's socket. Published so ocbar can
// switch to this pane without asking tmux which pane a tty belongs to — two `tmux` spawns, ~110ms
// each, on the click path. Both are null outside tmux (a plain terminal has no pane to switch to).
const TMUX_PANE = process.env.TMUX_PANE ?? null;
const TMUX_SOCKET = (process.env.TMUX ?? "").split(",")[0] || null;

function sessionIdOf(route) {
  if (!route || typeof route !== "object") return null;
  return route.type === "session" && typeof route.sessionID === "string"
    ? route.sessionID
    : null;
}

export default {
  id: "ocbar.bridge",
  setup(ctx) {
    try {
      mkdirSync(DIR, { recursive: true });
    } catch {}

    const tick = () => {
      let route = null;
      try {
        route = ctx.ui?.router?.current?.() ?? null;
      } catch {}

      const sessionID = sessionIdOf(route);

      let isRoot = null;
      if (sessionID) {
        try {
          isRoot = ctx.data.session.root(sessionID) === sessionID;
        } catch {}
      }

      const rec = {
        version: 1,
        pid: PID,
        sessionID,
        isRoot,
        tmuxPane: TMUX_PANE,
        tmuxSocket: TMUX_SOCKET,
        directory: ctx.location?.directory ?? null,
        updatedAt: Date.now(),
      };

      // Atomic write: temp file + rename so ocbar never reads a half-written file.
      try {
        writeFileSync(TMP, JSON.stringify(rec));
        renameSync(TMP, FILE);
      } catch {}
    };

    tick();
    const timer = setInterval(tick, 200);

    return () => {
      clearInterval(timer);
      try {
        rmSync(FILE);
      } catch {}
    };
  },
};