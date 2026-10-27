# Context-window usage

This file documents the optional per-session context-window readout: where its numbers come from, how it is presented, and which knobs change it.

## Gating and carriers

- Off by default; when on it shows on the dropdown's detail row and, when the island is on too, as the island row's third line.
- Filled by `SessionMonitor.fillContext` and carried as `SessionInfo.context` (`SessionContext{used, limit, fraction}`, `Models.swift`). Per-session refresh is throttled to 2s.
- Gated on `UserDefaults` keys `ocbar.contextUsage` (master, default false), `ocbar.contextUsageDisplay` (`percent`|`tokens`|`both`, default `both`), `ocbar.contextUsageWarn` (default 80) and `ocbar.contextUsageCritical` (default 95), all menu-driven in `contextUsageMenu()`.

## Where the numbers come from

- **Ceiling** — `GET /api/model` (`limit.input`/`limit.context`/`limit.output`, TTL-cached 300s), run through a copy of opencode's own `usable()` rule (`packages/opencode/src/session/overflow.ts`: `mx = min(output ?? 32000, 32000)`, `usable = input ? input - min(20000, mx) : context - mx`; 46/110 models have no `limit.input`).
- **Usage** — `GET /api/session/<id>/message?limit=10`, taking the first entry with `type == "assistant"` **and** a `tokens` object, because the list is newest-first and the in-flight turn carries no `tokens`.
- `used = input + output + cache.read + cache.write` — `reasoning` is deliberately excluded and `input` excludes cache, so the prompt is `input + cache.read + cache.write`.
- `Session.Info.tokens` in the session list is **cumulative** and must not be used for this.

## Presentation invariants

- The dropdown and the island cannot disagree: thresholds, wording, display mode and banding are resolved once in `Models.swift` (`ContextUsagePresentation`, `ContextBand`, `ContextDisplayMode`, `compactTokens`) and consumed by both `contextDetailItem` and `AppDelegate.islandContext`.
- A non-positive model `limit` must be treated as unknown rather than divided by (it once trapped on a divide by zero).
- The dropdown row is an indented, non-actionable item whose leading badge image is the session row's own glyph width (`contextDetailItem(for:)`), which is what aligns its text under the session name; `contextDetailExtraInset` is the tuning knob.

See also: [`session-monitoring.md`](session-monitoring.md), [`menubar-and-reminders.md`](menubar-and-reminders.md), [`island.md`](island.md), [`island-pill.md`](island-pill.md), [`island-alert.md`](island-alert.md), [`../AGENTS.md`](../AGENTS.md).