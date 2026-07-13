#!/usr/bin/env python3
"""Run provider-free operational contracts against the installed DSPy RLM."""

from __future__ import annotations

import argparse
import hashlib
import inspect
import json
import platform
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import dspy


SCOPE_NOTE = (
    "Provider-free operational semantics only; this is not long-context "
    "effectiveness evidence or a paper reproduction."
)


@dataclass
class FakeResponse:
    choices: list[Any]
    usage: dict[str, Any]
    model: str
    _hidden_params: dict[str, Any]


class QueueLM(dspy.BaseLM):
    """Deterministic controller LM whose turns are trusted fixture programs."""

    def __init__(self, responses: list[str]) -> None:
        super().__init__(model="deterministic/rlm-controller", cache=False)
        self.responses = list(responses)
        self._queue_lock = threading.Lock()

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001, ARG002
        with self._queue_lock:
            if not self.responses:
                raise RuntimeError("controller response queue exhausted")
            content = self.responses.pop(0)
        return _fake_response(content, self.model)


class DeterministicSubLM(dspy.BaseLM):
    """Prompt-keyed callback LM, safe under batched concurrent invocation."""

    def __init__(self, responses: dict[str, str], delays_ms: dict[str, int] | None = None) -> None:
        super().__init__(model="deterministic/rlm-sub", cache=False)
        self.responses = responses
        self.delays_ms = delays_ms or {}
        self.calls: list[str] = []
        self._calls_lock = threading.Lock()

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001, ARG002
        key = prompt if prompt is not None else _last_message(messages)
        if not isinstance(key, str):
            raise RuntimeError(f"sub-LM prompt is not a string: {key!r}")
        with self._calls_lock:
            self.calls.append(key)
        time.sleep(self.delays_ms.get(key, 0) / 1000)
        if key not in self.responses:
            raise RuntimeError(f"no deterministic subresponse for prompt {key!r}")
        return _fake_response(self.responses[key], self.model)


class StringAnswerSignature(dspy.Signature):
    context: Any = dspy.InputField()
    query: str = dspy.InputField()
    answer: str = dspy.OutputField()


class IntegerAnswerSignature(dspy.Signature):
    context: Any = dspy.InputField()
    query: str = dspy.InputField()
    answer: int = dspy.OutputField()


class IntegerListAnswerSignature(dspy.Signature):
    context: Any = dspy.InputField()
    query: str = dspy.InputField()
    answer: list[int] = dspy.OutputField()


def _fake_response(content: str, model: str) -> FakeResponse:
    return FakeResponse(
        choices=[SimpleNamespace(message=SimpleNamespace(content=content))],
        usage={},
        model=model,
        _hidden_params={},
    )


def _last_message(messages: Any) -> Any:
    if isinstance(messages, list) and messages:
        item = messages[-1]
        if isinstance(item, dict):
            return item.get("content")
    return None


def action_response(index: int, code: str) -> str:
    return (
        f"[[ ## reasoning ## ]]\nExecute trusted fixture turn {index}.\n"
        f"[[ ## code ## ]]\n```python\n{code}\n```"
    )


def extract_response(value: Any) -> str:
    rendered = json.dumps(value) if not isinstance(value, str) else value
    return f"[[ ## answer ## ]]\n{rendered}"


def signature_for(case: dict[str, Any]) -> type[dspy.Signature]:
    output_type = case.get("output_type")
    expected = case["expected"]["output"]
    if output_type == "list[int]":
        return IntegerListAnswerSignature
    if isinstance(expected, int) and not isinstance(expected, bool):
        return IntegerAnswerSignature
    return StringAnswerSignature


def normalize_trace(prediction: Any) -> dict[str, Any]:
    trajectory = prediction.toDict().get("trajectory", [])
    entries = [
        {
            "reasoning": str(entry.get("reasoning", "")),
            "code": str(entry.get("code", "")),
            "output": str(entry.get("output", "")),
            "attempted_status": attempted_status(str(entry.get("output", ""))),
        }
        for entry in trajectory
    ]
    return {
        "entries": entries,
        "entry_count": len(entries),
        "final_reasoning": getattr(prediction, "final_reasoning", None),
    }


def attempted_status(output: str) -> str:
    if output.startswith("FINAL:"):
        return "submitted"
    if "Error" in output or "error" in output:
        return "error"
    return "continued"


def gate_trace(actual: dict[str, Any], expected: dict[str, Any]) -> list[str]:
    failures = []
    if actual["entry_count"] != expected["entries"]:
        failures.append(f"trace entries: expected {expected['entries']}, got {actual['entry_count']}")
    actual_codes = [entry["code"] for entry in actual["entries"]]
    if "codes" in expected and actual_codes != expected["codes"]:
        failures.append(f"trace codes: expected {expected['codes']!r}, got {actual_codes!r}")
    all_output = "\n".join(entry["output"] for entry in actual["entries"])
    for fragment in expected.get("output_contains", []):
        if fragment not in all_output:
            failures.append(f"trace output missing {fragment!r}")
    if "final_reasoning" in expected and actual["final_reasoning"] != expected["final_reasoning"]:
        failures.append(
            f"final reasoning: expected {expected['final_reasoning']!r}, got {actual['final_reasoning']!r}"
        )
    return failures


