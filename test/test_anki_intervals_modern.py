"""Exercise the add-on against the real current Anki backend in temp collections.

Run with Anki's Python version and its app_packages on PYTHONPATH.
No installed profile or study cards are opened.
"""

import importlib.util
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

try:
    import anki.collection
    from anki.collection import Collection
    from anki.cards import Card
    from anki.scheduler.v3 import Scheduler, CardAnswer
except ImportError:
    Collection = None


@unittest.skipUnless(Collection, "Requires the current Anki Python packages")
class ModernIntervalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native_queue = staticmethod(Scheduler.get_queued_cards)
        cls.config = {"deck": "LeetCode::NeetCode150",
                      "days": {"2": 2, "3": 5, "4": 10}}
        manager = types.SimpleNamespace(getConfig=lambda _: cls.config)
        fake_aqt = types.SimpleNamespace(mw=types.SimpleNamespace(addonManager=manager))
        path = Path(__file__).resolve().parents[1] / "anki/leetcode_intervals/__init__.py"
        spec = importlib.util.spec_from_file_location("leetcode_modern_tests", path)
        cls.addon = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"aqt": fake_aqt}):
            spec.loader.exec_module(cls.addon)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="leetcode-modern-test-")
        self.col = Collection(str(Path(self.temp.name) / "collection.anki2"))
        self.did = self.col.decks.id("LeetCode::NeetCode150::Test")
        self.col.decks.select(self.did)

    def tearDown(self):
        self.col.close()
        self.temp.cleanup()

    def add_card(self):
        note = self.col.new_note(self.col.models.by_name("Basic"))
        note["Front"], note["Back"] = "Temporary problem", "Temporary answer"
        self.col.add_note(note, self.did)
        return note.card_ids()[0]

    def answer(self, queued, rating):
        card = Card(self.col, backend_card=queued.card)
        card.start_timer()
        self.col.sched.answer_card(self.col.sched.build_answer(
            card=card, states=queued.states, rating=rating))
        return self.col.get_card(card.id)

    def test_initial_delays_are_saved_in_due_dates_and_history(self):
        for rating, days in ((CardAnswer.HARD, 2), (CardAnswer.GOOD, 5), (CardAnswer.EASY, 10)):
            with self.subTest(days=days):
                self.add_card()
                queued = self.col.sched.get_queued_cards().cards[0]
                expected = [2, 5, 10]
                actual = [getattr(queued.states, name).normal.review.scheduled_days
                          for name in ("hard", "good", "easy")]
                self.assertEqual(actual, expected)
                card = self.answer(queued, rating)
                self.assertEqual(card.queue, 2)
                self.assertEqual(card.ivl, days)
                self.assertEqual(card.due, self.col.sched.today + days)
                self.assertEqual(self.col.db.scalar(
                    "select ivl from revlog where cid=? order by id desc limit 1", card.id), days)

    def test_again_is_native_and_graduated_intervals_keep_growing(self):
        cid = self.add_card()
        native = self.native_queue(self.col.sched).cards[0].states
        queued = self.col.sched.get_queued_cards().cards[0]
        self.assertEqual(queued.states.again, native.again)
        self.answer(queued, CardAnswer.EASY)
        self.col.sched.set_due_date([cid], "0")
        native = self.native_queue(self.col.sched).cards[0].states
        queued = self.col.sched.get_queued_cards().cards[0]
        self.assertEqual(queued.states, native)
        self.assertGreater(queued.states.good.normal.review.scheduled_days, 10)

    def test_other_decks_are_unchanged(self):
        self.did = self.col.decks.id("Vietnamese")
        self.col.decks.select(self.did)
        self.add_card()
        native = self.native_queue(self.col.sched)
        actual = self.col.sched.get_queued_cards()
        self.assertEqual(actual, native)

    def test_fsrs_uses_each_ratings_own_memory_state(self):
        self.col.set_config("fsrs", True)
        self.add_card()
        native = self.native_queue(self.col.sched).cards[0].states
        queued = self.col.sched.get_queued_cards().cards[0]
        for name in ("hard", "good"):
            original = getattr(native, name).normal
            memory = (original.learning.memory_state if original.HasField("learning")
                      else original.review.memory_state)
            self.assertTrue(memory.stability > 0)
            self.assertEqual(getattr(queued.states, name).normal.review.memory_state, memory)
        card = self.answer(queued, CardAnswer.GOOD)
        self.assertEqual(card.ivl, 5)
        self.assertIsNotNone(card.memory_state)

    def test_random_review_uses_home_intervals_and_returns_to_home_deck(self):
        for rating, days in ((CardAnswer.HARD, 2), (CardAnswer.GOOD, 5), (CardAnswer.EASY, 10)):
            with self.subTest(days=days):
                cid = self.add_card()
                api = types.SimpleNamespace(collection=lambda: self.col)
                name = self.addon.prepare_random_card(api, cid, "LeetCode::NeetCode150")
                did = self.col.decks.by_name(name)["id"]
                self.col.decks.select(did)
                queued = self.col.sched.get_queued_cards().cards[0]
                self.assertEqual(queued.card.id, cid)
                self.assertEqual(queued.states.current.WhichOneof("kind"), "filtered")
                self.assertEqual([getattr(queued.states, key).normal.review.scheduled_days
                                  for key in ("hard", "good", "easy")], [2, 5, 10])
                card = self.answer(queued, rating)
                self.assertEqual(card.did, self.did)
                self.assertEqual(card.odid, 0)
                self.assertEqual(card.ivl, days)
                self.assertEqual(card.due, self.col.sched.today + days)
                self.assertEqual(self.col.db.scalar("select count(*) from revlog where cid=?", cid), 1)

    def test_random_review_again_returns_learning_card_home_without_changing_due(self):
        cid = self.add_card()
        api = types.SimpleNamespace(collection=lambda: self.col)
        name = self.addon.prepare_random_card(api, cid, "LeetCode::NeetCode150")
        self.col.decks.select(self.col.decks.by_name(name)["id"])
        queued = self.col.sched.get_queued_cards().cards[0]
        card = self.answer(queued, CardAnswer.AGAIN)
        due = card.due
        self.assertTrue(self.addon.finish_random_card(api, cid))
        card = self.col.get_card(cid)
        self.assertEqual(card.did, self.did)
        self.assertEqual(card.odid, 0)
        self.assertEqual(card.queue, 1)
        self.assertEqual(card.due, due)
        self.assertEqual(card.reps, 1)
        self.assertTrue(self.addon.finish_random_card(api, cid))

    def test_random_review_does_not_consume_regular_allowance(self):
        regular = self.add_card()
        extra = self.add_card()
        config = self.col.decks.config_dict_for_deck_id(self.did)
        config["new"]["perDay"] = 1
        self.col.decks.update_config(config)
        api = types.SimpleNamespace(collection=lambda: self.col)
        name = self.addon.prepare_random_card(api, extra, "LeetCode::NeetCode150")
        self.col.decks.select(self.col.decks.by_name(name)["id"])
        queued = self.col.sched.get_queued_cards().cards[0]
        self.answer(queued, CardAnswer.GOOD)
        self.col.decks.select(self.did)
        self.assertEqual(self.col.sched.get_queued_cards().cards[0].card.id, regular)
        self.assertEqual(self.col.decks.config_dict_for_deck_id(self.did)["new"]["perDay"], 1)

    def test_random_review_preserves_existing_extra_card(self):
        api = types.SimpleNamespace(collection=lambda: self.col)
        cid = self.add_card()
        name = self.addon.prepare_random_card(api, cid, "LeetCode::NeetCode150")
        did = self.col.decks.by_name(name)["id"]
        self.assertEqual(self.addon.prepare_random_card(api, cid, "LeetCode::NeetCode150"), name)
        other = self.add_card()
        with self.assertRaisesRegex(ValueError, "Finish the existing"):
            self.addon.prepare_random_card(api, other, "LeetCode::NeetCode150")
        self.assertEqual(self.col.get_card(other).did, self.did)
        self.assertEqual(self.col.get_card(cid).did, did)

    def test_force_next_changes_only_todays_allowance(self):
        self.add_card()
        config = self.col.decks.config_dict_for_deck_id(self.did)
        config["new"]["perDay"] = 0
        self.col.decks.update_config(config)
        ready = [False]

        def review(_):
            ready[0] = bool(self.col.sched.get_queued_cards().cards)
            return True

        api = types.SimpleNamespace(collection=lambda: self.col,
                                    scheduler=lambda: self.col.sched,
                                    guiReviewActive=lambda: ready[0], guiDeckReview=review)
        self.assertTrue(self.addon.extend_new_cards(api, "LeetCode::NeetCode150::Test"))
        self.assertTrue(ready[0])
        self.assertEqual(self.col.decks.config_dict_for_deck_id(self.did)["new"]["perDay"], 0)

    def test_force_next_waits_for_async_reviewer_without_duplicate_extension(self):
        self.add_card()
        config = self.col.decks.config_dict_for_deck_id(self.did)
        config["new"]["perDay"] = 0
        self.col.decks.update_config(config)
        callbacks = []
        window = types.SimpleNamespace(_background_op_count=0)
        ready = [False]
        navigations = []

        class Deferred:
            done = False
            value = error = None

            def resolve(self, value=None, error=None):
                self.done, self.value, self.error = True, value, error

        def active():
            self.assertEqual(window._background_op_count, 0)
            return ready[0]

        def review(deck):
            navigations.append(deck)
            window._background_op_count = 1
            return True

        api = types.SimpleNamespace(
            collection=lambda: self.col, scheduler=lambda: self.col.sched,
            window=lambda: window, guiReviewActive=active, guiDeckReview=review)
        with patch.object(self.col.sched, "extend_limits",
                          wraps=self.col.sched.extend_limits) as extend:
            result = self.addon.extend_new_cards_async(
                api, "LeetCode::NeetCode150::Test", 1, Deferred,
                lambda delay, callback: callbacks.append(callback))
            self.assertFalse(result.done)
            # Waiting during the first navigation must not grant any cards.
            for _ in range(3):
                callbacks.pop(0)()
                extend.assert_not_called()
            window._background_op_count = 0
            callbacks.pop(0)()
            extend.assert_called_once_with(1, 0)
            self.assertFalse(result.done)
            # Waiting during the second navigation must not grant them again.
            for _ in range(3):
                callbacks.pop(0)()
                extend.assert_called_once_with(1, 0)
            ready[0] = bool(self.col.sched.get_queued_cards().cards)
            window._background_op_count = 0
            callbacks.pop(0)()
            self.assertTrue(result.done)
            self.assertIsNone(result.error)
            self.assertTrue(result.value)
            self.assertEqual(len(navigations), 2)
        self.assertEqual(self.col.decks.config_dict_for_deck_id(self.did)["new"]["perDay"], 0)

    def test_fsrs_relearning_keeps_lapses_ease_and_rating_memory(self):
        self.col.set_config("fsrs", True)
        cid = self.add_card()
        self.answer(self.col.sched.get_queued_cards().cards[0], CardAnswer.GOOD)
        self.col.sched.set_due_date([cid], "0")
        self.answer(self.col.sched.get_queued_cards().cards[0], CardAnswer.AGAIN)
        native = self.native_queue(self.col.sched).cards[0].states
        queued = self.col.sched.get_queued_cards().cards[0]
        self.assertEqual(native.current.normal.WhichOneof("kind"), "relearning")
        for name in ("hard", "good", "easy"):
            original = getattr(native, name).normal
            review = (original.relearning.review if original.HasField("relearning")
                      else original.review)
            actual = getattr(queued.states, name).normal.review
            self.assertEqual(actual.memory_state, review.memory_state)
            self.assertEqual(actual.ease_factor, review.ease_factor)
            self.assertEqual(actual.lapses, review.lapses)
        saved = self.answer(queued, CardAnswer.HARD)
        self.assertEqual(saved.ivl, 2)
        self.assertGreater(saved.lapses, 0)


if __name__ == "__main__":
    unittest.main()
