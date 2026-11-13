# Spec: answer questions from the expanded island

## Problem Statement

A session blocked on a question is the one state ocbar can only point at. The island already knows the
session is waiting — the blue question mark, the "Question pending" notification, the waiting rank —
but answering means finding the terminal, reading the question there, and typing an answer. With
several terminals open, locating the right pane is the slow part, and the surface that told the user
about the question cannot act on it.

## Solution

The expanded card becomes answerable. When a session is blocked on a question form, the island opens
itself on every screen showing that session's row with the question beneath it, and every other
session folds into the `+k more` tail. The user picks options, or types an answer where the question
allows one, steps left and right between the form's fields, and presses Send; the reply goes straight
to the OpenCode server. A pending question outranks every other island state, further forms queue
oldest first, and the card folds once the last one settles.

## User Stories

1. As someone running several sessions, I want a pending question to open the island on its own, so
   that I do not have to notice it in a terminal I am not watching.
2. As someone answering a question, I want the question rendered in the card with its options, so
   that I can answer without switching to the terminal.
3. As someone answering a question, I want the waiting session's row above the question, so that I
   know which session is asking before I answer.
4. As someone answering a question, I want every other session folded into the `+k more` tail, so
   that the card is about the one thing that needs me.
5. As someone answering a question with several fields, I want to step left and right between fields
   with a counter, so that I can see how much is left.
6. As someone with more than one question pending, I want the oldest shown first with a position
   counter, and the next one taking its place after Send, so that nothing is silently queued behind
   one form.
7. As someone picking an option, I want a visible selection plus an explicit Send, so that a misclick
   cannot answer for me.
8. As someone answering a required question, I want Send held back until every required field has an
   answer, so that my click cannot bounce off the server.
9. As someone whose question allows a free-text answer, I want an "Other…" row that lets me type one,
   so that I am not limited to the canned options.
10. As someone reading options, I want each option's explanatory line under its label, so that two
    similar choices are distinguishable without going back to the terminal.
11. As someone answering a question with many options, I want the options to scroll inside the card,
    so that the card never leaves the screen.
12. As someone mid-answer, I want my unsent selections to survive the card's refresh, so that a
    background tick cannot wipe a half-filled form.
13. As someone who clicked Send and got nothing, I want the question to leave the card rather than
    loop, so that a rejected answer does not become a permanent interruption.
14. As someone answering a question in the terminal instead, I want the card to notice and fold, so
    that I never have to dismiss what is already done.
15. As someone who wants to answer in the terminal, I want Hide in the card's footer, so that I can
    put the question back without answering it.
16. As someone who does not want the card to stay up, I want questions to fold after a set time, or
    never fold at all, so that the surface obeys my preference.
17. As someone whose terminal is doing something else, I want the island to take the keyboard only
    while I am typing a free-text answer, so that my typing is not swallowed at any other moment.
18. As someone clicking the waiting session's row, I want it to still jump to that session's terminal
    pane, so that the card keeps the behaviour it has today.
19. As someone with two displays, I want the question card on both, answerable on either, so that I
    answer from wherever my pointer is.
20. As someone who answers in the terminal, I want the macOS notification to stay, so that there is
    still a durable record of the question.
21. As someone with a question the island cannot render, I want the card to say it must be answered in
    the terminal, so that the card does not pretend to be able to help.
22. As someone who does not want this behaviour, I want a menu toggle, so that the island stays a
    readout if I prefer.

## Implementation Decisions

- **The feature lives on the card, not on a new window.** The question block replaces the session list
  inside the existing expanded card: the waiting session's row stays, the block sits under it, and
  every other session folds into the `+k more` tail. Reuse the alert's existing scope mechanism rather
  than a second list computed beside it — one fold calculation serves the card, its frame and its
  summary line.
- **The monitor carries the ask.** The form list is already fetched once per scan for the directories
  it asks about; it now keeps the payload instead of discarding it, and hands the oldest pending form
  per session down with the rows. No new poll loop: reads ride the existing scan tick, the 0.5s render
  tick only draws.
- **The reply is one write, per form.** A form settles as a whole, so Send submits every field's answer
  in one request. Send is disabled until every required field carries an answer.
