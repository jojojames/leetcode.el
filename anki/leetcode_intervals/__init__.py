"""Longer learning intervals for legacy and current Anki schedulers.

Install this directory in Anki's addons21 directory and restart Anki.
The native reviewer and AnkiConnect share these interval previews and
answer handling. Other decks retain their normal scheduling.
"""

from functools import wraps
import importlib

from aqt import mw


def interval_days(scheduler, card, ease):
    """Return a learning interval, or None for native review scheduling."""
    # New, learning, and day-learning cards get problem-sized starting
    # delays. Graduated reviews retain Anki's growing intervals.
    if card.queue not in (0, 1, 3):
        return None
    config = mw.addonManager.getConfig(__name__) or {}
    root = config.get("deck", "LeetCode::NeetCode150")
    original = getattr(card, "original_deck_id", getattr(card, "odid", 0))
    current = getattr(card, "deck_id", getattr(card, "did", 0))
    deck = scheduler.col.decks.get(original or current)
    name = deck["name"]
    if name != root and not name.startswith(root + "::"):
        return None
    # Filtered decks can have different button meanings; leave them native.
    if original:
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


def customize_states(scheduler, card, states):
    """Override only learning transitions in current Anki's native states.

    The backend records the selected state directly, so previews, due dates,
    undo, review history, and FSRS memory remain part of the native answer.
    """
    if not states.current.HasField("normal"):
        return
    if states.current.normal.WhichOneof("kind") == "review":
        return
    # Easy supplies a native graduation template, including starting ease.
    if not states.easy.normal.HasField("review"):
        return
    for ease, name in ((2, "hard"), (3, "good"), (4, "easy")):
        days = interval_days(scheduler, card, ease)
        if days is None:
            continue
        state = getattr(states, name)
        normal = state.normal
        kind = normal.WhichOneof("kind")
        review = type(states.easy.normal.review)()
        if kind == "review":
            review.CopyFrom(normal.review)
        elif kind == "relearning":
            review.CopyFrom(normal.relearning.review)
        elif kind == "learning":
            review.CopyFrom(states.easy.normal.review)
            # Use this rating's predicted FSRS memory, not Easy's memory.
            if normal.learning.HasField("memory_state"):
                review.memory_state.CopyFrom(normal.learning.memory_state)
            else:
                review.ClearField("memory_state")
        else:
            continue
        review.scheduled_days = days
        review.elapsed_days = 0
        normal.review.CopyFrom(review)


def install_modern(scheduler_class):
    """Customize native queue states without patching removed v2 methods."""
    if scheduler_class.__dict__.get("_leetcode_intervals_installed", False):
        return
    original = scheduler_class.get_queued_cards

    @wraps(original)
    def queued_cards(self, *args, **kwargs):
        result = original(self, *args, **kwargs)
        for queued in result.cards:
            customize_states(self, queued.card, queued.states)
        return result

    scheduler_class.get_queued_cards = queued_cards
    scheduler_class._leetcode_intervals_installed = True


try:
    from anki import schedv2
except ImportError:
    from anki.scheduler.v3 import Scheduler
    install_modern(Scheduler)
else:
    install(schedv2.Scheduler)


def extend_new_cards(self, deck, count=1):
    """Expose native Custom Study's extra new cards through AnkiConnect.

    True means the native reviewer has a card. False means there are no
    unstudied cards to unlock. Never grade a card or change preset limits.
    """
    if type(count) is not int or count < 1:
        raise ValueError("Extra new-card count must be a positive integer")
    collection = self.collection()
    by_name = getattr(collection.decks, "by_name", None) or collection.decks.byName
    selected = by_name(deck)
    if selected is None:
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
    # Native count includes the selected deck's children, without choosing
    # a card ourselves or changing any card's due date.
    if hasattr(scheduler, "custom_study_defaults"):
        defaults = scheduler.custom_study_defaults(selected["id"])
        if not (defaults.available_new + defaults.available_new_in_children):
            return False
        scheduler.extend_limits(count, 0)
    else:
        scheduler.reset()
        if not scheduler.totalNewForCurrentDeck():
            return False
        scheduler.extendLimits(count, 0)
    if not self.guiDeckReview(deck):
        raise ValueError("Could not start the extended review")
    if not self.guiReviewActive():
        raise ValueError("Today's new-card allowance was extended, but no card became ready; check review and parent-deck limits")
    return True


def extend_new_cards_async(owner, deck, count, deferred_class, schedule):
    """Wait for native reviewer operations before inspecting their results.

    Each phase runs once. In particular, waiting never repeats the allowance
    mutation, even when opening the reviewer takes multiple event-loop turns.
    """
    import time

    result = deferred_class()
    deadline = time.monotonic() + 4
    collection = owner.collection()
    window = owner.window()

    def wait(callback):
        if result.done:
            return
        try:
            if owner.collection() is not collection:
                raise ValueError("Anki collection changed while opening the problem")
            if time.monotonic() >= deadline:
                raise ValueError("Timed out waiting for Anki's reviewer; check Anki before forcing again")
            if window._background_op_count:
                schedule(25, lambda: wait(callback))
            else:
                callback()
        except Exception as error:
            result.resolve(error=error)

    def navigate(callback):
        if not owner.guiDeckReview(deck):
            raise ValueError("Could not select deck: " + deck)
        # moveToState starts a collection operation and returns before the
        # reviewer is ready. Yield to Qt, then wait for its completion.
        schedule(0, lambda: wait(callback))

    def finish():
        if not owner.guiReviewActive():
            raise ValueError("Today's new-card allowance was extended, but no card became ready; check review and parent-deck limits")
        result.resolve(True)

    def extend():
        if owner.guiReviewActive():
            result.resolve(True)
            return
        selected = collection.decks.by_name(deck)
        scheduler = owner.scheduler()
        defaults = scheduler.custom_study_defaults(selected["id"])
        if not (defaults.available_new + defaults.available_new_in_children):
            result.resolve(False)
            return
        scheduler.extend_limits(count, 0)
        navigate(finish)

    def start():
        if type(count) is not int or count < 1:
            raise ValueError("Extra new-card count must be a positive integer")
        if collection.decks.by_name(deck) is None:
            raise ValueError("Deck not found: " + deck)
        if owner.guiReviewActive():
            if collection.decks.current()["name"] != deck:
                raise ValueError("Anki is reviewing a different deck")
            result.resolve(True)
        else:
            navigate(extend)

    wait(start)
    return result


def install_anki_connect():
    """Register the bridge with AnkiConnect when that add-on is installed."""
    try:
        connector = importlib.import_module("2055492159")
    except ModuleNotFoundError:
        return
    # Current AnkiConnect dispatches gui-prefixed methods on the UI thread.
    # Keep the public action name used by Emacs through a versioned alias.
    connector.AnkiConnect.guiLeetcodeExtendNewCards = connector.util.api(
        (6, "leetcodeExtendNewCards"))(extend_new_cards)
    if hasattr(connector, "Legacy") and not getattr(
            connector.Legacy, "_leetcode_bridge_installed", False):
        original_call = connector.Legacy.call

        @wraps(original_call)
        def call(adapter, name, params):
            if name == "guiLeetcodeExtendNewCards":
                from aqt.qt import QTimer
                protocol = importlib.import_module(connector.__name__ + ".protocol")
                return extend_new_cards_async(
                    adapter.owner, params["deck"], params.get("count", 1),
                    protocol.Deferred, QTimer.singleShot)
            return original_call(adapter, name, params)

        connector.Legacy.call = call
        connector.Legacy._leetcode_bridge_installed = True


install_anki_connect()
