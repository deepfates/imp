#!/usr/bin/env python3
"""Run canonical benchmark rows through the real Python DSPy package.

This script intentionally lives outside the Elixir runtime. It is the
side-by-side reference runner used by DSEx parity reports.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

import dspy


class GSM8KSignature(dspy.Signature):
    """Solve the math word problem. Return only the final numeric answer in answer."""

    question = dspy.InputField()
    answer = dspy.OutputField(desc="final numeric answer")


class HotPotQASignature(dspy.Signature):
    """Answer using the provided context. Return the shortest exact answer string."""

    question = dspy.InputField()
    context = dspy.InputField()
    answer = dspy.OutputField(desc="short exact answer")


class GSM8KProgram(dspy.Module):
    def __init__(self) -> None:
        self.program = dspy.ChainOfThought(GSM8KSignature)

    def forward(self, question: str) -> Any:
        return self.program(question=question)


class HotPotQAProgram(dspy.Module):
    def __init__(self) -> None:
        self.program = dspy.Predict(HotPotQASignature)

    def forward(self, question: str, context: str) -> Any:
        return self.program(question=question, context=context)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gsm8k")
    parser.add_argument("--hotpotqa")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--max-examples", type=int, default=20)
    parser.add_argument("--max-concurrency", type=int, default=1)
    parser.add_argument("--out", default="benchmarks/results")
    parser.add_argument("--model", default=os.environ.get("OPENAI_MODEL", "gpt-5.5"))
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--api-key-env", default="OPENAI_API_KEY")
    args = parser.parse_args()

    api_key = os.environ.get(args.api_key_env)
    if not api_key:
        raise SystemExit(f"{args.api_key_env} is required")

    os.makedirs(args.out, exist_ok=True)
    configure_dspy(args.model, api_key, args.temperature)

    tasks: List[Dict[str, Any]] = []
    if args.gsm8k:
        tasks.append(run_task("gsm8k", args.gsm8k, args.offset, args.max_examples, args.max_concurrency))
    if args.hotpotqa:
        tasks.append(run_task("hotpotqa", args.hotpotqa, args.offset, args.max_examples, args.max_concurrency))
    if not tasks:
        raise SystemExit("provide --gsm8k or --hotpotqa")

    report = {
        "schema_version": 1,
        "runner": "python-dspy",
        "mode": "live",
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "git_sha": git_sha(),
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "model": {"provider": "dspy.LM", "model": f"openai/{args.model}"},
        "tasks": tasks,
        "aggregate_score": average([task["score"] for task in tasks]),
    }

    out_path = Path(args.out) / f"dspy-parity-live-{timestamp_slug()}.json"
    out_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(str(out_path))
    print(f"aggregate score: {report['aggregate_score']}")
    return 0


def configure_dspy(model: str, api_key: str, temperature: Optional[float]) -> None:
    lm_args: Dict[str, Any] = {
        "api_key": api_key,
        "max_tokens": 700,
        "cache": False,
    }
    if temperature is not None:
        lm_args["temperature"] = temperature

    lm = dspy.LM(f"openai/{model}", **lm_args)
    dspy.configure(lm=lm)


def run_task(task: str, path: str, offset: int, max_examples: int, max_concurrency: int) -> Dict[str, Any]:
    rows = read_jsonl(path)[offset : offset + max_examples]
    metric = gsm8k_metric if task == "gsm8k" else hotpotqa_metric
    started = time.perf_counter()

    indexed_rows = list(enumerate(rows))
    if max_concurrency <= 1:
        result_rows = [run_row(task, metric, index, row) for index, row in indexed_rows]
    else:
        with ThreadPoolExecutor(max_workers=max_concurrency) as executor:
            result_rows = list(
                executor.map(lambda item: run_row(task, metric, item[0], item[1]), indexed_rows)
            )

    duration_ms = (time.perf_counter() - started) * 1000
    return {
        "task": task,
        "path": path,
        "sha256": file_sha256(path),
        "offset": offset,
        "examples": len(rows),
        "max_concurrency": max_concurrency,
        "score": average([row["score"] for row in result_rows]),
        "duration_ms": round(duration_ms, 3),
        "errors": [row["error"] for row in result_rows if row["error"] is not None],
        "rows": result_rows,
    }


def run_row(
    task: str,
    metric: Callable[[Dict[str, Any], Any], bool],
    index: int,
    row: Dict[str, Any],
) -> Dict[str, Any]:
    started = time.perf_counter()
    try:
        program = GSM8KProgram() if task == "gsm8k" else HotPotQAProgram()
        if task == "gsm8k":
            prediction = program(question=row["question"])
        else:
            prediction = program(question=row["question"], context=row["context"])

        passed = bool(metric(row, prediction))
        error = None
        pred = prediction_to_dict(prediction)
    except Exception as exc:  # noqa: BLE001 - benchmark artifact should capture all failures.
        passed = False
        error = {"index": index, "reason": repr(exc)}
        pred = None

    return {
        "index": index,
        "score": 1.0 if passed else 0.0,
        "passed": passed,
        "prediction": pred,
        "error": error,
        "duration_ms": round((time.perf_counter() - started) * 1000, 3),
    }


def gsm8k_metric(example: Dict[str, Any], prediction: Any) -> bool:
    gold = example.get("canonical_answer") or extract_gsm8k_answer(example.get("answer", ""))
    return normalize_text(getattr(prediction, "answer", "")) == normalize_text(gold)


def hotpotqa_metric(example: Dict[str, Any], prediction: Any) -> bool:
    return normalize_text(getattr(prediction, "answer", "")) == normalize_text(example.get("answer", ""))


def prediction_to_dict(prediction: Any) -> Dict[str, Any]:
    data: Dict[str, Any] = {}
    for key in ("reasoning", "answer"):
        if hasattr(prediction, key):
            data[key] = getattr(prediction, key)
    if not data:
        data["repr"] = repr(prediction)
    return data


def read_jsonl(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def extract_gsm8k_answer(answer: str) -> str:
    return str(answer).split("####")[-1].strip()


def normalize_text(value: Any) -> str:
    text = str(value).lower()
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    words = [word for word in text.split() if word not in {"a", "an", "the"}]
    return " ".join(words)


def average(values: Iterable[float]) -> float:
    values = list(values)
    if not values:
        return 0.0
    return sum(values) / len(values)


def file_sha256(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


def timestamp_slug() -> str:
    return re.sub(r"[^0-9A-Za-z]", "", datetime.now(timezone.utc).replace(microsecond=0).isoformat())


if __name__ == "__main__":
    raise SystemExit(main())
