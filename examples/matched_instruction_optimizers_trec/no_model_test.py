#!/usr/bin/env python3
"""No-model regressions for the upstream matched diagnostic boundary."""

from __future__ import annotations

import importlib.util
import copy
import sys
import types
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("matched_upstream", HERE / "run_upstream.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def successful_call(content: str = "malformed", input_tokens: int = 12):
    return {
        "phase": {"seed": 1, "arm": "baseline", "phase": "selection"},
        "role": "task",
        "request_seed": 1,
        "prompt": None,
        "messages": [{"role": "user", "content": "question"}],
        "raw_response": {"response": content, "provider_metadata": {}},
        "response_metadata": {
            "model": "openai/gpt-5.4-mini",
            "provider": "OpenAI",
            "gateway": "openrouter",
            "service_tier": "default",
            "input_tokens": input_tokens,
            "output_tokens": 4,
            "finish_reason": "stop",
            "content": content,
            "gateway_reported_cost": 0.0001,
            "computed_cost": 0.0001,
        },
        "error": None,
        "adapter_transport_dispatch": 1,
        "wall_seconds": 0.01,
    }


class NoModelBoundaryTest(unittest.TestCase):
    def test_operational_abort_bypasses_dspy_exception_fallback(self):
        def dspy_style_fallback():
            try:
                raise MODULE.OperationalSafetyAbort("route drift")
            except Exception:
                return "silently disabled data-aware proposer"

        with self.assertRaisesRegex(MODULE.OperationalSafetyAbort, "route drift"):
            dspy_style_fallback()

    def test_mipro_optimizer_parser_guard_is_arm_scoped_and_fail_closed(self):
        capture = MODULE.Capture()
        capture.set_phase(1, "mipro_v2", "compile")
        with self.assertRaisesRegex(RuntimeError, "exact Chat marker"):
            MODULE.validate_mipro_optimizer_envelope(capture, "optimizer", "malformed")

        MODULE.validate_mipro_optimizer_envelope(
            capture,
            "optimizer",
            "[[ ## observations ## ]]\nuseful summary\n\n[[ ## completed ## ]]\n",
        )
        capture.set_phase(1, "gepa", "compile")
        MODULE.validate_mipro_optimizer_envelope(capture, "optimizer", "malformed")

    def test_catalog_guard_binds_provider_identity_and_exact_route_tag(self):
        expected = {
            "endpoint_provider": "Anthropic",
            "catalog_prompt_per_token": "0.000003",
            "catalog_completion_per_token": "0.000015",
        }
        eligible = MODULE.eligible_endpoints(
            [
                {
                    "provider_name": "Anthropic",
                    "tag": "anthropic/2",
                    "pricing": {"prompt": "0.000003", "completion": "0.000015"},
                    "supported_parameters": ["max_tokens", "temperature"],
                },
                {
                    "provider_name": "Anthropic",
                    "tag": "anthropic",
                    "pricing": {"prompt": "0.000003", "completion": "0.000015"},
                    "supported_parameters": ["max_tokens", "temperature"],
                },
                {
                    "provider_name": "Other",
                    "tag": "default",
                    "pricing": {"prompt": "0", "completion": "0"},
                    "supported_parameters": ["max_tokens", "temperature"],
                },
            ],
            expected,
            "optimizer",
            ["anthropic"],
        )
        self.assertEqual([endpoint["tag"] for endpoint in eligible], ["anthropic"])

    def test_first_response_drift_stops_before_second_dispatch(self):
        dispatches = []

        class FakeLM:
            def __init__(self, *_args, **kwargs):
                self.kwargs = kwargs

            def forward(self, **_kwargs):
                dispatches.append(1)
                return types.SimpleNamespace(
                    model="openai/gpt-5.4-mini",
                    provider="WrongProvider",
                    service_tier="default",
                    usage={"prompt_tokens": 1, "completion_tokens": 1, "cost": 0.0001},
                    choices=[types.SimpleNamespace(
                        finish_reason="stop",
                        message=types.SimpleNamespace(content="ok"),
                    )],
                    _hidden_params={"custom_llm_provider": "openrouter", "response_cost": 0.0001},
                )

        prior = sys.modules.get("dspy")
        sys.modules["dspy"] = types.SimpleNamespace(LM=FakeLM)
        try:
            _dspy, recording_lm = MODULE.install_runtime(
                types.SimpleNamespace(dspy_root=HERE, gepa_root=HERE)
            )
            capture = MODULE.Capture()
            capture.max_input_tokens = {"task": 4096}
            capture.usd_limit = 1.0
            capture.role_usd = {"task": 0.1}
            capture.register_budget(1, "baseline", {
                "task_logical": 2, "optimizer_logical": 0, "total_logical": 2, "transports": 2
            })
            capture.set_phase(1, "baseline", "selection")
            lm = recording_lm(
                "model", capture=capture, role="task", seed=1,
                expected_model={
                    "logical": "openai/gpt-5.4-mini",
                    "upstream": "openrouter/openai/gpt-5.4-mini",
                    "endpoint_provider": "OpenAI",
                    "max_input_tokens": 4096,
                    "max_output_tokens": 256,
                },
            )
            with self.assertRaisesRegex(MODULE.OperationalSafetyAbort, "transport evidence"):
                for _ in range(2):
                    lm.forward(messages=[{"role": "user", "content": "question"}])
            self.assertEqual(len(dispatches), 1)
            self.assertEqual(len(capture.calls), 1)
            self.assertEqual(capture.actual_cost, 0.0001)
        finally:
            if prior is None:
                sys.modules.pop("dspy", None)
            else:
                sys.modules["dspy"] = prior

    def test_usd_reservation_refuses_before_dispatch(self):
        manifest = {
            "seeds": [1, 2, 3],
            "execution": {
                "request": {
                    "task": {"reservation_input_tokens": 10, "max_tokens": 2, "max_input_tokens": 100},
                    "optimizer": {"reservation_input_tokens": 20, "max_tokens": 3, "max_input_tokens": 200},
                },
                "call_ceilings": {
                    "baseline": {"task_logical": 1, "optimizer_logical": 0},
                    "gepa": {"task_logical": 0, "optimizer_logical": 1},
                },
            },
            "models": {
                "task": {"catalog_prompt_per_token": "0.001", "catalog_completion_per_token": "0.01"},
                "optimizer": {"catalog_cache_write_per_token": "0.002", "catalog_completion_per_token": "0.02"},
            },
        }
        capture = MODULE.Capture(manifest)
        self.assertAlmostEqual(capture.usd_limit, 3 * (0.03 + 0.10))
        capture.usd_limit = 0.1
        capture.role_usd = {"task": 0.06}
        capture.register_budget(
            1,
            "baseline",
            {"task_logical": 2, "optimizer_logical": 0, "total_logical": 2, "transports": 2},
        )
        capture.set_phase(1, "baseline", "selection")
        capture.reserve("task")
        with self.assertRaisesRegex(RuntimeError, "USD reservation"):
            capture.reserve("task")
        self.assertEqual(capture.call_budgets["1:baseline"]["counts"]["transports"], 1)

    def test_rendered_input_bound_refuses_before_budget_or_transport(self):
        class FakeLM:
            def __init__(self, *_args, **_kwargs):
                pass

        prior = sys.modules.get("dspy")
        sys.modules["dspy"] = types.SimpleNamespace(LM=FakeLM)
        try:
            _dspy, recording_lm = MODULE.install_runtime(
                types.SimpleNamespace(dspy_root=HERE, gepa_root=HERE)
            )
            capture = MODULE.Capture()
            capture.max_input_tokens = {"task": 4}
            lm = recording_lm("model", capture=capture, role="task")
            with self.assertRaisesRegex(MODULE.OperationalSafetyAbort, "conservative token bound"):
                lm.forward(messages=[{"role": "user", "content": "too large"}])
            self.assertEqual(capture.calls, [])
        finally:
            if prior is None:
                sys.modules.pop("dspy", None)
            else:
                sys.modules["dspy"] = prior

    def test_dspy_lm_copies_keep_one_shared_budget_ledger(self):
        class FakeLM:
            def __init__(self, *_args, **kwargs):
                self.kwargs = kwargs
                self.history = []

        prior = sys.modules.get("dspy")
        sys.modules["dspy"] = types.SimpleNamespace(LM=FakeLM)

        try:
            _dspy, recording_lm = MODULE.install_runtime(
                types.SimpleNamespace(dspy_root=HERE, gepa_root=HERE)
            )
            capture = MODULE.Capture()
            original = recording_lm("model", capture=capture, role="task")
            duplicate = copy.deepcopy(original)
            self.assertIs(duplicate.capture, capture)
            self.assertEqual(duplicate.role, "task")
        finally:
            if prior is None:
                sys.modules.pop("dspy", None)
            else:
                sys.modules["dspy"] = prior

    def test_budget_refuses_before_dispatch_and_retains_the_refusal(self):
        capture = MODULE.Capture()
        capture.register_budget(
            1,
            "baseline",
            {"task_logical": 1, "optimizer_logical": 0, "total_logical": 1, "transports": 1},
        )
        capture.set_phase(1, "baseline", "selection")
        capture.reserve("task")

        with self.assertRaisesRegex(RuntimeError, "before dispatch"):
            capture.reserve("task")

        budget = capture.call_budgets["1:baseline"]
        self.assertEqual(budget["counts"]["transports"], 1)
        self.assertEqual(len(budget["refusals"]), 1)

    def test_typed_parse_failure_is_a_scored_row_error(self):
        capture = MODULE.Capture()

        class MalformedProgram:
            def __call__(self, **_kwargs):
                capture.calls.append(successful_call())
                raise ValueError("typed route decode failed")

        rows = MODULE.evaluate(
            MalformedProgram(),
            [{"id": "row-1", "text": "question", "route": "K11"}],
            None,
            capture,
            {
                "logical": "openai/gpt-5.4-mini",
                "upstream": "openrouter/openai/gpt-5.4-mini",
                "endpoint_provider": "OpenAI",
                "max_input_tokens": 4096,
                "max_output_tokens": 256,
            },
        )

        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0]["correct"])
        self.assertIsNone(rows[0]["parsed_route"])
        self.assertEqual(rows[0]["error"]["type"], "ValueError")
        self.assertEqual(rows[0]["raw_response"]["response"], "malformed")

    def test_reported_input_tokens_cannot_exceed_num_ctx_contract(self):
        with self.assertRaisesRegex(RuntimeError, "transport evidence"):
            MODULE.transport_evidence(
                successful_call(input_tokens=4097),
                {
                    "logical": "openai/gpt-5.4-mini",
                    "upstream": "openrouter/openai/gpt-5.4-mini",
                    "endpoint_provider": "OpenAI",
                    "max_input_tokens": 4096,
                    "max_output_tokens": 256,
                },
            )


if __name__ == "__main__":
    unittest.main()
