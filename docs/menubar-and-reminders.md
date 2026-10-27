# Menubar and reminders

This file documents the menubar label and the reminder chain that fires on busy → idle/waiting transitions.

## Reminders

- Busy → idle/waiting transitions drive notifications + the speech bubble. App targets OpenCode v2 only: all sessions share one `opencode serve --service` process, so no per-terminal `--port` is needed.
- The bubble is gated on `UserDefaults` key `ocbar.bubble` (default true, menu → "Show bubble"); `bounceIcon()` rides with it, since the bounce only exists to point at the bubble.
- With the bubble off the **island** carries those same two moments instead (`island.alert`), so the reminder is a chain — the bubble, else the island, else nothing beyond `SessionMonitor`'s own system notification — and not two independent switches.
- The alert sound (`ocbar.alertSound`, default `off`) belongs to neither surface: it rings whenever one of them is about to show something.

## Menubar label

- Which sessions appear at all is the monitoring rule — see [`session-monitoring.md`](session-monitoring.md). Each shown session is labeled by its project folder name only, never the session title.
- The menubar shows per-session labels up to a cap (default 4, configurable 0–10 via menu → "Projects shown", UserDefaults key `ocbar.projectsShown`).
- At 0 it drops project names entirely and renders one glyph + count per status instead (`aggregateTitle`), most urgent first, with the running mark still turning (the ring — see [`island-pill.md`](island-pill.md)).
- **Unless the island is on**, in which case the menubar drops to the plain `ocbar` name (`MenubarTitleShape.appName`) because the island already carries that detail; the VoiceOver summary keeps the counts on both paths (`aggregateSummary(statuses:)`).
- The shape is decided by the pure `menubarTitleShape(sessionCount:projectsShown:islandEnabled:)`, delimited by `<menubar-title-shape>` sentinel comments because an out-of-tree harness extracts exactly that block — don't delete the markers as stray comments.
- With no sessions the item stays the grey dot + "No OpenCode sessions" whatever the toggles say, since the island is ordered out when it has no rows.
- The exact rendering of the folded and aggregate labels (the `!1 · ●2 · ?1 · ✓1` walk-through and friends) lives in `README.md`; the invariant here is only that the aggregate orders by urgency and keeps the running mark turning. Do not restate the examples.

See also: [`session-monitoring.md`](session-monitoring.md), [`context-usage.md`](context-usage.md), [`island.md`](island.md), [`island-pill.md`](island-pill.md), [`island-alert.md`](island-alert.md), [`../AGENTS.md`](../AGENTS.md).