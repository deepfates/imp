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
    def __init__(self, usage=None, error=None):
        self.kwargs = {"max_completion_tokens": 32_768}
        self.history = []
        self.dispatched = None
        self.usage = usage or {
            "input_tokens": 12,
            "output_tokens": 34,
            "total_cost": 0.25,
        }
        self.error = error

    def __call__(self, _prompt, **kwargs):
        self.dispatched = kwargs
        self.history.append({"usage": self.usage})
        if self.error is not None:
            raise self.error
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


class RacingHistoryLM:
    def __init__(self):
        self.kwargs = {"max_completion_tokens": 100}
        self.history = []
        self.first_started = threading.Event()
        self.second_recorded = threading.Event()
        self.state_lock = threading.Lock()
        self.active = 0
        self.max_active = 0

    def __call__(self, prompt, **_kwargs):
        with self.state_lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        try:
            if prompt == "first":
                self.history.append(
                    {"usage": {"input_tokens": 11, "output_tokens": 1}}
                )
                self.first_started.set()
                self.second_recorded.wait(timeout=0.2)
            else:
                self.first_started.wait(timeout=1)
                self.history.append(
                    {"usage": {"input_tokens": 22, "output_tokens": 2}}
                )
                self.second_recorded.set()
            return [prompt]
        finally:
            with self.state_lock:
                self.active -= 1


def empty_ledger():
    return {
        "requests": 0,
        "root_calls": 0,
        "sub_calls": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "usd": 0.0,
    }


def wrapped(
    inner,
    ledger=None,
    limits=None,
    pricing=None,
    role="root",
    lock=None,
    max_tokens=32_768,
):
    return campaign.BudgetLM(
        inner,
        ledger or empty_ledger(),
        limits
        or {"requests": 4, "input_tokens": 10_000, "output_tokens": 1_000, "usd": 10.0},
        pricing or {"input_per_million": 1.0, "output_per_million": 1.0},
        configured_max_tokens=max_tokens,
        role=role,
        lock=lock or threading.Lock(),
    )


