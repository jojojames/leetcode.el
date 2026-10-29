"""Check learning overrides and native review delegation without live Anki."""

import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch


class IntervalTests(unittest.TestCase):
    def setUp(self):
        class Scheduler:
            def nextIvl(self, card, ease):
                return 25 * 86400  # A mature native interval, not 2/5/10 days.

            def answerCard(self, card, ease):
                self.native_calls += 1
                card.queue = 2

            def reschedCards(self, ids, low, high):
                self.rescheduled = (ids, low, high)

            def reset(self):
                self.reset_called = True

        self.scheduler = Scheduler()
        self.scheduler.native_calls = 0
        self.deck = "LeetCode::NeetCode150::1-D DP"
        self.scheduler.col = types.SimpleNamespace(
            decks=types.SimpleNamespace(get=lambda _: {"name": self.deck}))
        self.config = {"deck": "LeetCode::NeetCode150",
                       "days": {"2": 3, "3": 4, "4": 5}}
        manager = types.SimpleNamespace(getConfig=lambda _: self.config)
        modules = {
            "aqt": types.SimpleNamespace(mw=types.SimpleNamespace(addonManager=manager)),
            "anki": types.SimpleNamespace(schedv2=types.SimpleNamespace(Scheduler=Scheduler)),
        }
        path = Path(__file__).resolve().parents[1] / "anki/leetcode_intervals/__init__.py"
        spec = importlib.util.spec_from_file_location("leetcode_intervals", path)
        self.addon = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules):
            spec.loader.exec_module(self.addon)

    @staticmethod
    def card(queue):
        card = types.SimpleNamespace(id=123, did=1, odid=0, factor=2350, queue=queue, type=2 if queue == 2 else 0, ivl=5)
        card.load = lambda: setattr(card, "factor", 2500)
        card.flush = lambda: setattr(card, "flushed", True)
        return card

    def test_learning_delays_and_ease_survive_graduation(self):
        for queue in (0, 1, 3):
            for ease, days in ((2, 3), (3, 4), (4, 5)):
                with self.subTest(queue=queue, ease=ease):
                    card = self.card(queue)
                    self.assertEqual(self.scheduler.nextIvl(card, ease), days * 86400)
                    self.scheduler.answerCard(card, ease)
                    self.assertEqual(self.scheduler.rescheduled, ([123], days, days))
                    self.assertEqual(card.factor, 2350)
                    self.assertTrue(self.scheduler.reset_called)
        self.assertEqual(self.scheduler.native_calls, 9)

    def test_graduated_reviews_follow_ladder(self):
        for ease, days in ((2, 5), (3, 7), (4, 10)):
            card = self.card(2)
            self.assertEqual(self.scheduler.nextIvl(card, ease), days * 86400)
            self.scheduler.answerCard(card, ease)
            self.assertEqual(self.scheduler.rescheduled, ([123], days, days))

    def test_cap_off_ladder_and_relearning(self):
        for interval, expected in ((100, [100, 100, 100]),
                                   (13, [13, 14, 18]),
                                   (150, [100, 100, 100])):
            card = self.card(2)
            card.ivl = interval
            self.assertEqual([self.addon.interval_days(self.scheduler, card, e)
                              for e in (2, 3, 4)], expected)
        card = self.card(1)
        card.type = 3
        self.assertEqual([self.addon.interval_days(self.scheduler, card, e)
                          for e in (2, 3, 4)], [3, 3, 3])

    def test_invalid_ladder_rejected_before_rating(self):
        for ladder in ([], [3, 3], [5, 3], [0, 3], [3, True]):
            self.config['intervals'] = ladder
            with self.assertRaises(ValueError):
                self.scheduler.answerCard(self.card(2), 3)
        self.assertEqual(self.scheduler.native_calls, 0)

    def test_empty_days_disables_ladder(self):
        self.config['days'] = {}
        self.assertIsNone(self.addon.interval_days(self.scheduler, self.card(2), 3))

    def test_again_other_decks_and_filtered_decks_stay_native(self):
        card = self.card(1)
        self.assertIsNone(self.addon.interval_days(self.scheduler, card, 1))
        self.deck = "LeetCode::NeetCode1500"
        self.assertIsNone(self.addon.interval_days(self.scheduler, card, 3))
        self.deck = "LeetCode::NeetCode150::1-D DP"
        card.odid = 1
        self.assertIsNone(self.addon.interval_days(self.scheduler, card, 3))

    def test_invalid_interval_is_rejected_before_rating(self):
        self.config["days"]["3"] = 0
        with self.assertRaises(ValueError):
            self.scheduler.answerCard(self.card(0), 3)
        self.assertEqual(self.scheduler.native_calls, 0)

    def test_force_next_uses_native_daily_extension(self):
        calls = []
        ready = [False]
        scheduler = types.SimpleNamespace(
            reset=lambda: calls.append("reset"),
            totalNewForCurrentDeck=lambda: 149,
            extendLimits=lambda new, review: calls.append((new, review)))
        collection = types.SimpleNamespace(decks=types.SimpleNamespace(
            byName=lambda _: {"name": self.deck},
            current=lambda: {"name": self.deck}))

        def review(deck):
            calls.append(("review", deck))
            if (1, 0) in calls:
                ready[0] = True
            return True

        api = types.SimpleNamespace(
            collection=lambda: collection, scheduler=lambda: scheduler,
            guiReviewActive=lambda: ready[0], guiDeckReview=review)
        self.assertTrue(self.addon.extend_new_cards(api, self.deck))
        self.assertEqual(calls.count((1, 0)), 1)
        self.assertTrue(ready[0])
        # Repeating the request with a ready card does not extend again.
        self.assertTrue(self.addon.extend_new_cards(api, self.deck))
        self.assertEqual(calls.count((1, 0)), 1)

    def test_force_next_empty_deck_never_extends_or_ratings(self):
        scheduler = types.SimpleNamespace(
            reset=lambda: None, totalNewForCurrentDeck=lambda: 0)
        api = types.SimpleNamespace(
            collection=lambda: types.SimpleNamespace(decks=types.SimpleNamespace(
                byName=lambda _: {"name": self.deck})),
            scheduler=lambda: scheduler,
            guiReviewActive=lambda: False, guiDeckReview=lambda _: True)
        self.assertFalse(self.addon.extend_new_cards(api, self.deck))
        with self.assertRaises(ValueError):
            self.addon.extend_new_cards(api, self.deck, 0)


if __name__ == "__main__":
    unittest.main()
