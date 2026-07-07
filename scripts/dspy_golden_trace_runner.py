#!/usr/bin/env python3
"""Replay provider-free golden trace fixtures through Python DSPy."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional

import dspy


@dataclass
class FakeResponse:
    choices: list
    usage: dict
    model: str
    _hidden_params: dict


class FixtureLM(dspy.BaseLM):
    def __init__(self, responses: List[str]) -> None:
        super().__init__(model="fake/golden", cache=False)
        self.responses = list(responses)

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        if not self.responses:
            raise RuntimeError("fixture response queue exhausted")

        content = self.responses.pop(0)
        return FakeResponse(
            choices=[SimpleNamespace(message=SimpleNamespace(content=content))],
            usage={},
            model=self.model,
            _hidden_params={},
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()

    cases = json.loads(Path(args.fixtures).read_text())
    report = {
        "schema_version": 1,
        "runner": "python-dspy-golden-trace",
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "git_sha": git_sha(),
        "cases": [run_case(case) for case in cases],
    }

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.out)
    else:
        print(json.dumps(report, indent=2, sort_keys=True))

    return 0


def run_case(case: Dict[str, Any]) -> Dict[str, Any]:
    lm = FixtureLM(case.get("dspy_responses", case["responses"]))
    dspy.configure(lm=lm)

    try:
        signature = dspy.Signature(dspy_signature(case["signature"]), case.get("instructions"))
        dspy.configure(lm=lm, adapter=adapter(case.get("adapter")))
        program = build_program(case, signature)
        prediction = program(**case["inputs"])
        status = "ok"
        error = None
        prediction_map = normalize_prediction(prediction)
        tool_trace = normalize_tool_trace(prediction_map)
    except Exception as exc:  # noqa: BLE001
        status = "error"
        error = repr(exc)
        prediction_map = None
        tool_trace = []

    history = normalize_history(lm.history)

    return {
        "id": case["id"],
        "status": status,
        "prediction": prediction_map,
        "tool_trace": tool_trace,
        "error": error,
        "history": history,
        "remaining_responses": len(lm.responses),
    }


def build_program(case: Dict[str, Any], signature):
    module = case["module"]

    if module == "predict":
        return dspy.Predict(signature)
    if module == "chain_of_thought":
        return dspy.ChainOfThought(signature)
    if module == "react":
        return dspy.ReAct(signature, build_tools(case), max_iters=case.get("max_iters", 5))
    raise ValueError(f"unsupported fixture module: {module}")


def build_tools(case: Dict[str, Any]):
    return [build_tool(spec) for spec in case.get("tools", [])]


def build_tool(spec: Dict[str, Any]):
    name = spec["name"]
    desc = spec.get("description", "")
    outputs = spec.get("outputs", {})

    def run(**kwargs):
        key = json.dumps(kwargs, sort_keys=True, separators=(",", ":"))
        if key not in outputs:
            raise ValueError(f"unexpected tool arguments for {name}: {kwargs!r}")
        return outputs[key]

    return dspy.Tool(run, name=name, desc=desc, args=spec.get("schema", {}).get("properties", {}))


def adapter(name: Optional[str]):
    if name == "json":
        return dspy.JSONAdapter()
    return dspy.ChatAdapter()


def dspy_signature(signature: str) -> str:
    return (
        signature.replace(": string", ": str")
        .replace(": integer", ": int")
        .replace(": boolean", ": bool")
    )


def normalize_prediction(prediction: Any) -> Dict[str, Any]:
    if hasattr(prediction, "toDict"):
        return prediction.toDict()
    if hasattr(prediction, "_store"):
        return dict(prediction._store)
    return {"repr": repr(prediction)}


def normalize_tool_trace(prediction_map: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if not prediction_map:
        return []

    trajectory = prediction_map.get("trajectory") or {}
    trace = []
    idx = 0
    while f"tool_name_{idx}" in trajectory:
        name = trajectory.get(f"tool_name_{idx}")
        args = trajectory.get(f"tool_args_{idx}", {})
        result = trajectory.get(f"observation_{idx}")
        if name != "finish":
            trace.append({"tool": name, "arguments": args, "result": result})
        idx += 1
    return trace


def normalize_history(history: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    normalized = []
    for entry in history:
        normalized.append(
            {
                "messages": entry.get("messages"),
                "kwargs": entry.get("kwargs"),
                "outputs": entry.get("outputs"),
                "model": entry.get("model"),
                "model_type": entry.get("model_type"),
            }
        )
    return normalized


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


if __name__ == "__main__":
    raise SystemExit(main())
