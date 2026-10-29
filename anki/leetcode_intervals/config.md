The `deck` root and its subdecks use the custom interval ladder.

`days` sets initial Hard/Good/Easy intervals (buttons 2/3/4): 3/4/5 days.
`intervals` lists the increasing steps, capped at 100 days.

For graduated reviews, Hard holds the current interval (bounded by the
ladder minimum/maximum), Good chooses the next strictly greater step,
and Easy chooses the second greater step. Existing off-ladder intervals
advance to the next greater steps. At the maximum, passing answers stay
at the maximum. Late reviews use the card's scheduled interval, without
a lateness bonus. Again uses native relearning; its next successful
Hard/Good/Easy answer restarts at the first ladder step (3 days).

Other decks and ordinary filtered decks retain native scheduling.
The add-on's LeetCode Random filtered deck uses the same overrides.
Set `days` to `{}` to disable scheduling overrides while retaining the
AnkiConnect extra-new-card and random-card bridges.

Restart Anki after changing Python code. Existing due dates are preserved;
the ladder applies when a card is next rated. Current Anki displays and
records the custom answer states, retaining native undo and rating history.
The legacy scheduler records its native rating before rescheduling, so its
review log interval can differ from the final scheduled interval.

Daily limits are stored separately in Anki's deck preset: 1 new/day,
3 reviews/day, and a maximum interval of 100 days. Extra-new-card commands
can extend today's new-card allowance.
