import importlib.util
import pathlib
import sys
import threading
import types
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "dspy_rlm_campaign.py"
sys.modules.setdefault("dspy", types.SimpleNamespace())
SPEC = importlib.util.spec_from_file_location("dspy_rlm_campaign", SCRIPT)
campaign = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(campaign)


class FakeReasoningLM:
    def __init__(self):
        self.kwargs = {"max_completion_tokens": 32_768}
        self.history = []
        self.dispatched = None

    def __call__(self, _prompt, **kwargs):
        self.dispatched = kwargs
        self.history.append(
            {
                "usage": {
                    "input_tokens": 12,
                    "output_tokens": 34,
                    "total_cost": 0.25,
                }
            }
        )
        return ["ok"]


class BlockingReasoningLM(FakeReasoningLM):
    def __init__(self):
        super().__init__()
        self.started = threading.Event()
        self.release = threading.Event()

    def __call__(self, prompt, **kwargs):
        self.started.set()
        self.release.wait(timeout=2)
        return super().__call__(prompt, **kwargs)


class BudgetLMTest(unittest.TestCase):
    def test_gpt5_limit_reaches_provider_as_max_completion_tokens(self):
        inner = FakeReasoningLM()
        ledger = {
            "requests": 0,
            "root_calls": 0,
            "sub_calls": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "usd": 0.0,
        }
        wrapped = campaign.BudgetLM(
            inner,
            ledger,
            {"requests": 2, "input_tokens": 10_000, "output_tokens": 100, "usd": 10.0},
            {"input_per_million": 1.0, "output_per_million": 1.0},
            configured_max_tokens=32_768,
            role="root",
            lock=threading.Lock(),
        )

        self.assertEqual(wrapped("hello"), ["ok"])
        self.assertEqual(inner.dispatched["max_completion_tokens"], 100)
        self.assertNotIn("max_tokens", inner.dispatched)
        self.assertFalse(inner.dispatched["cache"])
        self.assertEqual(ledger["requests"], 1)
        self.assertEqual(ledger["output_tokens"], 34)

    def test_active_output_reservations_prevent_concurrent_overcommit(self):
        inner = BlockingReasoningLM()
        ledger = {
            "requests": 0,
            "root_calls": 0,
            "sub_calls": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "usd": 0.0,
        }
        wrapped = campaign.BudgetLM(
            inner,
            ledger,
            {"requests": 2, "input_tokens": 10_000, "output_tokens": 100, "usd": 10.0},
            {"input_per_million": 1.0, "output_per_million": 1.0},
            configured_max_tokens=100,
            role="root",
            lock=threading.Lock(),
        )
        first = threading.Thread(target=wrapped, args=("first",))
        first.start()
        self.assertTrue(inner.started.wait(timeout=1))

        with self.assertRaisesRegex(campaign.CampaignError, "output-token ceiling"):
            wrapped("second")

        inner.release.set()
        first.join(timeout=2)
        self.assertFalse(first.is_alive())


if __name__ == "__main__":
    unittest.main()
