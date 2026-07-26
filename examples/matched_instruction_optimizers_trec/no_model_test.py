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
        "prompt": None,
        "messages": [{"role": "user", "content": "question"}],
        "raw_response": {"response": content, "provider_metadata": {}},
        "response_metadata": {
            "model": "llama3.2:3b",
            "provider": "ollama",
            "input_tokens": input_tokens,
            "output_tokens": 4,
            "finish_reason": "stop",
            "content": content,
            "provider_cost": None,
        },
        "error": None,
        "adapter_transport_dispatch": 1,
        "wall_seconds": 0.01,
    }


class NoModelBoundaryTest(unittest.TestCase):
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
            {"upstream": "ollama/llama3.2:3b", "max_input_tokens": 4096},
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
                {"upstream": "ollama/llama3.2:3b", "max_input_tokens": 4096},
            )


if __name__ == "__main__":
    unittest.main()
