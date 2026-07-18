#!/usr/bin/env python3
"""Observe pinned DSPy 3.2.1 AvatarOptimizer semantics without a provider."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List

from dspy_avatar_differential_common import (
    ROOT,
    authenticate,
    credential_names,
    install_scrubbed_environment,
    run_isolated,
    sha256,
)

install_scrubbed_environment()
try:
    import dspy
    from dspy.predict.avatar.models import ActionOutput, Tool
    from dspy.teleprompt.avatar_optimizer import AvatarOptimizer, EvalResult
except (ModuleNotFoundError, AttributeError) as error:
    raise SystemExit("DSPy 3.2.1 AvatarOptimizer fixture environment is missing") from error
install_scrubbed_environment()

DEFAULT_CONFIG = ROOT / "benchmarks/config/avatar-optimizer-differential-v1.json"
COMMON_SCRIPT = ROOT / "scripts/dspy_avatar_differential_common.py"


class FakeSignature:
    def __init__(self, instructions: str) -> None:
        self.instructions = instructions

    def with_instructions(self, instructions: str) -> "FakeSignature":
        return FakeSignature(instructions)


class FakeStudent:
    def __init__(self, instruction: str) -> None:
        self.actor = SimpleNamespace(signature=FakeSignature(instruction))
        self.actor_clone = deepcopy(self.actor)
        self.tools = [Tool(tool=None, name="lookup", desc="Look up a capital")]


class CaptureComparator:
    def __init__(self, feedback: str) -> None:
        self.feedback = feedback
        self.calls: List[Dict[str, Any]] = []

    def __call__(self, **kwargs: Any) -> Any:
        assert credential_names(dict(__import__("os").environ)) == []
        self.calls.append(kwargs)
        return SimpleNamespace(feedback=self.feedback)


class CaptureRewriter:
    def __init__(self, instruction: str) -> None:
        self.instruction = instruction
        self.calls: List[Dict[str, Any]] = []

    def __call__(self, **kwargs: Any) -> Any:
        assert credential_names(dict(__import__("os").environ)) == []
        self.calls.append(kwargs)
        return SimpleNamespace(new_instruction=self.instruction)


def observations(config: Dict[str, Any]) -> Dict[str, Any]:
    fixture = config["fixture"]
    # AvatarOptimizer's constructor uses these top-level factories. Replace
    # only their deterministic fixture shape; no LM or provider is reachable.
    dspy.TypedPredictor = lambda _signature: None
    dspy.Predict = lambda _signature: None
    optimizer = AvatarOptimizer(
        metric=lambda _example, _prediction: 0.0,
        max_iters=1,
        lower_bound=fixture["lower_bound"],
        upper_bound=fixture["upper_bound"],
        max_positive_inputs=1,
        max_negative_inputs=1,
    )

    positive = EvalResult(
        example={"question": "easy"},
        score=fixture["positive_score"],
        actions=[ActionOutput(tool_name="lookup", tool_input_query="France", tool_output="Paris")],
    )
    negative = EvalResult(
        example={"question": "hard"},
        score=fixture["negative_score"],
        actions=[ActionOutput(tool_name="lookup", tool_input_query="wrong", tool_output="unknown")],
    )

    # Preserve actual threshold classification by feeding the evaluator rows
    # through _get_pos_neg_results rather than replacing that method.
    examples = [
        SimpleNamespace(inputs=lambda: SimpleNamespace(toDict=lambda: {"question": "easy"})),
        SimpleNamespace(inputs=lambda: SimpleNamespace(toDict=lambda: {"question": "hard"})),
    ]

    def evaluator_with_examples(_trainset: Any, _actor: Any, return_outputs: bool = False, num_threads: Any = None) -> Any:
        assert return_outputs
        return 0.5, [
            (examples[0], SimpleNamespace(actions=positive.actions), positive.score),
            (examples[1], SimpleNamespace(actions=negative.actions), negative.score),
        ]

    optimizer.thread_safe_evaluator = evaluator_with_examples
    comparator = CaptureComparator(fixture["feedback"])
    rewriter = CaptureRewriter(fixture["rewritten_instruction"])
    optimizer.comparator = comparator
    optimizer.feedback_instruction = rewriter

    with contextlib.redirect_stdout(io.StringIO()):
        compiled = optimizer.compile(FakeStudent(fixture["initial_instruction"]), trainset=examples)

    comparator_call = comparator.calls[0]
    rewriter_call = rewriter.calls[0]
    result = {
        "positive_count": len(comparator_call["pos_input_with_metrics"]),
        "negative_count": len(comparator_call["neg_input_with_metrics"]),
        "comparator_call_count": len(comparator.calls),
        "rewriter_call_count": len(rewriter.calls),
        "feedback_propagated": rewriter_call["feedback"] == fixture["feedback"],
        "final_instruction": compiled.actor.signature.instructions,
    }
    assert result == config["expected"]
    return result


def worker(config: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    observed = observations(config)
    return {
        "schema_version": 1,
        "runner": "python-dspy-avatar-optimizer-differential",
        "fixture_id": config["fixture_id"],
        "status": "passing",
        "source": config["source"],
        "runtime_identity": authenticate(config, dspy),
        "credential_environment": {"provider_credential_names_present": credential_names(dict(__import__("os").environ))},
        "fixture_identity": {
            "script_sha256": sha256(Path(__file__)),
            "common_script_sha256": sha256(COMMON_SCRIPT),
            "config_sha256": sha256(config_path),
        },
        "observations": observed,
        "scope": config["scope"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    report = worker(config, args.config) if args.worker else run_isolated(Path(__file__), args.config)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
