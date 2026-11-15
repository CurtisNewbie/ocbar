# Code review rules: ocbar

Mistakes this repo keeps making, each one a tell that shows up in a diff. Written by reviews.

1. **A widened rule needs a widened field.** Tell: a rule goes from "the head, if it is X" to "any form except X" while the field holding X stays single-valued, beside a `Set` of the same keys. Shape: widen the state with the rule and re-check every write, or the value a write drops becomes visible again.

2. **Moving logic into a tested seam makes the call the untested part.** Tell: a pure function is pinned by tests while the caller's delegation is the only thing a revert can break, and the suite stays green. Shape: keep the call trivial and name the gap in the harness ("shortcut: <what is not compiled>, <when to extend>") instead of claiming the behaviour is pinned.