- **Selections are state, not render output.** Picked answers are held per form and field, keyed on
  the form's identity, and survive render ticks. They are dropped when the form's payload changes (it
  is a different question then) or when it settles.
- **Navigation has two axes.** Fields step left and right with chevrons and a counter; forms queue
  vertically, oldest first, one on the card at a time, with their own counter.
- **Free text is a row, not a mode.** "Other…" is the last row of a field's options; picking it turns
  the block into a text field and takes the keyboard on the non-activating panel. Nothing else in the
  card ever takes the keyboard.
- **A question outranks an alert.** A newly pending question preempts a card that an armed alert
  occupies; the alert's sound and row mark have already happened, so nothing is lost.
- **Unpainted field types are named, not hidden.** Any field outside what the card renders makes
  the form terminal-only: the card shows the asking row plus one dim line saying it must be answered
  in the terminal, because the reply carries the form's whole answer set and a partial one is a
  guaranteed rejection.
- **Ignoring field conditions is deliberate.** Hidden and conditional fields are rendered like any
  other, so the card's field set never shrinks under the user's pointer.
- **The card ends the way an alert does.** When the last pending form settles the card folds; Hide
  folds without answering. Fold timing is its own preference, defaulting to never folding.

## Testing Decisions

- The repo has no test harness, no CI and no linter; a successful `./build.sh` is the only automated
  check. No test framework is introduced by this feature.
- The one seam worth naming is the transform from the server's form payload to the card's block model
  — pure, and where the field filtering, ordering and required-gating live. It stays a plain function
  so that a future harness can pin it without touching the view layer.
- Verification is the build, then a manual pass against a live session carrying a real question: one
  single-field form, one multi-field form, one form with a free-text-only field, one form the card
  cannot render, two forms queued, and an alert armed when a question arrives.

## Required Skills

None beyond `AGENTS.md` — the app's build trap and the island's invariants are already there.

## Out of Scope

- Permission requests (allow/deny). They stay a terminal-only decision; the card keeps treating them
  as a waiting state without a control.
- Creating, editing or cancelling forms from the card.
- Answering from the menubar dropdown, the bubble, or the TUI plugin.
- Any keyboard navigation of options (arrow keys, Enter to send).
- Retrying a failed submit, and any queueing of writes.
- Multi-select limits (`minItems`/`maxItems`) checked client-side; a violation surfaces as a rejected
  submit, which the failure path already handles.

## Further Notes

- The question form's own title ("Questions") is boilerplate and never rendered; a field's short title
  is the block's heading, falling back to the field's full text.
- The card's list budget already owns how tall the card may get; the block's scrolling comes out of
  the same budget rather than a second one.
- A TUI plugin is a delivery vehicle this app already has: the build installs the session bridge into
  the OpenCode config, so a plugin change ships with the app and needs no separate install. This
  feature needs none — the form list and the reply are plain HTTP against the server the monitor
  already polls — and a plugin-side change would ride the same build if one ever earned its place.

## Contracts

### Data

The card reads one payload shape and writes one. Both come from the local OpenCode server.

`Form.Info` — one entry per pending form, as returned by the form list:

| Field | Type | Null | Meaning |
|---|---|---|---|
| `id` | string (`frm_` prefix) | no | Form identity, the reply's path segment |
| `sessionID` | string (`ses_` prefix) | no | The session blocked on it |
| `title` | string | no | Form-level title; boilerplate for questions, never rendered |
| `metadata` | object | yes | Free-form; the question tool records `kind: "question"` and its tool call |
| `fields` | array, non-empty | no | The questions, in ask order |

`Form.Field` — one question:

| Field | Type | Null | Meaning |
|---|---|---|---|
| `key` | string | no | Answer key in the reply map |
| `type` | enum | no | `string`, `number`, `integer`, `boolean`, `multiselect`, `external` |
| `title` | string | yes | Short heading |
| `description` | string | yes | The question itself |
| `required` | bool | yes | Absent means optional, except where `type` implies otherwise |
| `hidden` | bool | yes | Ignored by this feature |
| `when` | array of `{key, op: eq\|neq, value}` | yes | Ignored by this feature |
| `options` | array of `{value, label, description?}` | yes | Present for `string`-with-options and `multiselect` |
| `custom` | bool | yes | Free text allowed; absent behaves as allowed |
| `default` | string / number / bool / string[] | yes | Pre-selected answer |
| `minItems` / `maxItems` | int | yes | Multiselect bounds; not checked client-side |
| `minLength` / `maxLength` / `pattern` / `format` | — | yes | Text constraints; not checked client-side |
| `url` | string | yes | `external` fields only |

