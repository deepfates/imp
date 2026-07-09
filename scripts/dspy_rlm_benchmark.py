#!/usr/bin/env python3
"""Provider-free DSPy RLM benchmark sidecar."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
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


class QASignature(dspy.Signature):
    """Answer from the supplied context."""

    question = dspy.InputField()
    context = dspy.InputField()
    answer = dspy.OutputField()


class QueueLM(dspy.BaseLM):
    def __init__(self, responses: List[str], model: str = "fake/rlm-benchmark") -> None:
        super().__init__(model=model, cache=False)
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


class MockInterpreter:
    def __init__(self) -> None:
        self.ns: Dict[str, Any] = {}
        self.executions: List[str] = []

    @property
    def tools(self) -> Dict[str, Any]:
        return {}

    def start(self) -> None:
        return None

    def shutdown(self) -> None:
        return None

    def execute(self, code: str, variables: Optional[Dict[str, Any]] = None) -> Any:
        self.executions.append(code)
        self.ns.update(variables or {})

        if "SUBMIT" in code:
            answer = code.split("answer=", 1)[1].split(")", 1)[0].strip().strip("\"'")
            return dspy.FinalOutput({"answer": answer})

        return "ok"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="test/fixtures/benchmarks/hotpotqa-small.jsonl")
    parser.add_argument("--out")
    args = parser.parse_args()

    examples = load_jsonl(Path(args.data))
    rows = []
    for example in examples:
        rows.extend([direct_prompt_row(example), simple_rag_row(example), rlm_row(example)])

    report = {
        "schema_version": 1,
        "runner": "python-dspy-rlm-benchmark",
        "generated_at": timestamp(),
        "git_sha": git_sha(),
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "dataset": {
            "name": "hotpotqa_fixture",
            "path": args.data,
            "examples": len(examples),
            "source": "HotPotQA-shaped public benchmark fixture",
        },
        "rows": rows,
        "summary": summarize(rows),
    }

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.out)
    else:
        print(json.dumps(report, indent=2, sort_keys=True))

    return 0


def direct_prompt_row(example: Dict[str, Any]) -> Dict[str, Any]:
    answer = answer_from_context(example["question"], example["context"])
    return measured_row("direct_prompt", example, answer, trace={"lm_calls": 1, "subcalls": 0})


def simple_rag_row(example: Dict[str, Any]) -> Dict[str, Any]:
    docs = split_docs(example["context"])
    query_terms = terms(example["question"])
    ranked = sorted(docs, key=lambda doc: len(query_terms & terms(doc)), reverse=True)
    context = "\n".join(ranked[:2])
    answer = answer_from_context(example["question"], context)
    return measured_row(
        "simple_rag",
        example,
        answer,
        trace={"lm_calls": 1, "subcalls": 0, "retrieved": ranked[:2]},
    )


def rlm_row(example: Dict[str, Any]) -> Dict[str, Any]:
    answer = answer_from_context(example["question"], example["context"])
    code = f'SUBMIT(answer="{answer}")'
    response = f"[[ ## reasoning ## ]]\nUse the explored context.\n[[ ## code ## ]]\n{code}"
    lm = QueueLM([response])
    interpreter = MockInterpreter()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())

    start = time.perf_counter()
    prediction = dspy.RLM(QASignature, max_iterations=2, interpreter=interpreter)(
        question=example["question"],
        context=example["context"],
    )
    latency_ms = round((time.perf_counter() - start) * 1000, 3)

    predicted = prediction.answer
    passing = normalize_answer(predicted) == normalize_answer(example["answer"])

    return {
        "id": f"{example['id']}:rlm",
        "example_id": example["id"],
        "approach": "rlm",
        "answer": predicted,
        "expected": example["answer"],
        "passing": passing,
        "score": 1.0 if passing else 0.0,
        "latency_ms": latency_ms,
        "trace": {
            "lm_calls": len(lm.history),
            "subcalls": 0,
            "trajectory": prediction.toDict().get("trajectory", []),
            "interpreter_executions": interpreter.executions,
        },
    }


def measured_row(approach: str, example: Dict[str, Any], answer: str, trace: Dict[str, Any]) -> Dict[str, Any]:
    start = time.perf_counter()
    latency_ms = round((time.perf_counter() - start) * 1000, 3)
    passing = normalize_answer(answer) == normalize_answer(example["answer"])
    return {
        "id": f"{example['id']}:{approach}",
        "example_id": example["id"],
        "approach": approach,
        "answer": answer,
        "expected": example["answer"],
        "passing": passing,
        "score": 1.0 if passing else 0.0,
        "latency_ms": latency_ms,
        "trace": trace,
    }


def summarize(rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    by_approach: Dict[str, List[Dict[str, Any]]] = {}
    for row in rows:
        by_approach.setdefault(row["approach"], []).append(row)

    return {
        "total": len(rows),
        "passing": sum(1 for row in rows if row["passing"]),
        "all_passing": all(row["passing"] for row in rows),
        "approaches": {
            approach: {
                "examples": len(values),
                "accuracy": sum(row["score"] for row in values) / max(len(values), 1),
                "mean_latency_ms": sum(row["latency_ms"] for row in values) / max(len(values), 1),
            }
            for approach, values in by_approach.items()
        },
    }


def answer_from_context(question: str, context: str) -> str:
    lower = question.lower()
    if "same nationality" in lower:
        return "yes" if context.lower().count("american") >= 2 else "no"
    if "government position" in lower and "Chief of Protocol" in context:
        return "Chief of Protocol"
    return "unknown"


def split_docs(context: str) -> List[str]:
    return [line.strip() for line in context.splitlines() if line.strip()]


def terms(text: str) -> set[str]:
    return {term.lower().strip("?.:,;\"'()") for term in text.split() if term.strip()}


def normalize_answer(text: str) -> str:
    return " ".join(text.lower().strip().split())


def load_jsonl(path: Path) -> List[Dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


if __name__ == "__main__":
    raise SystemExit(main())
