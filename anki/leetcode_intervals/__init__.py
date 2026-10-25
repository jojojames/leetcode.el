"""Longer learning intervals for Anki 2.1's Python v2 scheduler.

Install this directory in Anki's addons21 directory and restart Anki.
The native reviewer and AnkiConnect share these interval previews and
answer handling. Other decks retain their normal scheduling.
"""

from functools import wraps
import importlib

from aqt import mw
from anki import schedv2


def interval_days(scheduler, card, ease):
    """Return a learning interval, or None for native review scheduling."""
    # New, learning, and day-learning cards get problem-sized starting
    # delays. Graduated reviews retain Anki's growing intervals.
    if card.queue not in (0, 1, 3):
        return None
    config = mw.addonManager.getConfig(__name__) or {}
    root = config.get("deck", "LeetCode::NeetCode150")
    deck = scheduler.col.decks.get(card.odid or card.did)
    name = deck["name"]
    if name != root and not name.startswith(root + "::"):
        return None
    # Filtered decks can have different button meanings; leave them native.
    if card.odid:
        return None
    days = config.get("days", {"2": 2, "3": 5, "4": 10}).get(str(ease))
    if days is not None and (type(days) is not int or days < 1):
        raise ValueError("LeetCode review intervals must be positive whole days")
    return days


def install(scheduler_class):
    """Keep previews and scheduling consistent on a Python scheduler."""
    if scheduler_class.__dict__.get("_leetcode_intervals_installed", False):
        return
    original_interval = scheduler_class.nextIvl
    original_answer = scheduler_class.answerCard

    @wraps(original_interval)
    def next_interval(self, card, ease):
        days = interval_days(self, card, ease)
        if days is not None:
            return days * 86400
        return original_interval(self, card, ease)

    @wraps(original_answer)
    def answer(self, card, ease):
        # Validate before recording anything. Keep Anki's review history,
        # daily limits, lapse tracking, and undo checkpoint for the rating.
        days = interval_days(self, card, ease)
        result = original_answer(self, card, ease)
        if days is not None:
            factor = card.factor
            # Move learning cards into the review queue as well, otherwise
            # their next learning step could repeat the problem today.
            self.reschedCards([card.id], days, days)
            card.load()
            # Native rescheduling resets ease. Preserve the existing ease
            # after a lapse so future reviews retain their history.
            if factor > 0:
                card.factor = factor
                card.flush()
            # Remove the old learning entry before the reviewer picks next.
            self.reset()
        return result

    scheduler_class.nextIvl = next_interval
    scheduler_class.answerCard = answer
    scheduler_class._leetcode_intervals_installed = True


install(schedv2.Scheduler)


def extend_new_cards(self, deck, count=1):
    """Expose native Custom Study's extra new cards through AnkiConnect.

    True means the native reviewer has a card. False means there are no
    unstudied cards to unlock. Never grade a card or change preset limits.
    """
    if type(count) is not int or count < 1:
        raise ValueError("Extra new-card count must be a positive integer")
    collection = self.collection()
    if collection.decks.byName(deck) is None:
        raise ValueError("Deck not found: " + deck)
    # Guard a race with another client starting a review after Emacs checked.
    if self.guiReviewActive():
        if collection.decks.current()["name"] != deck:
            raise ValueError("Anki is reviewing a different deck")
        return True
    # Re-enter through the native reviewer first: a learning/review card
    # may have become due since Emacs checked, requiring no extra allowance.
    if not self.guiDeckReview(deck):
        raise ValueError("Could not select deck: " + deck)
    if self.guiReviewActive():
        return True
    scheduler = self.scheduler()
    scheduler.reset()
    # Native count includes the selected deck's children, without choosing
    # a card ourselves or changing any card's due date.
    if not scheduler.totalNewForCurrentDeck():
        return False
    scheduler.extendLimits(count, 0)
    if not self.guiDeckReview(deck):
        raise ValueError("Could not start the extended review")
    if not self.guiReviewActive():
        raise ValueError("Today's new-card allowance was extended, but no card became ready; check review and parent-deck limits")
    return True


def install_anki_connect():
    """Register the bridge with AnkiConnect when that add-on is installed."""
    try:
        connector = importlib.import_module("2055492159")
    except ModuleNotFoundError:
        return
    connector.AnkiConnect.leetcodeExtendNewCards = connector.util.api()(extend_new_cards)


install_anki_connect()
