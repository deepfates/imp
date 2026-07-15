#!/usr/bin/env python3
"""Provider-free DSPy RAG/tool production-semantics sidecar."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional

import dspy

from dspy_parity_runner import configure_dspy, history_instrumentation, wire_api


LIVE_RAG_INSTRUCTION = "Answer using the supplied context. Return only the exact answer span."
LIVE_TOOL_INSTRUCTION = """First call lookup_capital with country "france". After its result is in history,
finish with answer exactly equal to that result. Never answer from memory and
never call lookup_capital more than once."""


class QASignature(dspy.Signature):
    """Answer using the supplied context."""

    question = dspy.InputField()
    context = dspy.InputField()
    answer = dspy.OutputField()


class ToolSignature(dspy.Signature):
    """Use tools when useful and answer."""

    question = dspy.InputField()
    answer = dspy.OutputField()


class LiveQASignature(dspy.Signature):
    __doc__ = LIVE_RAG_INSTRUCTION

    question = dspy.InputField()
    context = dspy.InputField()
    answer = dspy.OutputField(desc="exact answer span")


class LiveToolSignature(dspy.Signature):
    __doc__ = LIVE_TOOL_INSTRUCTION

    question = dspy.InputField()
    answer = dspy.OutputField(desc="exact tool result")


@dataclass
class FakeResponse:
    choices: list
    usage: dict
    model: str
    _hidden_params: dict


@dataclass
class Passage:
    long_text: str


class QueueLM(dspy.BaseLM):
    def __init__(self, responses: List[str]) -> None:
        super().__init__(model="fake/rag-tool-agent", cache=False)
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


class FakeRM:
    def __call__(self, query: str, k: int = 1, **kwargs):  # noqa: ANN001
        corpus = [
            "France capital: Paris.",
            "BEAM runs lightweight Elixir processes.",
        ]
        ranked = sorted(corpus, key=lambda text: overlap(query, text), reverse=True)
        return [Passage(text) for text in ranked[:k]]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--model")
    parser.add_argument("--api-key-env", default="OPENAI_API_KEY")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--max-tokens", type=int, default=400)
    parser.add_argument("--reasoning-effort")
    args = parser.parse_args()

    rows = [rag_row(), react_tool_row()]
    mode = "provider_free"

    if args.live:
        if not args.model:
            raise SystemExit("--model is required with --live")
        api_key = os.environ.get(args.api_key_env)
        if not api_key:
            raise SystemExit(f"{args.api_key_env} is required with --live")
        configure_dspy(
            args.model,
            api_key,
            args.temperature,
            args.max_tokens,
            args.reasoning_effort,
        )
        settings = live_settings(args)
        rows.extend([live_rag_row(args.model, settings), live_tool_row(args.model, settings)])
        mode = "live_matched"

    report = {
        "schema_version": 1,
        "runner": "python-dspy-rag-tool-agent",
        "mode": mode,
        "generated_at": timestamp(),
        "git_sha": git_sha(),
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "rows": rows,
    }

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.out)
    else:
        print(json.dumps(report, indent=2, sort_keys=True))

    return 0


def live_settings(args: argparse.Namespace) -> Dict[str, Any]:
    effective = {"max_tokens": args.max_tokens, "temperature": args.temperature}
    if provider(args.model) == "openai" and is_openai_reasoning_model(args.model):
        effective = {
            "max_completion_tokens": args.max_tokens,
            "reasoning_effort": args.reasoning_effort,
            "temperature": "provider_default",
        }
    elif args.reasoning_effort:
        effective["reasoning_effort"] = args.reasoning_effort

    return {
        "temperature": args.temperature,
        "max_tokens": args.max_tokens,
        "reasoning_effort": args.reasoning_effort,
        "effective_generation": effective,
        "cache": False,
        "max_iters": 4,
        "retrieval_k": 1,
    }


def live_rag_row(model: str, settings: Dict[str, Any]) -> Dict[str, Any]:
    before = len(dspy.settings.lm.history)
    try:
        retriever = FakeRM()
        context = retriever("What is France's capital?", k=settings["retrieval_k"])[0].long_text
        prediction = dspy.Predict(LiveQASignature)(
            question="What is France's capital?", context=context
        )
        answer = str(prediction.answer)
        usage = usage_since(before)
        return {
            "id": "live_rag_memory_retrieval",
            "category": "rag",
            "passing": answer == "Paris" and context == "France capital: Paris." and usage_complete(usage),
            "answer": answer,
            "retrieved": [{"id": "fr", "text": context}],
            "evidence": live_evidence(
                model, settings, usage, None, "rag-exact-context-v1", None
            ),
        }
    except Exception as exc:  # noqa: BLE001 - evidence must fail closed.
        usage = usage_since(before)
        error = bounded_error(exc)
        return {
            "id": "live_rag_memory_retrieval",
            "category": "rag",
            "passing": False,
            "answer": None,
            "error": error,
            "evidence": live_evidence(
                model, settings, usage, error, "rag-exact-context-v1", None
            ),
        }


def live_tool_row(model: str, settings: Dict[str, Any]) -> Dict[str, Any]:
    before = len(dspy.settings.lm.history)
    try:
        prediction = dspy.ReAct(
            LiveToolSignature, [lookup_capital], max_iters=settings["max_iters"]
        )(question="What is France's capital?")
        answer = str(prediction.answer)
        trace = normalize_tool_trace(prediction.toDict())
        usage = usage_since(before)
        expected = [
            {
                "tool": "lookup_capital",
                "arguments": {"country": "france"},
                "result": "Paris",
            }
        ]
        return {
            "id": "live_mcp_lookup_tool",
            "category": "tools",
            "passing": answer == "Paris" and trace == expected and usage_complete(usage),
            "answer": answer,
            "tool_trace": trace,
            "evidence": live_evidence(
                model,
                settings,
                usage,
                None,
                "lookup-capital-then-terminate-v1",
                "finish",
            ),
        }
    except Exception as exc:  # noqa: BLE001 - evidence must fail closed.
        usage = usage_since(before)
        error = bounded_error(exc)
        return {
            "id": "live_mcp_lookup_tool",
            "category": "tools",
            "passing": False,
            "answer": None,
            "error": error,
            "evidence": live_evidence(
                model,
                settings,
                usage,
                error,
                "lookup-capital-then-terminate-v1",
                "finish",
            ),
        }


def lookup_capital(country: str) -> str:
    """Look up the capital for one supported country key."""

    if country == "france":
        return "Paris"
    raise ValueError(f"unexpected country: {country}")


def usage_since(before: int) -> Dict[str, Any]:
    entries = dspy.settings.lm.history[before:]
    usage = {"requests": 0, "input_tokens": 0, "output_tokens": 0, "usd": 0.0}
    for entry in entries:
        values = history_instrumentation(entry)
        if all(values.get(key) is not None for key in ("input_tokens", "output_tokens", "usd")):
            usage["requests"] += 1
            usage["input_tokens"] += int(values["input_tokens"])
            usage["output_tokens"] += int(values["output_tokens"])
            usage["usd"] += float(values["usd"])
    return usage


def usage_complete(usage: Dict[str, Any]) -> bool:
    return (
        usage["requests"] > 0
        and usage["input_tokens"] > 0
        and usage["output_tokens"] > 0
        and usage["usd"] > 0
    )


def live_evidence(
    model: str,
    settings: Dict[str, Any],
    usage: Dict[str, Any],
    error: Optional[str],
    prompt_contract: str,
    termination_tool: Optional[str],
) -> Dict[str, Any]:
    return {
        "mode": "live",
        "provider": provider(model),
        "model_identity": model_identity(model),
        "runtime_model": model,
        "wire_api": wire_api(model),
        "generation": settings,
        "prompt_contract": prompt_contract,
        "termination_tool": termination_tool,
        "usage": usage,
        "usage_complete": usage_complete(usage),
        "error": error,
    }


def model_identity(model: str) -> str:
    normalized = model.strip().strip("/")
    for prefix in (
        "openai:", "openai/", "responses/", "anthropic:", "anthropic/",
        "gemini:", "gemini/", "google:", "google/",
    ):
        if normalized.startswith(prefix):
            normalized = normalized[len(prefix) :]
    return normalized


def provider(model: str) -> str:
    normalized = model.lower().strip()
    if normalized.startswith("anthropic/") or normalized.startswith("anthropic:"):
        return "anthropic"
    if normalized.startswith(("gemini/", "gemini:", "google/", "google:")):
        return "google"
    return "openai"


def is_openai_reasoning_model(model: str) -> bool:
    normalized = model_identity(model).lower()
    return normalized.startswith(("gpt-5", "o1", "o3", "o4"))


def bounded_error(exc: Exception) -> str:
    return f"{type(exc).__name__}: {exc}"[:2048]


def rag_row() -> Dict[str, Any]:
    lm = QueueLM(["[[ ## answer ## ]]\nParis"])
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter(), rm=FakeRM())

    retriever = dspy.Retrieve(k=1)
    retrieved = retriever("What is France's capital?")
    context = retrieved.passages[0]
    prediction = dspy.Predict(QASignature)(question="What is France's capital?", context=context)
    passed = prediction.answer == "Paris" and context == "France capital: Paris."

    return {
        "id": "rag_memory_retrieval",
        "category": "rag",
        "passing": passed,
        "answer": prediction.answer,
        "retrieved": retrieved.passages,
        "trace": {"lm_calls": len(lm.history), "remaining_responses": len(lm.responses)},
    }


def react_tool_row() -> Dict[str, Any]:
    responses = [
        "[[ ## next_thought ## ]]\nNeed lookup.\n[[ ## next_tool_name ## ]]\nlookup\n[[ ## next_tool_args ## ]]\n{\"query\":\"capital-france\"}",
        "[[ ## next_thought ## ]]\nHave enough.\n[[ ## next_tool_name ## ]]\nfinish\n[[ ## next_tool_args ## ]]\n{}",
        "[[ ## reasoning ## ]]\nThe lookup says Paris.\n[[ ## answer ## ]]\nParis",
    ]
    lm = QueueLM(responses)
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter(), rm=FakeRM())
    prediction = dspy.ReAct(ToolSignature, [lookup], max_iters=3)(question="What is France's capital?")
    trace = normalize_tool_trace(prediction.toDict())
    passed = prediction.answer == "Paris" and trace == [{"tool": "lookup", "arguments": {"query": "capital-france"}, "result": "Paris"}]

    return {
        "id": "react_lookup_tool",
        "category": "tools",
        "passing": passed,
        "answer": prediction.answer,
        "tool_trace": trace,
        "trace": {"lm_calls": len(lm.history), "remaining_responses": len(lm.responses)},
    }


def lookup(query: str) -> str:
    """Lookup a fact by query."""

    if query == "capital-france":
        return "Paris"
    raise ValueError(f"unexpected query: {query}")


def normalize_tool_trace(prediction: Dict[str, Any]) -> List[Dict[str, Any]]:
    trajectory = prediction.get("trajectory") or {}
    trace = []
    idx = 0
    while f"tool_name_{idx}" in trajectory:
        name = trajectory.get(f"tool_name_{idx}")
        if name != "finish":
            trace.append(
                {
                    "tool": name,
                    "arguments": trajectory.get(f"tool_args_{idx}", {}),
                    "result": trajectory.get(f"observation_{idx}"),
                }
            )
        idx += 1
    return trace


def overlap(query: str, text: str) -> int:
    query_terms = {term.lower().strip("?.:,") for term in query.split()}
    text_terms = {term.lower().strip("?.:,") for term in text.split()}
    return len(query_terms & text_terms)


def timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


if __name__ == "__main__":
    raise SystemExit(main())