class BudgetLMTest(unittest.TestCase):
    def test_gpt5_limit_and_provider_reported_cost_are_audited(self):
        inner = FakeReasoningLM()
        ledger = empty_ledger()
        lm = wrapped(
            inner,
            ledger=ledger,
            limits={"requests": 2, "input_tokens": 10_000, "output_tokens": 100, "usd": 10.0},
        )

        self.assertEqual(lm("hello"), ["ok"])
        self.assertEqual(inner.dispatched["max_completion_tokens"], 100)
        self.assertNotIn("max_tokens", inner.dispatched)
        self.assertFalse(inner.dispatched["cache"])
        usage = campaign.auditable_usage(ledger)
        self.assertEqual(usage["requests"], 1)
        self.assertEqual(usage["output_tokens"], 34)
        self.assertEqual(usage["usd"], 0.25)
        self.assertEqual(usage["cost_authority"], "provider_reported")
        self.assertEqual(usage["cost_audit"][0]["provider_reported_usd"], 0.25)
        self.assertEqual(
            usage["cost_rates"],
            {"input_per_million": 1.0, "output_per_million": 1.0},
        )

    def test_input_only_provider_error_retains_charged_dimension_and_counts(self):
        inner = FakeReasoningLM(
            {"input_tokens": 40, "output_tokens": 0, "total_cost": 0.0},
            error=RuntimeError("rate limited"),
        )
        ledger = empty_ledger()
        lm = wrapped(
            inner,
            ledger=ledger,
            pricing={"input_per_million": 2.0, "output_per_million": 3.0},
        )

        with self.assertRaisesRegex(campaign.CampaignError, "failed after charging") as raised:
            lm("hello")

        usage = raised.exception.usage
        self.assertEqual(usage["requests"], 1)
        self.assertEqual(usage["root_calls"], 1)
        self.assertEqual(usage["sub_calls"], 0)
        self.assertEqual(usage["input_tokens"], 40)
        self.assertEqual(usage["output_tokens"], 0)
        self.assertAlmostEqual(usage["usd"], 0.00008)
        self.assertEqual(usage["cost_authority"], "pricing_derived")

    def test_output_only_success_is_rejected_after_retaining_observed_usage(self):
        inner = FakeReasoningLM({"input_tokens": 0, "output_tokens": 7})
        lm = wrapped(inner)

        with self.assertRaisesRegex(campaign.CampaignError, "provider usage missing") as raised:
            lm("hello")

        self.assertEqual(raised.exception.usage["requests"], 1)
        self.assertEqual(raised.exception.usage["input_tokens"], 0)
        self.assertEqual(raised.exception.usage["output_tokens"], 7)
        self.assertEqual(raised.exception.usage["cost_authority"], "pricing_derived")

    def test_zero_usage_retains_counts_but_has_unavailable_cost(self):
        inner = FakeReasoningLM(
            {"input_tokens": 0, "output_tokens": 0, "total_cost": 0.0}
        )
        lm = wrapped(inner)

        with self.assertRaisesRegex(campaign.CampaignError, "explicit free authority") as raised:
            lm("hello")

        usage = raised.exception.usage
        self.assertEqual(usage["requests"], 1)
        self.assertEqual(usage["root_calls"], 1)
        self.assertEqual(usage["input_tokens"], 0)
        self.assertEqual(usage["output_tokens"], 0)
        self.assertEqual(usage["usd"], 0.0)
        self.assertEqual(usage["cost_authority"], "unavailable")

    def test_missing_cost_is_derived_from_exact_pinned_rates(self):
        inner = FakeReasoningLM({"input_tokens": 12, "output_tokens": 34})
        ledger = empty_ledger()
        lm = wrapped(
            inner,
            ledger=ledger,
            pricing={"input_per_million": 2.0, "output_per_million": 3.0},
        )

        self.assertEqual(lm("hello"), ["ok"])
        usage = campaign.auditable_usage(ledger)
        self.assertAlmostEqual(usage["usd"], 0.000126)
        self.assertEqual(usage["cost_authority"], "pricing_derived")
        self.assertEqual(
            usage["cost_audit"][0]["rates"],
            {"input_per_million": 2.0, "output_per_million": 3.0},
        )
        self.assertIsNone(usage["cost_audit"][0]["provider_reported_usd"])

    def test_explicit_provider_free_authority_allows_zero_cost(self):
        inner = FakeReasoningLM(
            {
                "input_tokens": 12,
                "output_tokens": 34,
                "total_cost": 0.0,
                "cost_authority": "free",
            }
        )
        ledger = empty_ledger()
        lm = wrapped(inner, ledger=ledger)

        self.assertEqual(lm("hello"), ["ok"])
        usage = campaign.auditable_usage(ledger)
        self.assertEqual(usage["usd"], 0.0)
        self.assertEqual(usage["cost_authority"], "free")

    def test_invalid_provider_cost_is_rejected_after_token_retention(self):
        inner = FakeReasoningLM(
            {"input_tokens": 12, "output_tokens": 34, "total_cost": -0.1}
        )
        lm = wrapped(inner)

        with self.assertRaisesRegex(campaign.CampaignError, "invalid provider total_cost") as raised:
            lm("hello")

        self.assertEqual(raised.exception.usage["input_tokens"], 12)
        self.assertEqual(raised.exception.usage["output_tokens"], 34)
        self.assertEqual(raised.exception.usage["cost_authority"], "unavailable")

    def test_conflicting_zero_and_positive_provider_cost_aliases_are_rejected(self):
        inner = FakeReasoningLM(
            {
                "input_tokens": 12,
                "output_tokens": 34,
                "total_cost": 0.0,
                "cost": 0.25,
            }
        )
        lm = wrapped(inner)

        with self.assertRaisesRegex(campaign.CampaignError, "inconsistent provider cost") as raised:
            lm("hello")

        self.assertEqual(raised.exception.usage["input_tokens"], 12)
        self.assertEqual(raised.exception.usage["output_tokens"], 34)
        self.assertEqual(raised.exception.usage["cost_authority"], "unavailable")

    def test_active_reservations_prevent_cross_lm_overcommit(self):
        blocking = BlockingReasoningLM()
        ledger = empty_ledger()
        lock = threading.Lock()
        limits = {"requests": 2, "input_tokens": 10_000, "output_tokens": 100, "usd": 10.0}
        first_lm = wrapped(
            blocking,
            ledger=ledger,
            limits=limits,
            lock=lock,
            max_tokens=100,
        )
        second_lm = wrapped(
            FakeReasoningLM(),
            ledger=ledger,
            limits=limits,
            role="sub",
            lock=lock,
            max_tokens=100,
        )
        first = threading.Thread(target=first_lm, args=("first",))
        first.start()
        self.assertTrue(blocking.started.wait(timeout=1))

        with self.assertRaisesRegex(campaign.CampaignError, "output-token ceiling"):
            second_lm("second")

        blocking.release.set()
        first.join(timeout=2)
        self.assertFalse(first.is_alive())

    def test_concurrent_calls_capture_their_own_history_entry(self):
        inner = RacingHistoryLM()
        ledger = empty_ledger()
        lm = wrapped(inner, ledger=ledger, max_tokens=100)
        results = []
        errors = []

        def invoke(prompt):
            try:
                results.append(lm(prompt))
            except BaseException as error:
                errors.append(error)

        first = threading.Thread(target=invoke, args=("first",))
        second = threading.Thread(target=invoke, args=("second",))
        first.start()
        self.assertTrue(inner.first_started.wait(timeout=1))
        second.start()
        first.join(timeout=2)
        second.join(timeout=2)

        self.assertEqual(errors, [])
        self.assertCountEqual(results, [["first"], ["second"]])
        self.assertEqual(inner.max_active, 1)
        usage = campaign.auditable_usage(ledger)
        self.assertEqual(usage["input_tokens"], 33)
        self.assertEqual(usage["output_tokens"], 3)
        self.assertEqual(
            [(audit["input_tokens"], audit["output_tokens"]) for audit in usage["cost_audit"]],
            [(11, 1), (22, 2)],
        )

    def test_observed_overage_is_retained_and_blocks_resumed_dispatch(self):
        inner = FakeReasoningLM(
            {"input_tokens": 2, "output_tokens": 12, "total_cost": 0.1}
        )
        limits = {"requests": 2, "input_tokens": 10_000, "output_tokens": 10, "usd": 10.0}
        lm = wrapped(inner, limits=limits, max_tokens=10)

        with self.assertRaisesRegex(campaign.CampaignError, "observed output_tokens") as raised:
            lm("hello")

        retained = raised.exception.usage
        self.assertEqual(retained["requests"], 1)
        self.assertEqual(retained["output_tokens"], 12)
        resumed_inner = FakeReasoningLM()
        resumed = wrapped(
            resumed_inner,
            ledger=dict(retained),
            limits=limits,
            max_tokens=10,
        )
        with self.assertRaisesRegex(campaign.CampaignError, "output-token ceiling") as resumed_error:
            resumed("again")
        self.assertEqual(resumed_error.exception.usage["requests"], 1)
        self.assertEqual(resumed_error.exception.usage["output_tokens"], 12)
        self.assertEqual(resumed_inner.history, [])


if __name__ == "__main__":
    unittest.main()