def run_case(case: dict[str, Any]) -> dict[str, Any]:
    expected = case["expected"]
    base = {
        "id": case["id"],
        "invariant": case["invariant"],
        "disposition": case["disposition"],
        "required": case.get("required", False),
        "expected": expected,
        "errors": [],
    }
    if case["disposition"] == "deviation":
        return {
            **base,
            "executed": False,
            "passing": True,
            "attempted_status": "supported_deviation",
            "status": "supported_deviation",
            "output": None,
            "subcalls": 0,
            "trace": {"entries": [], "entry_count": 0, "final_reasoning": None},
            "deviation": case["deviation"],
        }

    responses = [action_response(i + 1, code) for i, code in enumerate(case["python_controller_code_turns"])]
    if "extract_output" in case:
        responses.append(extract_response(case["extract_output"]))
    controller = QueueLM(responses)
    sub_lm = DeterministicSubLM(case["subresponses"], case.get("subresponse_delays_ms"))
    dspy.configure(lm=controller, adapter=dspy.ChatAdapter())

    try:
        rlm_parameters = inspect.signature(dspy.RLM.__init__).parameters
        iteration_option = "max_iters" if "max_iters" in rlm_parameters else "max_iterations"
        rlm_options = {
            iteration_option: case["budgets"]["max_iterations"],
            "max_llm_calls": case["budgets"]["max_llm_calls"],
            "sub_lm": sub_lm,
        }
        prediction = dspy.RLM(signature_for(case), **rlm_options)(**case["inputs"])
        output = prediction.answer
        trace = normalize_trace(prediction)
        status = "extracted" if trace["final_reasoning"] == "Extract forced final output" else "submitted"
        failures = []
        if output != expected["output"]:
            failures.append(f"output: expected {expected['output']!r}, got {output!r}")
        if status != expected["status"]:
            failures.append(f"status: expected {expected['status']!r}, got {status!r}")
        if len(sub_lm.calls) != expected["subcalls"]:
            failures.append(f"subcalls: expected {expected['subcalls']}, got {len(sub_lm.calls)}")
        failures.extend(gate_trace(trace, expected["trace_shape"]))
        return {
            **base,
            "executed": True,
            "passing": not failures,
            "attempted_status": status,
            "status": status,
            "output": output,
            "subcalls": len(sub_lm.calls),
            "subcall_prompts": sub_lm.calls,
            "controller_calls": len(controller.history),
            "trace": trace,
            "errors": failures,
        }
    except Exception as exc:  # Evidence must retain genuine upstream failures.
        return {
            **base,
            "executed": True,
            "passing": False,
            "attempted_status": "raised",
            "status": "error",
            "output": None,
            "subcalls": len(sub_lm.calls),
            "subcall_prompts": sub_lm.calls,
            "controller_calls": len(controller.history),
            "trace": {"entries": [], "entry_count": 0, "final_reasoning": None},
            "errors": [f"{type(exc).__name__}: {exc}"],
        }


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    matched = [row for row in rows if row["disposition"] == "matched"]
    required = [row for row in matched if row["required"]]
    executed = [row for row in matched if row["executed"]]
    deviations = [row for row in rows if row["disposition"] == "deviation"]
    complete = len(executed) >= 10 and len(required) > 0 and all(row["passing"] for row in required)
    return {
        "total_cases": len(rows),
        "matched_cases": len(matched),
        "matched_executed": len(executed),
        "matched_passing": sum(row["passing"] for row in matched),
        "required_matched_cases": len(required),
        "required_matched_passing": sum(row["passing"] for row in required),
        "supported_deviations": len(deviations),
        "operational_contract_complete": complete,
        "completion_rule": "all required matched cases pass and at least 10 matched cases execute",
        "scope": SCOPE_NOTE,
    }


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_sha() -> str:
    result = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    fixture = json.loads(args.cases.read_text())
    rows = [run_case(case) for case in fixture["cases"]]
    source_path = Path(inspect.getsourcefile(dspy.RLM) or "").resolve()
    artifact = {
        "schema_version": 1,
        "evidence_tier": "t1_operational_contract",
        "scope": SCOPE_NOTE,
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "upstream_source_path": str(source_path),
        "upstream_source_sha256": sha256(source_path),
        "python_version": platform.python_version(),
        "git_sha": git_sha(),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "fixture_path": str(args.cases),
        "rows": rows,
        "summary": summarize(rows),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    print(args.out)
    print(json.dumps(artifact["summary"], indent=2, sort_keys=True))
    return 0 if artifact["summary"]["operational_contract_complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
