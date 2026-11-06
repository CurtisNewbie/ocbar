# Menubar and reminders

This file documents the menubar label and the reminder chain that fires on busy → idle/waiting transitions.

## Reminders

- Busy → idle/waiting transitions drive notifications + the speech bubble. App targets OpenCode v2 only: all sessions share one `opencode serve --service` process, so no per-terminal `--port` is needed.
- The bubble is gated on `UserDefaults` key `ocbar.bubble` (default true, menu → "Show bubble"); `bounceIcon()` rides with it, since the bounce only exists to point at the bubble.
- With the bubble off the **island** carries those same two moments instead (`island.alert`), so the reminder is a chain — the bubble, else the island, else nothing beyond `SessionMonitor`'s own system notification — and not two independent switches.
- The alert sound (`ocbar.alertSound`, default `off`) belongs to neither surface: it rings whenever one of them is about to show something.
- **With the menubar item hidden (the island is on) the bubble has no icon to hang from.** `showBubble` passes `statusItem.isVisible ? statusItem.button : nil` — the app states which case it is rather than asking a hidden item's button for a window — so `StatusBubble` gets no anchor and falls back to the configured positions on **every** screen: default `topCenter`, directly under the island, which is where the reminder belongs now. `bounceIcon()` no-ops in the same state: the bounce exists only to point at the bubble anchored to the icon, and there is no icon.

## Menubar label

**The item exists only while the island is off.** `AppDelegate.render` sets `statusItem.isVisible = !islandEnabled` on every path that can change the toggle — launch, the menu's own "Show island", and each poll tick — so an ocbar with the island on has no menubar icon at all: no title to draw, nothing to bounce. The island is then the app's only surface, and the dropdown lives behind the expanded card's footer gear (next section). The rule is **strict on the toggle and deliberately not conditional on there being sessions**: the island stays up with zero sessions for exactly this reason, so an empty ocbar still has a way into its own menu ([`island.md`](island.md)). `updateButton` therefore returns early while the item is hidden — but `updateRunningMark`/`refreshBusyMarks` keep running, because they also repaint the dropdown rows' running marks and the dropdown is now opened from the island.

- Which sessions appear at all is the monitoring rule — see [`session-monitoring.md`](session-monitoring.md). Each shown session is labeled by its project folder name only, never the session title.
- The menubar shows per-session labels up to a cap (default 4, configurable 0–10 via menu → "Projects shown", UserDefaults key `ocbar.projectsShown`).
- At 0 it drops project names entirely and renders one glyph + count per status instead (`aggregateTitle`), most urgent first, with the running mark still turning (the ring — see [`island-pill.md`](island-pill.md)).
- `MenubarTitleShape.appName` — the plain "ocbar" label this file used to describe for "project names off, island on" — is **never drawn now**: an island-on ocbar has no item to draw it in. It survives in the pure `menubarTitleShape(sessionCount:projectsShown:islandEnabled:)` only because the out-of-tree harness asserts that block (below); deleting the case fails the harness. Nothing in the app renders it, and `updateButton`'s early return means the branch is unreachable rather than merely unused.
- The shape is decided by the pure `menubarTitleShape(sessionCount:projectsShown:islandEnabled:)`, delimited by `<menubar-title-shape>` sentinel comments because an out-of-tree harness extracts exactly that block — don't delete the markers as stray comments.
- With no sessions and the island **off** — the only state in which the item exists — it is the grey dot + "No OpenCode sessions" whatever the other toggles say. With the island on there is no such state to render: the island says those same three words in its card instead.
- The exact rendering of the folded and aggregate labels (the `!1 · ●2 · ?1 · ✓1` walk-through and friends) lives in `README.md`; the invariant here is only that the aggregate orders by urgency and keeps the running mark turning. Do not restate the examples.

## The dropdown, from the island

The island's expanded card carries a **gear at its trailing edge on every card** — hover, alert, and the empty one — because while the menubar is hidden it is the only way into the menu. `IslandHost.onSettingsRequested` is a pure pass-through (`IslandPanel.onSettingsRequested`), and `AppDelegate.showMenuFromIsland` drops the **same `menu` object** the status item would have opened, at `NSEvent.mouseLocation` in screen coordinates (`popUp(positioning:at:in: nil)`): the pointer is on the gear when it fires, so nothing is re-anchored to a view. `NSMenuDelegate.menuWillOpen` does the rest exactly as it always has — collapse every island, stop the bubble's pulse, force a menu refresh — so the gear handler itself folds nothing, and the panel's hover latch is what keeps the card from re-opening under the pointer after the menu closes. Opening the menu is therefore **also an exit from an alert** (`menuWillOpen` → `collapse()`), which is why the gear's `hitTest` claim sits *before* the card's refusal to toggle while an alert is armed: settings are not an answer to the alert, but reaching the menu still ends it.

**No `NSApp.activate(ignoringOtherApps:)`.** The app is `.accessory` and the island panel is deliberately non-activating; never pulling focus away from the terminal is a standing invariant of this app. A pop-up menu started from a mouse-down in our own window tracks without activation — that is the deliberate choice, not an oversight, if a later report says the menu "doesn't highlight".

See also: [`session-monitoring.md`](session-monitoring.md), [`context-usage.md`](context-usage.md), [`island.md`](island.md), [`island-pill.md`](island-pill.md), [`island-alert.md`](island-alert.md), [`../AGENTS.md`](../AGENTS.md).
