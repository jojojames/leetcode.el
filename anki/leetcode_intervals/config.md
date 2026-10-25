Use `deck` to select the root deck (all its subdecks are included).

`days` maps Anki answer buttons to starting delays in days: 2 = Hard,
3 = Good, 4 = Easy. These apply to new, learning, and relearning cards.
The card then graduates to review, where Anki resumes its native growing
intervals. Again uses the deck's native learning/relearning steps. After
a lapse, the next successful relearning rating uses these starting delays
again, preserving the card's ease. Other decks are unaffected.

The add-on also exposes Anki's native extra-new-cards action to AnkiConnect
for `leetcode-anki-next-force`. This extends today's allowance only; the
deck's permanent daily limit is unchanged. Set `days` to `{}` to disable
the interval overrides while retaining this bridge.

This add-on supports current Anki (tested with 26.9.3, including FSRS) and
the older 2.1.33 Python v2 scheduler. On current Anki it changes native
learning answer states before they are displayed or recorded, preserving
each rating's predicted FSRS memory, lapse count, ease, native undo, and
review history. The displayed and recorded intervals match. Graduated
review states are unchanged. On the older scheduler it records the native
rating and then explicitly reschedules the card; legacy review history
retains the native interval rather than the override.
