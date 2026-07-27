#!/usr/bin/env python3
"""Render the pinned DSPy 3.2.1 IFBench task messages without an LM."""

import json

import dspy


class GenerateResponse(dspy.Signature):
    """Respond to the query"""

    query = dspy.InputField()
    response = dspy.OutputField()


class EnsureCorrectResponse(dspy.Signature):
    """Ensure the response is correct and adheres to the given constraints. Your response will be used as the final response."""

    query = dspy.InputField()
    response = dspy.InputField()
    final_response = dspy.OutputField()


adapter = dspy.ChatAdapter()
probe = "Write exactly BLUE."
messages = [
    adapter.format(
        dspy.ChainOfThought(GenerateResponse).predict.signature,
        demos=[],
        inputs={"query": probe},
    ),
    adapter.format(
        dspy.ChainOfThought(EnsureCorrectResponse).predict.signature,
        demos=[],
        inputs={"query": probe, "response": "BLUE"},
    ),
]
print(json.dumps(messages, sort_keys=True, separators=(",", ":")))