Answer values, by field type: `string` → string, `number`/`integer` → number, `boolean` → bool,
`multiselect` → array of strings. `external` → `true`, and lies outside this feature.

### Interfaces

- **Read:** `GET /api/form?location[directory]=<abs path>` → `{location, data: Form.Info[]}`,
  pending only. Following the server, a settled form disappears from the very next response.
- **Write:** `POST /api/session/<sessionID>/form/<formID>/reply`, body
  `{"answer": {"<fieldKey>": <value>, …}}`, success `204` with an empty body.
- **Failures from the write:** `400` invalid answer (missing required field, wrong type, unknown key),
  `404` form not found, `409` form already settled. Transport failure is equally possible. All four
  are treated the same: the block drops and the form is suppressed until its payload changes.

### Config

| Key | Type | Domain | Default | Owner | Effect |
|---|---|---|---|---|---|
| `ocbar.questions` | bool | on / off | on | island menu | Off: no question card, no unprompted open; the waiting state and notification stay |
| `ocbar.questionFold` | string | `never`, `5`, `10`, `20`, `30`, `60` | `never` | island menu | `never`: the card stays until answered or hidden. A seconds value folds it that long after it takes the card; the timer restarts per queued form and the pointer never pauses it |

Both are read at use time, so a menu pick applies without a relaunch — the same rule the existing
feature gates follow.

## Invariants

- Only sessions the card lists may be answered from it.
- One form occupies the card at a time; the oldest pending one wins.
- A pending question outranks an armed alert. The alert's sound and row mark are already spent by
  that point, and nothing about the alert survives onto the question card.
- The waiting session's row is the block's anchor: it is the same row, with the same click-to-focus.
- Unsent answers survive render ticks; they do not survive a change to the form's payload or the form
  settling.
- Send submits every answer in one reply and is disabled until every required field has one.
- A failed submit never retries and never re-offers the same payload.
- Every screen's panel shows the same question and any of them may answer it.
- The macOS notification is independent of the card and is never cancelled by answering.

## States and failure

The card's block has one state at a time:

| State | Entered by | Leaves by |
|---|---|---|
| `idle` | no pending form for a listed session | a form appears → `asking` |
| `asking(fieldIndex, answers)` | a pending form arrives, or the previous one settles and another is queued | Send → `submitting`; the form settles elsewhere → `idle` or the next form; Hide → `idle` until the timer/next event |
| `submitting` | Send pressed | `204` → next queued form, or `idle` and the card folds; `400`/`404`/`409`/transport → `suppressed` |
| `suppressed(formID, payload)` | a failed submit | a different payload for that form, or the form settling → `idle` |

Server-side form states are `pending`, `answered`, `cancelled`; only `pending` is ever visible to the
card, and a settled form simply stops being listed. Nothing on the client cleans up after a form; the
server's own expiry does.

The suppression key is the form's identity together with its payload, so a form that is re-asked with
different fields is a new question and is offered again.

## Boundaries

- **OpenCode server (local).** The card reads the form list and writes the reply; the server owns form
  lifetime entirely, expiring settled forms after its own cache window. Reads carry the location
  directory that the existing scan already passes for these endpoints; the write is session-scoped.
  Within a directory the server's list order is used untouched, so "oldest" is the server's cache
  insertion order; across directories the order is the directory order, which is the only
  deterministic order the server exposes.
- **Server down.** The monitor's existing behaviour governs: no service endpoint, no sessions, no
  forms, and the card empties. No retry is introduced, and a reply attempted against a vanished
  server lands in the failure path like any `404`.
- **No push.** The server exposes form events over SSE; this feature keeps polling, because the
  events are ephemeral and a reconnecting poller cannot replay them. A form answered in the terminal
  is noticed on the next scan tick, not instantly.