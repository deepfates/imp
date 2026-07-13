#!/usr/bin/env python3
"""One-row DSPy campaign sidecar. No fixture or oracle mode is provided."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import threading
import time
from pathlib import Path
from typing import Any

import dspy


class CampaignError(RuntimeError):
    def __init__(self, message: str, usage: dict[str, Any] | None = None):
        super().__init__(message)
        self.usage = usage


class BudgetLM(dspy.BaseLM):
    def __init__(
        self,
        inner: Any,
        ledger: dict[str, Any],
        limits: dict[str, float],
        pricing: dict[str, float],
        configured_max_tokens: int,
        role: str,
        lock: threading.Lock,
    ):
        self.inner = inner
        self.ledger = ledger
        self.limits = limits
        self.pricing = validated_rates(pricing)
        self.configured_max_tokens = int(configured_max_tokens)
        self.role = role
        self.lock = lock
        self.dispatch_lock = threading.Lock()

        for key, value in (("_reserved_input", 0), ("_reserved_output", 0), ("_reserved_usd", 0.0)):
            self.ledger.setdefault(key, value)
        self.ledger.setdefault("_cost_audit", list(self.ledger.get("cost_audit", [])))
        self.ledger.setdefault("_cost_rates", dict(self.pricing))

        if self.configured_max_tokens <= 0:
            raise CampaignError("configured provider output limit must be positive")

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)

    def __call__(self, prompt: Any = None, **kwargs: Any) -> Any:
        conservative_input = len(str(prompt).encode("utf-8")) + 256
        with self.dispatch_lock:
            with self.lock:
                if self.ledger["requests"] + 1 > self.limits["requests"]:
                    raise CampaignError(
                        "request ceiling exhausted before dispatch", auditable_usage(self.ledger)
                    )
                if (
                    self.ledger["input_tokens"]
                    + self.ledger["_reserved_input"]
                    + conservative_input
                    > self.limits["input_tokens"]
                ):
                    raise CampaignError(
                        "input-token ceiling exhausted before dispatch",
                        auditable_usage(self.ledger),
                    )
                output_remaining = int(
                    self.limits["output_tokens"]
                    - self.ledger["output_tokens"]
                    - self.ledger["_reserved_output"]
                )
                if output_remaining <= 0:
                    raise CampaignError(
                        "output-token ceiling exhausted before dispatch",
                        auditable_usage(self.ledger),
                    )
                dispatch_max = min(self.configured_max_tokens, output_remaining)
                reserved_usd = (
                    conservative_input / 1_000_000 * self.pricing["input_per_million"]
                    + dispatch_max / 1_000_000 * self.pricing["output_per_million"]
                )
                if (
                    self.ledger["usd"] + self.ledger["_reserved_usd"] + reserved_usd
                    > self.limits["usd"]
                ):
                    raise CampaignError(
                        "USD ceiling exhausted before dispatch", auditable_usage(self.ledger)
                    )
                self.ledger["requests"] += 1
                self.ledger[f"{self.role}_calls"] += 1
                request_index = self.ledger["requests"]
                self.ledger["_reserved_input"] += conservative_input
                self.ledger["_reserved_output"] += dispatch_max
                self.ledger["_reserved_usd"] += reserved_usd

            provider_key = (
                "max_completion_tokens"
                if "max_completion_tokens" in getattr(self.inner, "kwargs", {})
                else "max_tokens"
            )
            dispatch_kwargs = {**kwargs, provider_key: dispatch_max, "cache": False}
            history_cursor = history_length(self.inner)
            result: Any = None
            provider_error: BaseException | None = None
            try:
                result = self.inner(prompt, **dispatch_kwargs)
            except BaseException as error:
                provider_error = error

            usage = new_history_usage(self.inner, history_cursor)
            if not usage and isinstance(getattr(provider_error, "usage", None), dict):
                usage = provider_error.usage
            input_tokens, input_error = token_count(usage, "input_tokens", "prompt_tokens")
            output_tokens, output_error = token_count(
                usage, "output_tokens", "completion_tokens"
            )
            audit, cost_error = cost_audit(
                usage,
                input_tokens,
                output_tokens,
                self.pricing,
                request_index,
                self.role,
            )

            with self.lock:
                self.ledger["_reserved_input"] -= conservative_input
                self.ledger["_reserved_output"] -= dispatch_max
                self.ledger["_reserved_usd"] -= reserved_usd
                self.ledger["input_tokens"] += input_tokens
                self.ledger["output_tokens"] += output_tokens
                self.ledger["usd"] += audit["usd"]
                self.ledger["_cost_audit"].append(audit)
                snapshot = auditable_usage(self.ledger)

        for key in ("input_tokens", "output_tokens", "usd"):
            if snapshot[key] > self.limits[key]:
                raise CampaignError(f"observed {key} ceiling exceeded", snapshot)
        observation_errors = [error for error in (input_error, output_error, cost_error) if error]
        if observation_errors:
            raise CampaignError("; ".join(observation_errors), snapshot) from provider_error
        if provider_error is not None:
            raise CampaignError(f"provider call failed after charging usage: {provider_error}", snapshot) from provider_error
        if input_tokens <= 0 or output_tokens <= 0:
            raise CampaignError("provider usage missing; outcome is not auditable", snapshot)
        return result


def validated_rates(pricing: dict[str, float]) -> dict[str, float]:
    rates = {}
    for key in ("input_per_million", "output_per_million"):
        value = pricing.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise CampaignError(f"invalid reservation pricing for {key}")
        value = float(value)
        if not math.isfinite(value) or value < 0:
            raise CampaignError(f"invalid reservation pricing for {key}")
        rates[key] = value
    return rates


def history_length(inner: Any) -> int:
    history = getattr(inner, "history", [])
    try:
        return len(history)
    except TypeError:
        return 0


def new_history_usage(inner: Any, cursor: int) -> dict[str, Any]:
    history = getattr(inner, "history", [])
    try:
        if len(history) <= cursor:
            return {}
        entry = history[-1]
    except (IndexError, TypeError):
        return {}
    if not isinstance(entry, dict) or not isinstance(entry.get("usage"), dict):
        return {}
    return entry["usage"]


def token_count(usage: dict[str, Any], primary: str, fallback: str) -> tuple[int, str | None]:
    value = usage.get(primary, usage.get(fallback, 0))
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0, f"invalid provider {primary}"
    if not math.isfinite(float(value)) or value < 0 or int(value) != value:
        return 0, f"invalid provider {primary}"
    return int(value), None


def provider_cost(usage: dict[str, Any]) -> tuple[float | None, str | None]:
    observed = []
    for key in ("total_cost", "cost"):
        if key not in usage or usage[key] is None:
            continue
        value = usage[key]
        if key == "cost" and isinstance(value, dict):
            continue
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None, f"invalid provider {key}"
        value = float(value)
        if not math.isfinite(value) or value < 0:
            return None, f"invalid provider {key}"
        observed.append(value)
    if observed and not all(math.isclose(observed[0], value) for value in observed[1:]):
        return None, "inconsistent provider cost fields"
    reported = observed[0] if observed else None
    return (reported if reported is not None and reported > 0 else None), None


def cost_audit(
    usage: dict[str, Any],
    input_tokens: int,
    output_tokens: int,
    rates: dict[str, float],
    request_index: int,
    role: str,
) -> tuple[dict[str, Any], str | None]:
    reported, error = provider_cost(usage)
    derived = (
        input_tokens / 1_000_000 * rates["input_per_million"]
        + output_tokens / 1_000_000 * rates["output_per_million"]
    )

    if error:
        authority, usd, reported_usd, error = "unavailable", 0.0, None, error
    elif reported is not None:
        authority, usd, reported_usd = "provider_reported", reported, reported
    elif usage.get("cost_authority") == "free":
        authority, usd, reported_usd = "free", 0.0, 0.0
    elif derived > 0:
        authority, usd, reported_usd = "pricing_derived", derived, None
    else:
        authority, usd, reported_usd = "unavailable", 0.0, None
        error = "zero cost lacks explicit free authority"

    return (
        {
            "request": request_index,
            "role": role,
            "authority": authority,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "usd": usd,
            "provider_reported_usd": reported_usd,
            "rates": dict(rates),
        },
        error,
    )


def remaining(snapshot: dict[str, Any]) -> dict[str, float]:
    limits = snapshot["limits"]
    usage = snapshot["usage"]
    return {
        "requests": int(limits["requests"]) - int(snapshot["requests"]),
        "input_tokens": int(limits["input_tokens"]) - int(usage["input_tokens"]),
        "output_tokens": int(limits["output_tokens"]) - int(usage["output_tokens"]),
        "usd": float(limits["usd"]) - float(usage["usd"]),
    }


def auditable_usage(ledger: dict[str, Any]) -> dict[str, Any]:
    audits = [dict(audit) for audit in ledger.get("_cost_audit", ledger.get("cost_audit", []))]
    audits.sort(key=lambda audit: audit["request"])
    authorities = {audit["authority"] for audit in audits}
    if not audits or "unavailable" in authorities:
        authority = "unavailable"
    elif len(authorities) == 1:
        authority = next(iter(authorities))
    else:
        authority = "mixed"
    result = {
        key: ledger[key]
        for key in ("requests", "root_calls", "sub_calls", "input_tokens", "output_tokens", "usd")
    }
    result.update(
        {
            "cost_authority": authority,
            "cost_rates": dict(ledger.get("_cost_rates", ledger.get("cost_rates", {}))),
            "cost_audit": audits,
        }
    )
    return result


def context_text(row: dict[str, Any]) -> str:
    if "documents" in row:
        return json.dumps(row["documents"], ensure_ascii=False)
    value = row.get("context", "")
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def lexical_retrieval(row: dict[str, Any], k: int) -> str:
    if "documents" in row:
        docs = [item["text"] for item in row["documents"]]
    else:
        docs = re.split(r"\n{2,}", context_text(row))
    terms = set(re.findall(r"[a-z0-9]+", row["question"].lower()))
    docs.sort(key=lambda text: -sum(token in terms for token in re.findall(r"[a-z0-9]+", text.lower())))
    return "\n\n".join(docs[:k])


def prediction_answer(prediction: Any) -> str:
    answer = getattr(prediction, "answer", None)
    if not isinstance(answer, str) or not answer.strip():
        raise CampaignError(f"malformed DSPy output: {answer!r}")
    return answer


def bounded_trace(events: list[Any]) -> list[dict[str, Any]]:
    result = []
    for index, event in enumerate(events):
        encoded = json.dumps(event, sort_keys=True, default=str).encode("utf-8")
        result.append({"index": index, "action": "repl", "bytes": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest()})
    return result


def provider_constructor_max_tokens(model: str, configured_max_tokens: int) -> int:
    if model.startswith("openai/gpt-5"):
        return max(16_000, configured_max_tokens)
    return configured_max_tokens


def build_dspy_lm(config: dict[str, Any]) -> Any:
    configured_max_tokens = int(config["max_output_tokens"])
    return dspy.LM(
        config["dspy"],
        temperature=config["temperature"],
        reasoning_effort=config["reasoning"],
        max_tokens=provider_constructor_max_tokens(
            config["dspy"], configured_max_tokens
        ),
        cache=False,
    )


def execute(payload: dict[str, Any]) -> dict[str, Any]:
    row = payload["row"]
    approach = payload["approach"]
    manifest = payload["manifest"]
    settings = manifest["approaches"][approach]["settings"]
    pricing = settings["reservation_pricing"]
    limits = remaining(payload["budget_remaining"])
    ledger = {
        "requests": 0, "root_calls": 0, "sub_calls": 0,
        "input_tokens": 0, "output_tokens": 0, "usd": 0.0,
        "_reserved_input": 0, "_reserved_output": 0, "_reserved_usd": 0.0,
    }
    ledger_lock = threading.Lock()

    root_cfg = manifest["models"]["root"]
    sub_role = "compaction" if approach == "compaction" else "submodel"
    sub_cfg = manifest["models"][sub_role]
    root = BudgetLM(
        build_dspy_lm(root_cfg),
        ledger, limits, pricing, root_cfg["max_output_tokens"], "root", ledger_lock,
    )
    sub = BudgetLM(
        build_dspy_lm(sub_cfg),
        ledger, limits, pricing, sub_cfg["max_output_tokens"], "sub", ledger_lock,
    )
    dspy.configure(lm=root)
    started = time.perf_counter()

    if approach == "direct":
        pred = dspy.Predict("context, question, choices -> answer")(context=context_text(row), question=row["question"], choices=row.get("choices", []))
        answer, shape, trace = prediction_answer(pred), ["predict:direct"], []
    elif approach == "simple_retrieval":
        selected = lexical_retrieval(row, int(settings.get("k", 8)))
        pred = dspy.Predict("context, question, choices -> answer")(context=selected, question=row["question"], choices=row.get("choices", []))
        answer, shape, trace = prediction_answer(pred), ["retrieve:lexical", "predict"], []
    elif approach == "compaction":
        text = context_text(row)
        size = int(settings.get("chunk_chars", 100_000))
        chunks = [text[i : i + size] for i in range(0, len(text), size)][: int(settings.get("max_chunks", 32))]
        summaries = []
        for chunk in chunks:
            with dspy.context(lm=sub):
                summaries.append(str(dspy.Predict("context -> summary")(context=chunk).summary))
        pred = dspy.Predict("context, question, choices -> answer")(context="\n\n".join(summaries), question=row["question"], choices=row.get("choices", []))
        answer, shape, trace = prediction_answer(pred), ["summarize"] * len(chunks) + ["predict"], []
    elif approach == "rlm":
        program = dspy.RLM("context, question, choices -> answer", sub_lm=sub, max_iterations=int(settings.get("max_iterations", 20)), max_llm_calls=int(settings.get("max_llm_calls", 50)))
        pred = program(context=context_text(row), question=row["question"], choices=row.get("choices", []))
        raw_trace = list(getattr(pred, "trajectory", []) or [])
        trace = bounded_trace(raw_trace)
        answer, shape = prediction_answer(pred), ["rlm:repl"] * max(1, len(raw_trace))
    else:
        raise CampaignError(f"unknown approach: {approach}")

    return {
        "answer": answer,
        "latency_ms": (time.perf_counter() - started) * 1000.0,
        "usage": auditable_usage(ledger),
        "trace_shape": shape,
        "trace": trace,
        "call_semantics": {
            "provider_calls": ledger["requests"],
            "root_calls": ledger["root_calls"],
            "sub_calls": ledger["sub_calls"],
            "max_llm_calls_scope": "subcalls_only" if approach == "rlm" else "not_applicable",
            "configured_max_depth": int(settings.get("recursion_depth", 0)) if approach == "rlm" else 0,
            "max_observed_depth": 1 if ledger["sub_calls"] > 0 else 0,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True)
    parser.add_argument("--response", required=True)
    args = parser.parse_args()
    payload = json.loads(Path(args.request).read_text(encoding="utf-8"))
    if getattr(dspy, "__version__", None) != "3.3.0b1":
        raise CampaignError(f"DSPy 3.3.0b1 required, got {getattr(dspy, '__version__', None)!r}")
    try:
        result = execute(payload)
    except CampaignError as error:
        usage = error.usage or {}
        approach = payload.get("approach", "")
        settings = payload.get("manifest", {}).get("approaches", {}).get(approach, {}).get("settings", {})
        result = {
            "status": "error",
            "error": str(error),
            "usage": usage,
            "call_semantics": {
                "provider_calls": usage.get("requests", 0),
                "root_calls": usage.get("root_calls", 0),
                "sub_calls": usage.get("sub_calls", 0),
                "max_llm_calls_scope": "subcalls_only" if approach == "rlm" else "not_applicable",
                "configured_max_depth": int(settings.get("recursion_depth", 0)) if approach == "rlm" else 0,
                "max_observed_depth": 1 if usage.get("sub_calls", 0) > 0 else 0,
            },
        }
    Path(args.response).write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
