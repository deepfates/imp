#!/usr/bin/env python3
"""Observe pinned DSPy 3.2.1 Avatar actor semantics without a provider."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
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
    from dspy.predict.avatar.avatar import Avatar
    from dspy.predict.avatar.models import Action, Tool
except ModuleNotFoundError as error:
    raise SystemExit("DSPy 3.2.1 fixture environment is missing") from error
install_scrubbed_environment()

DEFAULT_CONFIG = ROOT / "benchmarks/config/avatar-actor-differential-v1.json"
COMMON_SCRIPT = ROOT / "scripts/dspy_avatar_differential_common.py"
CALLS: List[Dict[str, Any]] = []


class QA(dspy.Signature):
    """Answer the question using a tool when needed."""

    question: str = dspy.InputField()
    answer: str = dspy.OutputField()


class LookupRunner:
    def __init__(self, expected_query: str, output: str) -> None:
        self.expected_query = expected_query
        self.output = output

    def run(self, query: str) -> str:
        assert credential_names(dict(__import__("os").environ)) == []
        assert query == self.expected_query
        return self.output


class QueuedActor:
    def __init__(self, signature: Any, fixture: Dict[str, Any]) -> None:
        self.signature = signature
        self.fixture = fixture

    def __call__(self, **kwargs: Any) -> Any:
        from types import SimpleNamespace

        CALLS.append(dict(kwargs))
        index = len(CALLS)
        if index == 1:
            return SimpleNamespace(
                action_1=Action(
                    tool_name=self.fixture["tool_name"],
                    tool_input_query=self.fixture["tool_query"],
                )
            )
        if index == 2:
            return SimpleNamespace(
                action_2=Action(tool_name="Finish", tool_input_query="done")
            )
        if index == 3:
            return SimpleNamespace(answer=self.fixture["answer"])
        raise AssertionError(f"unexpected Avatar actor call {index}")


def observations(config: Dict[str, Any]) -> Dict[str, Any]:
    from types import SimpleNamespace

    fixture = config["fixture"]
    CALLS.clear()
    tool = Tool(
        tool=LookupRunner(fixture["tool_query"], fixture["tool_output"]),
        name=fixture["tool_name"],
        desc="Look up a capital",
    )
    # DSPy 3.2.1's Avatar source refers to a top-level TypedPredictor export
    # that is absent in the release initializer. Supply only the constructor
    # shape, then replace it with the deterministic actor below.
    dspy.TypedPredictor = lambda signature: SimpleNamespace(signature=signature)
    avatar = Avatar(QA, tools=[tool], max_iters=3)
    avatar.actor = QueuedActor(avatar.actor.signature, fixture)
    avatar.actor_clone = __import__("copy").deepcopy(avatar.actor)
    prediction = avatar(question=fixture["question"], max_iters=3)
    actions = [action.model_dump() for action in prediction.actions]
    result = {
        "answer": prediction.answer,
        "actor_call_count": len(CALLS),
        "finish_selected": len(CALLS) >= 2,
        "finalizer_received_tool_result": len(CALLS) == 3 and CALLS[2].get("result_1") == fixture["tool_output"],
        "recorded_actions": actions,
    }
    assert result == config["expected"]
    return result


def worker(config: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    observed = observations(config)
    return {
        "schema_version": 1,
        "runner": "python-dspy-avatar-actor-differential",
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
