# 01: The card shows the pending question

**What to build:** The monitor keeps the pending form payloads it already fetches instead of discarding
them, and the expanded card renders the oldest pending form for a listed session as read-only content:
the waiting session's row, then under it a block carrying the field's heading, a `1 / n` field counter,
the field's options with their descriptions, and a dim "answer in terminal" line for a form whose
fields the card cannot render. Every other session folds into the `+k more` tail while the block is
up. No interaction yet — nothing here writes, and the card opens only by hover.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] A listed session with a pending question shows its row plus a question block; other sessions
      appear only in the `+k more` tail.
- [ ] The block's heading is the field's short title, falling back to its full question text; the
      form's own title is never rendered.
- [ ] Options render as label plus dim description when the option carries one, inside the card's
      existing height budget, scrolling rather than clipping when they do not fit.
- [ ] A form with several fields shows one field at a time with a `n / m` counter; chevrons are drawn
      but inactive in this ticket.
- [ ] A form whose fields are all outside the card's rendering set shows the row plus one dim
      "answer in terminal" line, and no options.
- [ ] Hovering a card with no pending form renders exactly what it renders today — same rows, same
      heights, same `+k more` behaviour.
- [ ] `./build.sh` succeeds and the app runs with a live session holding a real question.