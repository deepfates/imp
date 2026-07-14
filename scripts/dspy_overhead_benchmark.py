#!/usr/bin/env python3
"""Provider-free DSPy overhead benchmarks for Imp parity reports."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable, Dict, Iterable, List, Optional

import dspy


class QASignature(dspy.Signature):
    """Answer the question."""

    question = dspy.InputField()
    answer = dspy.OutputField()


class StaticLM(dspy.BaseLM):
    def __init__(self, response: str = "[[ ## answer ## ]]\nParis") -> None:
        super().__init__(model="fake/overhead", cache=False)
        self.response = response

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=self.response))],
            usage={},
            model=self.model,
            _hidden_params={},
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=10)
    parser.add_argument("--out")
    args = parser.parse_args()

    dspy.configure(lm=StaticLM(), adapter=dspy.ChatAdapter())
    cases = build_cases()

    results = [
        measure(case_id, fun, iterations=args.iterations, warmup=args.warmup, batch_size=args.batch_size)
        for case_id, fun in cases.items()
    ]

    report = {
        "schema_version": 1,
        "runner": "python-dspy-overhead",
        "generated_at": timestamp(),
        "git_sha": git_sha(),
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "iterations": args.iterations,
        "warmup": args.warmup,
        "batch_size": args.batch_size,
        "cases": results,
    }

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.out)
    else:
        print(json.dumps(report, indent=2, sort_keys=True))

    return 0


def build_cases() -> Dict[str, Callable[[], Any]]:
    signature = QASignature
    adapter = dspy.ChatAdapter()
    response = "[[ ## answer ## ]]\nParis"
    examples = [dspy.Example(question=f"q{i}", answer="Paris").with_inputs("question") for i in range(8)]
    metric = lambda example, pred, trace=None: str(pred.answer).strip() == example.answer

    def signature_parse() -> Any:
        return dspy.Signature("question -> answer")

    def adapter_format() -> Any:
        return adapter.format(signature, [], {"question": "What is the capital of France?"})

    def adapter_parse() -> Any:
        return adapter.parse(signature, response)

    def schema_validate() -> Any:
        return adapter.parse(signature, response)

    def evaluation_loop() -> Any:
        evaluator = dspy.Evaluate(devset=examples, metric=metric, display_progress=False, max_errors=100)
        return evaluator(dspy.Predict(signature))

    def metric_normalization() -> Any:
        pred = dspy.Prediction(answer="Paris")
        return [metric(example, pred) for example in examples]

    def optimizer_trial_scheduling() -> Any:
        teleprompter = dspy.BootstrapFewShot(metric=metric, max_bootstrapped_demos=1, max_labeled_demos=1)
        return teleprompter.compile(dspy.Predict(signature), trainset=examples[:2])

    def trace_redaction_serialization() -> Any:
        trace = {
            "messages": [{"role": "user", "content": "hello"}],
            "api_key": "sk-test-secretsecret",
            "nested": {"authorization": "Bearer test-secret-secret"},
        }
        redacted = redact(trace)
        return json.dumps(redacted, sort_keys=True)

    cache: Dict[str, Any] = {"hit": response}

    def cache_hit() -> Any:
        return cache.get("hit")

    def cache_miss() -> Any:
        key = f"miss-{time.perf_counter_ns()}"
        cache[key] = response
        return cache[key]

    def concurrent_orchestration() -> Any:
        with ThreadPoolExecutor(max_workers=8) as executor:
            return list(executor.map(lambda value: value * value, range(32)))

    return {
        "signature_parse": signature_parse,
        "adapter_format": adapter_format,
        "adapter_parse": adapter_parse,
        "schema_validate": schema_validate,
        "evaluation_loop": evaluation_loop,
        "metric_normalization": metric_normalization,
        "optimizer_trial_scheduling": optimizer_trial_scheduling,
        "trace_redaction_serialization": trace_redaction_serialization,
        "cache_hit": cache_hit,
        "cache_miss": cache_miss,
        "concurrent_orchestration": concurrent_orchestration,
    }


def measure(
    case_id: str,
    fun: Callable[[], Any],
    *,
    iterations: int,
    warmup: int,
    batch_size: int,
) -> Dict[str, Any]:
    for _ in range(warmup):
        for _ in range(batch_size):
            fun()

    samples = []
    for _ in range(iterations):
        started = time.perf_counter_ns()
        for _ in range(batch_size):
            fun()
        samples.append(((time.perf_counter_ns() - started) / 1000) / batch_size)

    return summarize(case_id, samples)


def summarize(case_id: str, samples_us: List[float]) -> Dict[str, Any]:
    return {
        "id": case_id,
        "iterations": len(samples_us),
        "median_us": round(statistics.median(samples_us), 3),
        "mean_us": round(statistics.mean(samples_us), 3),
        "p95_us": round(percentile(samples_us, 0.95), 3),
        "min_us": round(min(samples_us), 3),
        "max_us": round(max(samples_us), 3),
    }


def percentile(values: Iterable[float], quantile: float) -> float:
    sorted_values = sorted(values)
    index = min(len(sorted_values) - 1, max(0, round((len(sorted_values) - 1) * quantile)))
    return sorted_values[index]


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: "[REDACTED]" if "key" in key.lower() or "authorization" in key.lower() else redact(nested)
            for key, nested in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


def timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def file_sha256(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
