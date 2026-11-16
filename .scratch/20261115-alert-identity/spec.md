# Spec: retract the alert of the session that moved

## Problem Statement

The island's unprompted alert is retracted by folder display name. Every dismissal the monitor publishes
carries a project directory, `AppDelegate` turns it into a display name, and `IslandHost.retractAlert`
matches the armed alert on that name. Two sessions in one directory therefore share a key: when session A
answers its prompt or goes back to work, the alert that session B armed is cleared, its row mark goes with
it, and a card the user was still reading folds as a card nobody owns. The app already allows several
sessions per directory, so the name is not an identity.

## Solution

An armed alert carries the id of the session it is about, and a dismissal carries that id too. The
monitor knows the session at every point it publishes a dismissal or a transition, so the id is threaded
from there: `onDismiss` and `onTransition` publish a `SessionReminder` holding the session id and the
project directory, `showBubble` hands the id to the island's alert, and `retractAlert` matches
`ActiveAlert.sessionID`. The folder display name stays the bubble's title and dismissal key. The bubble,
the menubar and the system notification keep the behaviour they have.

## Implementation Decisions

- **The identity is the session id, not the client pid.** An unbound session has no client pid, so two
  unbound sessions would match each other on `nil`. The session id exists for every session and is the
  identity the rows are already built from.
- **The reminder decision becomes a pure function.** `SessionMonitor.publish` interleaves previous-state
  lookup, notifications and callbacks. `reminderEvents(previousStatus:previousDir:sessions:)` moves the
  decision into `Models.swift` and returns the dismissals and transitions in the order they fire today,
  each carrying its session's reminder. `publish` dispatches the events (notification first, callback
  second, as now) and then stores the new state. The seam needs no AppKit, so the harness can pin it.
- **One value carries the identity.** A bare `(String, String)` callback loses its labels at every closure
  site, so two directory strings could be swapped without a compile error. `SessionReminder` names both
  fields once and the callbacks carry it.
- **One key per surface.** The island alert matches on the session id. The bubble keeps the folder display
  name as its title and its `dismiss(ifShowing:)` key, which is out of scope here.
- **A dismissal with no matching alert stays a no-op**, exactly as today.

## Contracts

### Data

```swift
struct SessionReminder: Equatable {
    let sessionID: String
    let projectDir: String
}

enum ReminderEvent: Equatable {
    case dismiss(SessionReminder)
    case transition(kind: SessionStatus, reminder: SessionReminder, pid: Int32?, title: String?)
}
```

### Interfaces

- `SessionMonitor.onDismiss: ((SessionReminder) -> Void)?`
- `SessionMonitor.onTransition: ((SessionStatus, SessionReminder, Int32?, String?) -> Void)?`
- `func reminderEvents(previousStatus: [String: SessionStatus], previousDir: [String: String],
  sessions: [SessionInfo]) -> [ReminderEvent]` in `Models.swift`, pure.
- `AppDelegate.showBubble(status:reminder:pid:title:)`, which hands `reminder` to both surfaces: the
  bubble titles and dismisses by `displayName(for: reminder.projectDir)`, the island arms with
  `reminder.sessionID`.
- `AppDelegate.dismissReminders(_ reminder: SessionReminder)`.
- `IslandHost.alert(sessionID:kind:pid:seconds:)` and `IslandHost.dismissAlert(sessionID:)`; the panel's
  `ActiveAlert` holds `sessionID`, `kind`, `pid`.

### Order

The events keep today's order: the sessions that vanished from the list first, then each visible session
in the order the monitor passes them, and within a session the dismissal before its transition. A session
that keeps waiting publishes nothing.

## Invariants

- A dismissal retracts only the alert armed by the session it names. Two sessions in one directory are
  independent reminders.
- The alert's row mark and its scope follow the alert's own session, not the directory.
- The bubble is dismissed by the same display name it was shown with.
- The session id a dismissal carries is the id of the session that published it, whether it left the list
  or stopped waiting.

## States and failure

| Situation | Published |
|---|---|
| A listed session disappears from the list | `dismiss(session of the disappeared id)` |
| A session goes from waiting to any other status | `dismiss(that session)` |
| A session goes from idle to busy | `dismiss(that session)` |
| A session enters waiting from another status | `transition(.waiting, that session)` |
| A session goes from busy to idle | `transition(.idle, that session)` |
| Anything else (no status change, waiting to busy) | nothing |

A dismissal whose session armed no alert is dropped by the island. A dismissal that arrives after the
alert's timer already ended it is the same no-op.

## Acceptance Criteria

- [ ] With two sessions in one directory, a dismissal published for A retracts only an alert armed for A;
  B's alert, mark and scope survive.
- [x] `reminderEvents` names the publishing session on both dismissal forms and both transitions, in
  today's order.
- [x] `./test.sh` fails against the old identity (the project directory standing in for the session id)
  and passes against the new one.
- [x] The bubble still shows and dismisses by folder display name.
- [ ] `./build.sh` succeeds, and a manual pass with two terminals in one directory shows B's mark
  surviving A's answer.

## Testing Decisions

- The harness stays framework-free: `./test.sh` compiles `Models.swift` plus one runner under `tests/`,
  and exits non-zero on a failed check. The runner gains a reminders suite beside the question-queue suite.
- The pure seam is `reminderEvents`. The panel's one equality and `AppDelegate`'s wiring are not compiled
  by the harness; the shortcut comment in `test.sh` names them and where a future seam extension goes.
- Manual verification is the two-terminal pass in the acceptance criteria, plus the existing alert
  behaviours: its timer, its `Hide`, a row click, and the menubar opening all still end it.

## Required Skills

`tdd` and `code-review`, per `AGENTS.md` and this repo's review rules.

## Out of Scope

- The speech bubble's identity: it remains one bubble keyed by folder display name.
- The menubar dropdown's rows, the system notification, and the question card.
- Changing when an alert is armed, how long it stays, or what it marks.