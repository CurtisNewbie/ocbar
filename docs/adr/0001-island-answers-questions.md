# 0001: The island answers questions

**Status:** Accepted

## Context

ocbar knows a session is blocked on a question — the waiting state, the blue mark, the notification —
but answering means finding that session's terminal. The reminder surface can point at the question and
cannot act on it. The local OpenCode server exposes the pending forms and accepts a reply over HTTP, so
the information and the write are both already reachable from the app.

## Decision

The expanded card carries the question form. A pending question opens the island on every screen,
shows the waiting session's row with the question beneath it, folds every other session into the
`+k more` tail, and submits the form's answers back to the server.

- One form on the card at a time, oldest first, with further forms queued and counted.
- A pending question outranks an armed alert: the notification state is the one that must be answered.
- Send is explicit and submits a form's whole answer set in one reply; a selection alone never sends.
- Only sessions the card lists are answerable from it.
- Answers are picked alongside the terminal, not instead of it: free text needs the keyboard, so the
  card takes it for that one interaction and never otherwise.

## Consequences

The island stops being a readout and becomes a control surface, which is the same step the bubble and
the row click already took. A form that fails to submit is dropped rather than retried, so a rejected
answer costs the user a retry in the terminal — chosen over a card that re-offers a question the server
will not accept. Form lifetime stays entirely with the server: the app never expires, retries or
re-asks anything.

Permission requests deliberately stay terminal-only. They are a security decision with different
semantics (approve once, always, reject, with a message), and folding them into the same block would
put a consent prompt on a surface the user has not focused.

## Alternatives rejected

- **A separate question window.** A second floating surface would duplicate the card's whole layout,
  budget and alert ownership, and would compete with the island for the same attention.
- **Inline per-row expansion.** The card is a ranked list; a question grown out of one row leaves the
  other rows competing with the question for the same card, which is exactly the hunt the alert's
  single-row scope already exists to prevent.
- **Answering permissions from the card too.** Rejected above: different semantics, higher stakes.
- **Submitting each field as it is answered.** The server settles a form as a whole, so per-field writes
  would need a synthetic form per field and would leave the real form half-answered.