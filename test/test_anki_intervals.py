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
                       "days": {"2": 2, "3": 5, "4": 10}}
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
        card = types.SimpleNamespace(id=123, did=1, odid=0, factor=2350, queue=queue)
        card.load = lambda: setattr(card, "factor", 2500)
        card.flush = lambda: setattr(card, "flushed", True)
        return card

    def test_learning_delays_and_ease_survive_graduation(self):
        for queue in (0, 1, 3):
            for ease, days in ((2, 2), (3, 5), (4, 10)):
                with self.subTest(queue=queue, ease=ease):
                    card = self.card(queue)
                    self.assertEqual(self.scheduler.nextIvl(card, ease), days * 86400)
                    self.scheduler.answerCard(card, ease)
                    self.assertEqual(self.scheduler.rescheduled, ([123], days, days))
                    self.assertEqual(card.factor, 2350)
                    self.assertTrue(self.scheduler.reset_called)
        self.assertEqual(self.scheduler.native_calls, 9)

    def test_graduated_reviews_grow_natively(self):
        for ease in (1, 2, 3, 4):
            card = self.card(2)
            self.assertEqual(self.scheduler.nextIvl(card, ease), 25 * 86400)
            self.scheduler.answerCard(card, ease)
        self.assertFalse(hasattr(self.scheduler, "rescheduled"))
        self.assertEqual(self.scheduler.native_calls, 4)

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


if __name__ == "__main__":
    unittest.main()
