#!/usr/bin/env python3
"""Provider-free DSPy RAG/tool production-semantics sidecar."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional

import dspy


class QASignature(dspy.Signature):
    """Answer using the supplied context."""

    question = dspy.InputField()
    context = dspy.InputField()
    answer = dspy.OutputField()


class ToolSignature(dspy.Signature):
    """Use tools when useful and answer."""

    question = dspy.InputField()
    answer = dspy.OutputField()


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
    args = parser.parse_args()

    rows = [rag_row(), react_tool_row()]
    report = {
        "schema_version": 1,
        "runner": "python-dspy-rag-tool-agent",
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
