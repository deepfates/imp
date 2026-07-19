#!/usr/bin/env python3
"""Run canonical benchmark rows through the real Python DSPy package.

This script intentionally lives outside the Elixir runtime. It is the
side-by-side reference runner used by Imp parity reports.
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
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple


DIAGNOSTIC_LIMIT_CHARS = 2048
DIAGNOSTIC_SECRETS: Tuple[str, ...] = ()
HISTORY_ENTRY_UNSET = object()


def isolate_from_beam_process_group() -> None:
    if os.name == "posix" and os.environ.get("IMP_BEAM_PORT_OWNER") == "1":
        if os.getpgrp() != os.getpid():
            os.setsid()


isolate_from_beam_process_group()

import dspy

HOTPOTQA_INSTRUCTION = (
    "Answer using the provided context. Return the canonical exact answer span from the context. "
    "For yes/no questions, answer exactly yes or no. Do not abbreviate locations, titles, names, "
    "dates, or quantities when the question asks for the full entity."
)
DSPY_PROMPT_CONTRACT = "dspy-signature-chat-20260707-canonical-answer"


class GSM8KSignature(dspy.Signature):
    """Solve the math word problem. Return only the final numeric answer in answer."""

    question = dspy.InputField()
    answer = dspy.OutputField(desc="final numeric answer")


class HotPotQASignature(dspy.Signature):
    __doc__ = HOTPOTQA_INSTRUCTION

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
    global DIAGNOSTIC_SECRETS

    parser = argparse.ArgumentParser()
    parser.add_argument("--gsm8k")
    parser.add_argument("--hotpotqa")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--max-examples", type=int, default=20)
    parser.add_argument("--max-concurrency", type=int, default=1)
    parser.add_argument("--out", default="benchmarks/results")
    parser.add_argument("--model", default=os.environ.get("OPENAI_MODEL", "gpt-5.5"))
    parser.add_argument("--campaign-id")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--max-tokens", type=int, default=700)
    parser.add_argument("--reasoning-effort")
    parser.add_argument("--api-key-env", default="OPENAI_API_KEY")
    args = parser.parse_args()

    api_key = os.environ.get(args.api_key_env)
    if not api_key:
        raise SystemExit(f"{args.api_key_env} is required")

    DIAGNOSTIC_SECRETS = (api_key,)
    os.makedirs(args.out, exist_ok=True)
    configure_dspy(args.model, api_key, args.temperature, args.max_tokens, args.reasoning_effort)

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
        "campaign_id": args.campaign_id,
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "model": {"provider": "dspy.LM", "model": dspy_lm_name(args.model)},
        "generation": generation_metadata(
            args.model, args.temperature, args.max_tokens, args.reasoning_effort
        ),
        "tasks": tasks,
        "aggregate_score": average([task["score"] for task in tasks]),
    }

    out_path = Path(args.out) / f"dspy-parity-live-{timestamp_slug()}.json"
    write_report_atomically(out_path, report)
    print(f"DSPY_REPORT_PATH={out_path}")
    print(f"aggregate score: {report['aggregate_score']}")
    return 0


def write_report_atomically(out_path: Path, report: Dict[str, Any]) -> None:
    partial_path = out_path.with_suffix(out_path.suffix + ".partial")
    try:
        partial_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        os.replace(partial_path, out_path)
    finally:
        partial_path.unlink(missing_ok=True)


def configure_dspy(
    model: str,
    api_key: str,
    temperature: Optional[float],
    max_tokens: int,
    reasoning_effort: Optional[str],
) -> None:
    lm_args: Dict[str, Any] = {
        "api_key": api_key,
        "cache": False,
    }
    normalized = model.lower()
    if dspy_responses_model(normalized) and reasoning_model(responses_model_family(normalized)):
        lm_args["max_tokens"] = max_tokens
        lm_args["max_completion_tokens"] = max_tokens
        lm_args["temperature"] = 1.0
    elif dspy_reasoning_model(normalized):
        lm_args["max_tokens"] = max_tokens
        lm_args["max_completion_tokens"] = max_tokens
        lm_args["temperature"] = 1.0
    else:
        lm_args["max_tokens"] = max_tokens
        if temperature is not None:
            lm_args["temperature"] = temperature
    if reasoning_effort:
        lm_args["reasoning_effort"] = reasoning_effort

    lm = attributing_lm(dspy_lm_name(model), **lm_args)
    dspy.configure(lm=lm)


def attributing_lm(*args: Any, **kwargs: Any) -> Any:
    class AttributingLM(dspy.LM):
        def __init__(self, *lm_args: Any, **lm_kwargs: Any) -> None:
            super().__init__(*lm_args, **lm_kwargs)
            self._imp_thread_history = threading.local()

        def update_history(self, entry: Dict[str, Any]) -> None:
            super().update_history(entry)
            self._imp_thread_history.entry = entry

        def clear_thread_history_entry(self) -> None:
            self._imp_thread_history.entry = None

        def thread_history_entry(self) -> Optional[Dict[str, Any]]:
            return getattr(self._imp_thread_history, "entry", None)

    return AttributingLM(*args, **kwargs)


def dspy_lm_name(model: str) -> str:
    if model.lower().strip("/").startswith("responses/"):
        return f"openai/{model.strip('/')}"
    if "/" in model:
        return model
    return f"openai/{model}"


def generation_metadata(
    model: str,
    temperature: Optional[float],
    max_tokens: int,
    reasoning_effort: Optional[str],
) -> Dict[str, Any]:
    requested = {"temperature": temperature, "max_tokens": max_tokens}
    if reasoning_effort:
        requested["reasoning_effort"] = reasoning_effort
    effective, warnings = effective_generation(model, temperature, max_tokens, reasoning_effort)
    return {
        **requested,
        "runtime": "python_dspy",
        "prompt_contract": DSPY_PROMPT_CONTRACT,
        "requested": requested,
        "effective": effective,
        "wire_api": wire_api(model),
        "warnings": warnings,
        "note": (
            "requested records the benchmark intent; effective and wire_api record "
            "the deterministic DSPy/LiteLLM request shape known before the request is sent"
        ),
    }


def effective_generation(
    model: str,
    temperature: Optional[float],
    max_tokens: int,
    reasoning_effort: Optional[str],
) -> Tuple[Dict[str, Any], List[str]]:
    normalized = model.lower()
    if dspy_responses_model(normalized):
        if not reasoning_model(responses_model_family(normalized)):
            effective = {"temperature": temperature, "max_tokens": max_tokens}
            if reasoning_effort:
                effective["reasoning_effort"] = reasoning_effort
            return (
                effective,
                ["DSPy/LiteLLM routed this comparison through OpenAI Responses for endpoint-equivalent parity"],
            )

        effective = {"max_completion_tokens": max_tokens}
        if reasoning_effort:
            effective["reasoning_effort"] = reasoning_effort
        return (
            effective,
            [
                "DSPy/LiteLLM routed this comparison through OpenAI Responses for endpoint-equivalent parity",
                "DSPy LM was configured with temperature=1.0 because GPT-5-family requests reject temperature=0.0; this matches the provider default that Imp reaches by dropping temperature",
            ],
        )
    if dspy_reasoning_model(normalized):
        effective = {"max_completion_tokens": max_tokens}
        if reasoning_effort:
            effective["reasoning_effort"] = reasoning_effort
        return (
            effective,
            [
                "DSPy LM renamed max_tokens to max_completion_tokens for o-series reasoning model profile",
                "DSPy requires temperature=1.0 for o-series reasoning models",
            ],
        )
    effective = {"temperature": temperature, "max_tokens": max_tokens}
    if reasoning_effort:
        effective["reasoning_effort"] = reasoning_effort
    return (effective, [])


def reasoning_model(model: str) -> bool:
    return bool(re.search(r"(^|[-_:])(gpt-5|o[134])", model)) or "reasoning" in model


def dspy_reasoning_model(model: str) -> bool:
    model_family = model.split("/")[-1].lower() if "/" in model else model.lower()
    return bool(re.match(r"^o([134])(?:-mini)?", model_family))


def dspy_responses_model(model: str) -> bool:
    normalized = model.lower().strip("/")
    return normalized.startswith("responses/") or "/responses/" in normalized


def responses_model_family(model: str) -> str:
    normalized = model.lower().strip("/")
    return normalized.split("responses/", 1)[-1]


def wire_api(model: str) -> str:
    normalized = model.lower().strip("/")
    if normalized.startswith("anthropic/"):
        return "litellm_anthropic_messages"
    if normalized.startswith("gemini/") or normalized.startswith("google/"):
        return "litellm_google_generate_content"
    if dspy_responses_model(model):
        return "openai_responses"
    if dspy_reasoning_model(model):
        return "litellm_chat_completion_with_max_completion_tokens"
    return "litellm_chat_completion"


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
    metric: Callable[[Dict[str, Any], Any], Dict[str, Any]],
    index: int,
    row: Dict[str, Any],
) -> Dict[str, Any]:
    started = time.perf_counter()
    before_history_len = dspy_history_len()
    clear_thread_history_entry()
    try:
        program = GSM8KProgram() if task == "gsm8k" else HotPotQAProgram()
        if task == "gsm8k":
            prediction = program(question=row["question"])
        else:
            prediction = program(question=row["question"], context=row["context"])

        metric_result = metric(row, prediction)
        passed = bool(metric_result["passed"])
        error = None
        pred = prediction_to_dict(prediction)
    except Exception as exc:  # noqa: BLE001 - benchmark artifact should capture all failures.
        passed = False
        metric_result = {"score": 0.0, "passed": False, "metadata": {}}
        error = exception_diagnostic(index, exc)
        pred = None

    duration_ms = round((time.perf_counter() - started) * 1000, 3)
    history_entry = thread_history_entry()

    return {
        "index": index,
        "score": metric_result["score"],
        "passed": passed,
        "prediction": pred,
        "metric_metadata": metric_result.get("metadata", {}),
        "error": error,
        "duration_ms": duration_ms,
        "instrumentation": dspy_instrumentation(
            task,
            row,
            pred,
            duration_ms,
            before_history_len,
            history_entry=history_entry,
        ),
    }


def clear_thread_history_entry() -> None:
    lm = getattr(dspy.settings, "lm", None)
    clear = getattr(lm, "clear_thread_history_entry", None)
    if callable(clear):
        clear()


def thread_history_entry() -> Optional[Dict[str, Any]]:
    lm = getattr(dspy.settings, "lm", None)
    get_entry = getattr(lm, "thread_history_entry", None)
    return get_entry() if callable(get_entry) else None


def exception_diagnostic(index: int, exc: Exception) -> Dict[str, Any]:
    text = str(exc)
    total_chars = len(text)
    redacted = redact_diagnostic(text)

    return {
        "index": index,
        "type": type(exc).__name__,
        "reason": redacted[:DIAGNOSTIC_LIMIT_CHARS],
        "reason_truncated": len(redacted) > DIAGNOSTIC_LIMIT_CHARS,
        "reason_chars": total_chars,
        "reason_limit_chars": DIAGNOSTIC_LIMIT_CHARS,
    }


def redact_diagnostic(text: str) -> str:
    for secret in sorted((value for value in DIAGNOSTIC_SECRETS if value), key=len, reverse=True):
        text = text.replace(secret, "[REDACTED]")
    text = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[REDACTED]", text)
    return re.sub(
        r"\bBearer\s+[A-Za-z0-9._~+/=\-]{12,}\b",
        "Bearer [REDACTED]",
        text,
        flags=re.IGNORECASE,
    )


def dspy_history_len() -> int:
    history = getattr(dspy.settings.lm, "history", None)
    return len(history) if isinstance(history, list) else 0


def dspy_instrumentation(
    task: str,
    row: Dict[str, Any],
    prediction: Optional[Dict[str, Any]],
    duration_ms: float,
    before_history_len: int,
    history_entry: Any = HISTORY_ENTRY_UNSET,
) -> Dict[str, Any]:
    if history_entry is HISTORY_ENTRY_UNSET:
        history_entry = attributed_history_entry(before_history_len, row)
        history_attribution = "shared_history_match" if history_entry is not None else "unavailable"
    else:
        history_attribution = "thread_local_lm" if history_entry is not None else "unavailable"

    history = history_instrumentation(history_entry)
    input_chars = len(str(row.get("question", "")))
    if task == "hotpotqa":
        input_chars += len(str(row.get("context", "")))
    message_chars = history.get("message_chars")
    message_chars_source = "lm_history"
    if message_chars is None:
        message_chars = estimated_dspy_message_chars(task, row)
        message_chars_source = "row_estimate"

    return {
        "lm_calls": 1,
        "lm_duration_ms": duration_ms,
        "input_chars": input_chars,
        "prediction_chars": char_len(prediction),
        "message_chars": message_chars,
        "message_chars_source": message_chars_source,
        "raw_chars": history.get("raw_chars") or char_len(prediction),
        "raw_chars_source": "lm_history" if history.get("raw_chars") else "prediction_fallback",
        "history_found": history_entry is not None,
        "history_attribution": history_attribution,
        "usage_found": all(
            history.get(key) is not None for key in ("input_tokens", "output_tokens", "usd")
        ),
        "input_tokens": history.get("input_tokens"),
        "output_tokens": history.get("output_tokens"),
        "usd": history.get("usd"),
        "history_keys": sorted(history_entry.keys()) if isinstance(history_entry, dict) else [],
        "note": (
            "The parity LM captures each row's exact history entry in worker-local storage. "
            "Shared-history matching remains a compatibility fallback; if neither is available, "
            "message_chars is a deterministic estimate from the canonical benchmark row."
        ),
    }


def estimated_dspy_message_chars(task: str, row: Dict[str, Any]) -> int:
    """Conservative prompt-shape estimate for rows whose DSPy LM history is ambiguous.

    This is deliberately simple and deterministic. It keeps benchmark shape coverage complete under
    concurrent DSPy execution without claiming byte-for-byte access to the provider request.
    """

    if task == "gsm8k":
        return char_len(row.get("question", ""))
    if task == "hotpotqa":
        return char_len(row.get("question", "")) + char_len(row.get("context", ""))
    return char_len(row)


def attributed_history_entry(
    before_history_len: int,
    row: Optional[Dict[str, Any]] = None,
) -> Optional[Dict[str, Any]]:
    history = getattr(dspy.settings.lm, "history", None)
    if not isinstance(history, list):
        return None
    if (
        len(history) == before_history_len + 1
        and isinstance(history[-1], dict)
        and (row is None or history_entry_matches_row(history[-1], row))
    ):
        return history[-1]
    if row is None:
        return None

    # Concurrent calls can append between the length snapshot and this row's
    # own history write. Match across the complete history by canonical input
    # instead of assuming append order identifies the caller.
    search_space = [entry for entry in history if isinstance(entry, dict)]
    candidates = [entry for entry in search_space if history_entry_matches_row(entry, row)]
    if len(candidates) == 1:
        return candidates[0]

    return None


def history_entry_matches_row(entry: Dict[str, Any], row: Dict[str, Any]) -> bool:
    question = str(row.get("question", "")).strip()
    if not question:
        return False
    haystack = history_entry_text(entry)
    if question not in haystack:
        return False

    # HotPotQA questions frequently occur inside another row's evidence. Bind
    # attribution to the complete canonical input, not the question alone.
    context = str(row.get("context", "")).strip()
    return not context or context in haystack


def history_entry_text(entry: Dict[str, Any]) -> str:
    fields = [
        entry.get("messages"),
        entry.get("prompt"),
        entry.get("kwargs"),
        entry.get("inputs"),
    ]
    return "\n".join(structured_text(field) for field in fields if field is not None)


def structured_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return "\n".join(structured_text(item) for item in value.values())
    if isinstance(value, (list, tuple)):
        return "\n".join(structured_text(item) for item in value)
    return str(value)


def history_instrumentation(history_entry: Optional[Dict[str, Any]]) -> Dict[str, Optional[int]]:
    if not isinstance(history_entry, dict):
        return {
            "message_chars": None,
            "raw_chars": None,
            "input_tokens": None,
            "output_tokens": None,
            "usd": None,
        }

    messages = history_entry.get("messages")
    prompt = history_entry.get("prompt")
    response = (
        history_entry.get("response")
        or history_entry.get("outputs")
        or history_entry.get("completion")
        or history_entry.get("completions")
    )
    usage = history_entry.get("usage") or {}

    return {
        "message_chars": messages_char_len(messages) if messages is not None else char_len(prompt),
        "raw_chars": char_len(response),
        "input_tokens": first_number(usage, "input_tokens", "prompt_tokens", "input"),
        "output_tokens": first_number(usage, "output_tokens", "completion_tokens", "output"),
        "usd": first_number(history_entry, "cost"),
    }


def first_number(mapping: Any, *keys: str) -> Optional[float]:
    if not isinstance(mapping, dict):
        return None
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return value
    return None


def messages_char_len(messages: Any) -> int:
    if not isinstance(messages, list):
        return char_len(messages)
    total = 0
    for message in messages:
        if isinstance(message, dict):
            total += char_len(message.get("content", ""))
        else:
            total += char_len(message)
    return total


def char_len(value: Any) -> int:
    if value is None:
        return 0
    if isinstance(value, str):
        return len(value)
    try:
        return len(json.dumps(value, sort_keys=True, ensure_ascii=False, default=str))
    except TypeError:
        return len(repr(value))


def gsm8k_metric(example: Dict[str, Any], prediction: Any) -> Dict[str, Any]:
    gold = example.get("canonical_answer") or extract_gsm8k_answer(example.get("answer", ""))
    predicted = getattr(prediction, "answer", "")
    passed = numeric_answer_equal(predicted, gold) or normalize_text(predicted) == normalize_text(gold)
    return {"score": 1.0 if passed else 0.0, "passed": passed, "metadata": {"task_metric": "gsm8k_numeric_exact_match"}}


def hotpotqa_metric(example: Dict[str, Any], prediction: Any) -> Dict[str, Any]:
    predicted = getattr(prediction, "answer", "")
    gold = example.get("answer", "")
    # "official" = the HotPotQA leaderboard metric as ported by DSPy
    # (em_score / hotpot_f1_score, incl. the yes/no/noanswer F1 gate); DSPy's
    # only delta from hotpot_evaluate_v1.py is a leading Unicode NFD step.
    exact_match = hotpotqa_em(predicted, gold)
    f1 = hotpotqa_f1(predicted, gold)
    return {
        "score": 1.0 if exact_match else 0.0,
        "passed": exact_match,
        "metadata": {
            "task_metric": "hotpotqa_exact_match",
            "official_hotpotqa_f1": f1,
            "official_hotpotqa_em": exact_match,
        },
    }


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


def numeric_answer_equal(predicted: Any, gold: Any) -> bool:
    predicted_number = parse_numeric_answer(predicted)
    gold_number = parse_numeric_answer(gold)
    return (
        predicted_number is not None
        and gold_number is not None
        and abs(predicted_number - gold_number) <= 1e-9
    )


def parse_numeric_answer(value: Any) -> Optional[float]:
    text = str(value).strip().replace(",", "")
    if text.startswith("$"):
        text = text[1:].strip()
    if not re.fullmatch(r"-?\d+(?:\.\d+)?", text):
        return None
    return float(text)


# Metric helpers call the REAL dspy.evaluate.metrics implementations
# (dee-c2ur / dee-j11u): the previous home-grown normalize (punctuation ->
# space, no NFD, no article word-boundary) provably disagreed with the
# official SQuAD/HotPotQA metric (f1('the US congress','U.S. congress') was
# 0.4; official is 1.0). Imports are function-local, not module-level: the
# structural tests in test/benchmark_truth_test.exs exec this module against
# a stub dspy that has no dspy.evaluate submodule. A missing real dspy fails
# loudly at metric time, never silently falls back.


def normalize_text(value: Any) -> str:
    from dspy.evaluate.metrics import normalize_text as dspy_normalize_text

    return dspy_normalize_text(str(value))


def hotpotqa_em(predicted: Any, gold: Any) -> bool:
    from dspy.evaluate.metrics import em_score

    return bool(em_score(str(predicted), str(gold)))


def hotpotqa_f1(predicted: Any, gold: Any) -> float:
    from dspy.evaluate.metrics import hotpot_f1_score

    return float(hotpot_f1_score(str(predicted), str(gold)))


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
