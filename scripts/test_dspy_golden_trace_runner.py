"""Provider-free LM contract tests; run under both pinned DSPy environments.

    python -m unittest discover -s scripts -p 'test_dspy_golden_trace_runner.py'
"""

import json
import unittest
from pathlib import Path

import dspy_golden_trace_runner as runner


FIXTURES = Path(__file__).resolve().parents[1] / "test/fixtures/golden_trace/cases.json"


class FixtureLMTest(unittest.TestCase):
    def test_capability_tiers(self):
        tiers = {
            None: (set(), False),
            "none": (set(), False),
            "response_format": ({"response_format"}, False),
            "json_object": ({"response_format"}, False),
            "json_schema": ({"response_format"}, True),
            "response_schema": ({"response_format"}, True),
        }
        self.assertEqual(set(runner._CAPABILITY_TIERS), set(tiers))
        for tier, (params, schema) in tiers.items():
            with self.subTest(tier=tier):
                lm = runner.FixtureLM([], tier)
                self.assertEqual(lm.supported_params, params)
                self.assertEqual(lm.supports_response_schema, schema)
                # Callers cannot mutate the fixture's tier through this set.
                lm.supported_params.add("not_a_fixture_capability")
                self.assertEqual(lm.supported_params, params)
                if runner._ENGINE_BASED_LM:
                    from dspy.clients.capabilities import capabilities

                    self.assertIs(lm.engine.responses, lm.responses)
                    hints = capabilities(lm)
                    self.assertEqual(hints.params, frozenset(params))
                    self.assertEqual(hints.response_schema, schema)
                    self.assertFalse(hints.function_calling)
                    self.assertFalse(hints.reasoning)
        with self.assertRaisesRegex(ValueError, "unknown lm_capability tier"):
            runner.FixtureLM([], "unknown")

    def test_queue_and_history(self):
        supplied = ["first", "second"]
        lm = runner.FixtureLM(supplied, "json_object")
        # Same prompt twice still consumes two entries: fixture caching is off.
        for output in supplied:
            self.assertEqual(lm("same prompt", response_format={"type": "json_object"}), [output])
        self.assertEqual(supplied, ["first", "second"])
        self.assertEqual(lm.responses, [])
        history = runner.normalize_history(lm.history)
        self.assertEqual(len(history), 2)
        for entry, output in zip(history, supplied):
            self.assertEqual(set(entry), {"messages", "kwargs", "outputs", "model", "model_type"})
            # Legacy BaseLM records a string call as prompt (not messages).
            messages = [{"role": "user", "content": "same prompt"}] if runner._ENGINE_BASED_LM else None
            self.assertEqual(entry["messages"], messages)
            self.assertEqual(entry["kwargs"], {"response_format": {"type": "json_object"}})
            self.assertEqual(entry["outputs"], [output])
            self.assertEqual(entry["model"], "fake/golden")
            self.assertEqual(entry["model_type"], "chat")
        # The one-attempt boundary raises the same exception on either API.
        with self.assertRaisesRegex(RuntimeError, "^fixture response queue exhausted$"):
            if runner._ENGINE_BASED_LM:
                lm.engine.complete(None)
            else:
                lm.forward()
        self.assertEqual(runner.normalize_history(lm.history), history)

    @unittest.skipUnless(runner._ENGINE_BASED_LM, "DSPy has no Engine API")
    def test_engine_protocol(self):
        from dspy.clients.engines.base import validate_engines
        from dspy.lm15 import Message, Request, Response, TextPart, Usage

        lm = runner.FixtureLM(["raw fixture text"])
        validate_engines(lm.engine, None)
        request = Request(model=lm.model, messages=(Message(role="user", parts=(TextPart(text="input"),)),))
        response = lm.engine.complete(request)
        self.assertIsInstance(response, Response)
        self.assertEqual(response.model, request.model)
        self.assertEqual(response.message, Message(role="assistant", parts=(TextPart(text="raw fixture text"),)))
        self.assertEqual(response.finish_reason, "stop")
        self.assertEqual(response.usage, Usage())
        self.assertEqual(lm.responses, [])
        # Only BaseLM records history, never the engine itself.
        self.assertEqual(lm.history, [])
        with self.assertRaisesRegex(RuntimeError, "^fixture response queue exhausted$"):
            lm.engine.complete(request)

    def test_all_cases_measure_real_outcomes(self):
        cases = json.loads(FIXTURES.read_text())
        results = {case["id"]: runner.run_case(case) for case in cases}
        self.assertEqual(len(results), 42)
        expected_errors = {"react_tool_argument_error", "missing_output_error", "xml_missing_output_error"}
        if runner._ENGINE_BASED_LM:
            # These are measured upstream semantic changes, not LM port failures.
            expected_errors |= {
                "chain_of_thought_basic", "react_tool_lookup", "react_multi_tool_transform",
                "react_dspy_tool_lookup", "h7nw_react_float_observation",
                "h7nw_react_bool_observation", "h7nw_react_nil_observation",
                "cidk_chain_of_thought_json",
            }
        self.assertEqual({key for key, value in results.items() if value["status"] == "error"}, expected_errors)
        for result in results.values():
            with self.subTest(case=result["id"]):
                self.assertNotIn("LMUnsupportedFeatureError", result["error"] or "")
                self.assertTrue(result["history"])
                self.assertEqual(result["remaining_responses"], 0)
        for key in ("two_step_basic", "two_step_typed"):
            self.assertEqual(results[key]["status"], "ok")
            self.assertEqual(len(results[key]["history"]), 2)
        # Histories/envelopes remain JSON-serializable, including schema tiers.
        json.dumps(results)


if __name__ == "__main__":
    unittest.main()
