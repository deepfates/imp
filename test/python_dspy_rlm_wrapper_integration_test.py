import importlib.util
import pathlib
import threading
import types
import unittest

import dspy


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "dspy_rlm_campaign.py"
SPEC = importlib.util.spec_from_file_location("dspy_rlm_campaign_integration", SCRIPT)
campaign = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(campaign)


class QueueLM(dspy.BaseLM):
    def __init__(self, responses):
        super().__init__(model="deterministic/controller", cache=False)
        self.responses = list(responses)

    def forward(self, prompt=None, messages=None, **kwargs):
        del prompt, messages, kwargs
        content = self.responses.pop(0)
        return types.SimpleNamespace(
            choices=[types.SimpleNamespace(message=types.SimpleNamespace(content=content))],
            usage={"input_tokens": 12, "output_tokens": 8, "total_cost": 0.0001},
            model=self.model,
            _hidden_params={},
        )


class SubmitInterpreter:
    def __init__(self):
        self.tools = {}
        self.output_fields = []
        self.executions = []

    def start(self):
        return None

    def shutdown(self):
        return None

    def execute(self, code, variables=None):
        del variables
        self.executions.append(code)
        return dspy.FinalOutput({"answer": "wrapped-ok"})


class BudgetLMRLMIntegrationTest(unittest.TestCase):
    def test_budget_wrapper_is_transparent_to_real_dspy_rlm(self):
        response = (
            "[[ ## reasoning ## ]]\nSubmit the deterministic answer.\n"
            "[[ ## code ## ]]\n```python\nSUBMIT(answer='wrapped-ok')\n```"
        )
        ledger = {
            "requests": 0,
            "root_calls": 0,
            "sub_calls": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "usd": 0.0,
        }
        root = campaign.BudgetLM(
            QueueLM([response]),
            ledger,
            {"requests": 2, "input_tokens": 1000, "output_tokens": 1000, "usd": 1.0},
            {"input_per_million": 1.0, "output_per_million": 1.0},
            configured_max_tokens=100,
            role="root",
            lock=threading.Lock(),
        )
        interpreter = SubmitInterpreter()
        dspy.configure(lm=root, adapter=dspy.ChatAdapter())

        program = dspy.RLM(
            "context, question -> answer",
            max_iters=1,
            max_llm_calls=0,
        )
        prediction = program(
            interpreter,
            context="public context",
            question="return the fixture answer",
        )

        self.assertEqual(prediction.answer, "wrapped-ok")
        self.assertEqual(len(prediction.trajectory), 1)
        self.assertEqual(ledger["requests"], 1)
        self.assertEqual(ledger["root_calls"], 1)
        self.assertEqual(ledger["input_tokens"], 12)
        self.assertEqual(ledger["output_tokens"], 8)
        self.assertEqual(len(interpreter.executions), 1)


if __name__ == "__main__":
    unittest.main()
