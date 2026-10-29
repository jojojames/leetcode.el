"""Stepwise LeetCode intervals for legacy and current Anki schedulers.

Install this directory in Anki's addons21 directory and restart Anki.
The native reviewer and AnkiConnect share these interval previews and
answer handling. Other decks retain their normal scheduling.
"""

from functools import wraps
import importlib

from aqt import mw


def interval_days(scheduler, card, ease, allow_filtered=False):
    """Return a configured interval, or None for native scheduling."""
    if ease not in (2, 3, 4) or card.queue not in (0, 1, 2, 3):
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
    if original and not allow_filtered:
        return None
    starts = config.get("days", {"2": 3, "3": 4, "4": 5})
    if not starts:
        return None
    ladder = config.get("intervals", [3, 4, 5, 7, 10, 14, 18, 24, 30, 40, 50, 65, 80, 100])
    if (not isinstance(ladder, list) or not ladder
            or any(type(day) is not int or day < 1 for day in ladder)
            or any(a >= b for a, b in zip(ladder, ladder[1:]))):
        raise ValueError("LeetCode intervals must be strictly increasing positive whole days")
    card_type = getattr(card, "type", 0)
    if card_type == 3:
        # A successful relearning answer restarts at the first step.
        days = ladder[0]
    elif card.queue == 2:
        current_interval = getattr(card, "interval", getattr(card, "ivl", 0))
        if ease == 2:
            days = min(max(current_interval, ladder[0]), ladder[-1])
        else:
            later = [day for day in ladder if day > current_interval]
            advance = 1 if ease == 3 else 2
            days = later[min(advance, len(later)) - 1] if later else ladder[-1]
    else:
        days = starts.get(str(ease))
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


def customize_states(scheduler, card, states, allow_filtered=False):
    """Override passing intervals in current Anki's native states.

    The backend records the selected state directly, so previews, due dates,
    undo, review history, and FSRS memory remain part of the native answer.
    """
    if states.current.WhichOneof("kind") == "filtered":
        # Only our own rescheduling deck gets the learning interval override.
        # Other filtered decks and preview-only sessions remain native.
        if (scheduler.col.decks.get(card.deck_id)["name"] != RANDOM_DECK
                or states.current.filtered.WhichOneof("kind") != "rescheduling"):
            return
        from anki.scheduler_pb2 import SchedulingStates
        native = SchedulingStates()
        for name in ("current", "again", "hard", "good", "easy"):
            state = getattr(states, name)
            if state.WhichOneof("kind") == "normal":
                getattr(native, name).CopyFrom(state)
            elif state.filtered.WhichOneof("kind") == "rescheduling":
                getattr(native, name).normal.CopyFrom(state.filtered.rescheduling.original_state)
            else:
                return
        customize_states(scheduler, card, native, allow_filtered=True)
        for name in ("again", "hard", "good", "easy"):
            normal = getattr(native, name).normal
            if normal.WhichOneof("kind") == "review":
                # Graduation exits the filtered deck through a normal state.
                getattr(states, name).CopyFrom(getattr(native, name))
            else:
                getattr(states, name).filtered.rescheduling.original_state.CopyFrom(normal)
        return
    if not states.current.HasField("normal"):
        return
    # Easy supplies a native graduation template, including starting ease.
    if not states.easy.normal.HasField("review"):
        return
    for ease, name in ((2, "hard"), (3, "good"), (4, "easy")):
        days = interval_days(scheduler, card, ease, allow_filtered)
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


RANDOM_DECK = "LeetCode Random"


