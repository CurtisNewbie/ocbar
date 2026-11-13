# 03: A question outranks the island's other states

**What to build:** A pending question becomes the island's top state. A newly pending question opens the
card on every screen by itself, preempting a card an armed alert is holding; further forms queue
oldest first, one shown at a time with a `1 of 3` counter, each taking the card in place after a Send
and getting its own fold deadline. The card folds when the last form settles, and Hide folds without
answering. A new preference decides whether questions fold never or after a set time, alongside a
toggle that turns the whole question surface off, both reachable from the island menu. The macOS
notification keeps firing beside the card, and the row mark and sound of a transition that lost its
card to a question still happen.

**Blocked by:** 02.

**Status:** ready-for-agent

- [ ] A question arriving while the island is folded opens the card on every screen; every panel shows
      the same question and answering on any one of them updates all.
- [ ] A question arriving while a done-alert is armed takes the card immediately, and the alert's row
      mark and sound are unaffected.
- [ ] With several forms pending, the oldest takes the card first, its counter shows position, and the
      next replaces it in place after Send with a fresh fold deadline.
- [ ] When the last pending form settles the card folds; Hide folds without answering.
- [ ] `ocbar.questionFold` offers `never` (default) plus 5/10/20/30/60 seconds, applies without a
      relaunch, and its timer is not paused by the pointer inside the card.
- [ ] `ocbar.questions` (default on) hides the whole question surface when off, leaving the waiting
      state and the notification untouched.
- [ ] The "Question pending" notification still fires alongside the card.
- [ ] `./build.sh` succeeds, and a manual pass covers: single-field, multi-field, free-text-only,
      unrenderable, two queued, and an alert armed when a question arrives.