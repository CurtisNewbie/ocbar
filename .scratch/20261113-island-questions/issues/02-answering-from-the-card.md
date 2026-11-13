# 02: Answering from the card

**What to build:** The block becomes answerable. Picking an option selects it visibly; "Other…" turns
the block into a text field that takes the keyboard and accepts typed answers; chevrons step between
the form's fields; Send sits in the footer left of Hide, disabled until every required field carries an
answer, and submits every field's answer in one reply to the server. Unsent selections survive the
render ticks. A successful reply removes the form from the card; a rejected or failed one drops the
block silently and does not offer that same form payload again. The waiting row keeps its
click-to-focus. Nothing about queueing, unprompted opening or fold timing changes here.

**Blocked by:** 01.

**Status:** ready-for-agent

- [ ] Clicking an option marks it selected; clicking another option in the same field replaces the
      selection; a multiselect field accumulates selections.
- [ ] Send stays disabled until every required field has an answer, then submits all answers in one
      request and leaves the card on success.
- [ ] "Other…" replaces the options with a text field that takes the keyboard on the non-activating
      panel, and its answer is submitted as that field's value.
- [ ] Chevrons move between the form's fields, and the counter follows; answers already given are
      still shown when stepping back.
- [ ] Selections picked but not sent survive the card's refresh ticks, and are discarded when the
      form's payload changes or the form settles.
- [ ] A failed submit (invalid answer, not found, already settled, or transport) drops the block
      without a message and does not re-offer the same form payload.
- [ ] A question answered in the terminal leaves the card on the next scan, with no click needed.
- [ ] Clicking the waiting session's row still jumps to its terminal pane.
- [ ] `./build.sh` succeeds and a real question is answerable end to end from the island.