def prepare_random_card(owner, card_id, deck):
    """Put one new problem in a native rescheduling filtered deck.

    Existing cards in the extra deck are never discarded. New-card limits
    are increased for today so random review does not consume the normal
    allowance. Original deck ownership and scheduling remain native.
    """
    if type(card_id) is not int or card_id < 1:
        raise ValueError("Card ID must be a positive integer")
    collection = owner.collection()
    card = collection.get_card(card_id)
    existing = collection.decks.by_name(RANDOM_DECK)
    if existing and card.did == existing["id"] and card.odid:
        return RANDOM_DECK
    home = collection.decks.get(card.did)["name"]
    if home != deck and not home.startswith(deck + "::"):
        raise ValueError("The chosen problem is outside the selected deck")
    if card.type != 0 or card.queue != 0 or card.odid:
        raise ValueError("Extra credit requires an unstudied, available problem")
    if existing:
        if not existing.get("dyn"):
            raise ValueError("LeetCode Random exists but is not a filtered deck")
        if collection.db.scalar("select count(*) from cards where did=?", existing["id"]):
            raise ValueError("Finish the existing random review problem before choosing another")
        did = existing["id"]
    else:
        did = collection.decks.new_filtered(RANDOM_DECK)
    config = collection.sched.get_or_create_filtered_deck(did)
    config.config.reschedule = True
    del config.config.search_terms[:]
    term = config.config.search_terms.add()
    term.search = f"cid:{card_id} is:new -is:suspended -is:buried"
    term.limit = 1
    collection.sched.add_or_update_filtered_deck(config)
    if collection.sched.rebuild_filtered_deck(did).count != 1:
        raise ValueError("Anki could not select the random review problem")
    collection.decks.select(card.did)
    collection.sched.extend_limits(1, 0)
    return RANDOM_DECK


def finish_random_card(owner, card_id):
    """Return a rated learning card home without changing its next due time."""
    if type(card_id) is not int or card_id < 1:
        raise ValueError("Card ID must be a positive integer")
    collection = owner.collection()
    card = collection.get_card(card_id)
    deck = collection.decks.by_name(RANDOM_DECK)
    if not deck or card.did != deck["id"]:
        return True  # Graduating answers have already returned it home.
    if card.reps < 1 or not card.odid:
        raise ValueError("The random review problem has not been rated")
    ids = collection.db.list("select id from cards where did=?", deck["id"])
    if ids != [card_id]:
        raise ValueError("Unexpected cards in random review deck; inspect Anki")
    collection.sched.empty_filtered_deck(deck["id"])
    return True


def review_random_card_async(owner, card_id, deck, deferred_class, schedule):
    """Open the native random review reviewer and await its exact card."""
    import time
    result = deferred_class()
    deadline = time.monotonic() + 4
    collection = owner.collection()

    def wait():
        try:
            if owner.collection() is not collection:
                raise ValueError("Anki collection changed while opening random review")
            if time.monotonic() >= deadline:
                raise ValueError("Timed out opening random review; retry to resume the same card")
            if owner.window()._background_op_count:
                schedule(25, wait)
                return
            current = owner.guiCurrentCard() if owner.guiReviewActive() else None
            if not current or current["cardId"] != card_id:
                raise ValueError("Anki did not open the chosen random review problem")
            result.resolve(current)
        except Exception as error:
            result.resolve(error=error)

    try:
        name = prepare_random_card(owner, card_id, deck)
        if not owner.guiDeckReview(name):
            raise ValueError("Could not open random review reviewer")
        schedule(0, wait)
    except Exception as error:
        result.resolve(error=error)
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
    connector.AnkiConnect.guiLeetcodeFinishRandomCard = connector.util.api(
        (6, "leetcodeFinishRandomCard"))(lambda self, cardId: None)
    connector.AnkiConnect.guiLeetcodeReviewRandomCard = connector.util.api(
        (6, "leetcodeReviewRandomCard"))(
            lambda self, cardId, deck: None)
    if hasattr(connector, "Legacy") and not getattr(
            connector.Legacy, "_leetcode_bridge_installed", False):
        original_call = connector.Legacy.call

        @wraps(original_call)
        def call(adapter, name, params):
            if name == "guiLeetcodeFinishRandomCard":
                return finish_random_card(adapter.owner, params["cardId"])
            if name == "guiLeetcodeReviewRandomCard":
                from aqt.qt import QTimer
                protocol = importlib.import_module(connector.__name__ + ".protocol")
                return review_random_card_async(
                    adapter.owner, params["cardId"], params["deck"],
                    protocol.Deferred, QTimer.singleShot)
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
