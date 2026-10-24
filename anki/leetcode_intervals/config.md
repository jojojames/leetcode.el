Use `deck` to select the root deck (all its subdecks are included).

`days` maps Anki answer buttons to starting delays in days: 2 = Hard,
3 = Good, 4 = Easy. These apply to new, learning, and relearning cards.
The card then graduates to review, where Anki resumes its native growing
intervals. Again uses the deck's native learning/relearning steps. After
a lapse, the next successful relearning rating uses these starting delays
again, preserving the card's ease. Other decks are unaffected.

This add-on supports Anki 2.1's Python v2 scheduler (including 2.1.33),
not newer Rust/FSRS schedulers. It preserves the native rating in review
history, then explicitly reschedules the card; the history entry describes
the native rating, while the card's due date reflects this fixed override.
