"""Runs DSPy's JSONAdapter.parse on single-quoted completions.

Reads a JSON list of string bodies on stdin. For each body, parses
`{'answer': '<body>'}` for a signature with one string output and prints, in
order, `{"codepoints": [...]}` for the parsed answer or `{"error": "<type>"}`.
Code points rather than a string, because json_repair can put lone UTF-16
surrogates into a Python string, and JSON text cannot carry those intact.
"""

import importlib.metadata
import json
import sys
import warnings

warnings.filterwarnings("ignore")

import dspy  # noqa: E402
from dspy.adapters.json_adapter import JSONAdapter  # noqa: E402


class Sig(dspy.Signature):
    question: str = dspy.InputField()
    answer: str = dspy.OutputField()


rows = []
for body in json.load(sys.stdin):
    try:
        parsed = JSONAdapter().parse(Sig, "{'answer': '" + body + "'}")
        rows.append({"codepoints": [ord(c) for c in parsed["answer"]]})
    except Exception as error:  # noqa: BLE001 - the error class is the result
        rows.append({"error": type(error).__name__})

print(
    json.dumps(
        {
            "dspy_version": dspy.__version__,
            "json_repair_version": importlib.metadata.version("json_repair"),
            "rows": rows,
        }
    )
)
