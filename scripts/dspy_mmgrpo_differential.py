#!/usr/bin/env python3
"""Provider-free DSPy 3.2.1 mmGRPO semantic observation harness."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any


CREDENTIAL_MARKERS = (
    "API_KEY", "ACCESS_KEY", "ACCESS_TOKEN", "AUTHORIZATION", "AUTH_TOKEN",
    "BEARER_TOKEN", "CLIENT_SECRET", "CREDENTIAL", "DATABASE_URL", "PASSWORD",
    "PRIVATE_KEY", "SECRET", "TOKEN",
)


def credential_names() -> list[str]:
    names = []
    for name in os.environ:
        upper = name.upper()
        if upper == "PGPASSWORD" or any(
            upper == marker or upper.endswith("_" + marker)
            for marker in CREDENTIAL_MARKERS
        ):
            names.append(name)
    return sorted(names)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_source(config: dict[str, Any], root: Path) -> dict[str, Any]:
    source = config["source"]
    commit = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain"],
        check=True, capture_output=True, text=True,
    ).stdout
    if commit != source["commit"] or dirty:
        raise RuntimeError("DSPy authority checkout is not the pinned clean commit")
    for key in ("grpo_source", "upstream_test"):
        entry = source[key]
        if sha256(root / entry["path"]) != entry["sha256"]:
            raise RuntimeError(f"DSPy authority hash mismatch: {entry['path']}")
    return {"git_commit": commit, "git_clean": True, "distribution_version": source["version"]}


class FixtureJob:
    def __init__(self) -> None:
        self.steps: list[list[dict[str, Any]]] = []
        self.next_batch_id = 1

    def get_status(self) -> dict[str, Any]:
        value = {
            "pending_batch_ids": [self.next_batch_id, self.next_batch_id + 1],
            "status": "running",
        }
        self.next_batch_id += 2
        return value

    def step(self, train_data: list[dict[str, Any]], train_data_format: Any) -> None:
        del train_data_format
        self.steps.append(train_data)

    def terminate(self) -> None:
        return None


class FixtureLM:
    def __init__(self) -> None:
        self.cache = True
        self.model = "provider-free-fixture"
        self.job = FixtureJob()

    def reinforce(self, train_kwargs: dict[str, Any]) -> FixtureJob:
        del train_kwargs
        return self.job


def run_success_fixture(config: dict[str, Any]) -> dict[str, Any]:
    import dspy
    import dspy.teleprompt.grpo as grpo_module
    from dspy.teleprompt.grpo import GRPO

    fixture = config["fixture"]
    lm = FixtureLM()
    program = dspy.Predict("question -> answer")
    program.set_lm(lm)
    selected_ids: list[str] = []

    def bootstrap(program: Any, dataset: list[Any], **kwargs: Any) -> list[dict[str, Any]]:
        del kwargs
        predictor = program.predictors()[0]
        rows = []
        for sample_index, example in enumerate(dataset):
            train_id = example.question
            if sample_index < fixture["examples_per_step"]:
                selected_ids.append(train_id)
            prediction = dspy.Prediction(answer=f"{train_id}-{sample_index}")
            rows.append({
                "example_ind": sample_index % len(dataset[: fixture["examples_per_step"]]),
                "example": example,
                "prediction": prediction,
                "trace": [(predictor, {"question": train_id}, prediction)],
                "score": fixture["success_reward"],
            })
        return rows

    original = grpo_module.bootstrap_trace_data
    grpo_module.bootstrap_trace_data = bootstrap
    try:
        optimizer = GRPO(
            metric=lambda *_args: fixture["success_reward"],
            exclude_demos=True,
            num_threads=1,
            num_train_steps=fixture["num_train_steps"],
            num_dspy_examples_per_grpo_step=fixture["examples_per_step"],
            num_rollouts_per_grpo_step=fixture["rollouts_per_step"],
            seed=0,
        )
        trainset = [dspy.Example(question=value).with_inputs("question") for value in fixture["train_ids"]]
        optimizer.compile(program, trainset)
    finally:
        grpo_module.bootstrap_trace_data = original

    groups = [item["group"] for step in lm.job.steps for item in step]
    rewards = sorted({float(item["reward"]) for group in groups for item in group})
    return {
        "selected_id_counts": dict(sorted(Counter(selected_ids).items())),
        "selected_example_count": len(selected_ids),
        "successful_group_count": len(groups),
        "successful_group_size": min({len(group) for group in groups}),
        "successful_rewards": rewards,
    }


def run_format_failure_fixture(config: dict[str, Any]) -> dict[str, Any]:
    import dspy
    import dspy.teleprompt.grpo as grpo_module
    from dspy.teleprompt.bootstrap_trace import FailedPrediction
    from dspy.teleprompt.grpo import GRPO

    fixture = config["fixture"]
    lm = FixtureLM()
    program = dspy.Predict("question -> answer")
    program.set_lm(lm)

    def bootstrap(program: Any, dataset: list[Any], **kwargs: Any) -> list[dict[str, Any]]:
        del kwargs
        predictor = program.predictors()[0]
        rows = []
        for sample_index, example in enumerate(dataset):
            failed = FailedPrediction(completion_text="malformed", format_reward=None)
            rows.append({
                "example_ind": 0,
                "example": example,
                "prediction": failed,
                "trace": [(predictor, {"question": example.question}, failed)],
                "score": fixture["success_reward"],
            })
        return rows

    original = grpo_module.bootstrap_trace_data
    grpo_module.bootstrap_trace_data = bootstrap
    try:
        optimizer = GRPO(
            metric=lambda *_args: fixture["success_reward"],
            exclude_demos=True,
            num_threads=1,
            num_train_steps=1,
            num_dspy_examples_per_grpo_step=1,
            num_rollouts_per_grpo_step=fixture["rollouts_per_step"],
            format_failure_score=fixture["format_failure_reward"],
        )
        optimizer.compile(program, [dspy.Example(question="failed").with_inputs("question")])
    finally:
        grpo_module.bootstrap_trace_data = original

    group = lm.job.steps[0][0]["group"]
    return {
        "format_failure_group_size": len(group),
        "format_failure_rewards": sorted({float(item["reward"]) for item in group}),
    }


def run_predictor_fixture(config: dict[str, Any]) -> dict[str, Any]:
    import dspy
    import dspy.teleprompt.grpo as grpo_module
    from dspy.teleprompt.grpo import GRPO

    fixture = config["fixture"]
    lm = FixtureLM()

    class TwoPredictorProgram(dspy.Module):
        def __init__(self) -> None:
            super().__init__()
            self.first = dspy.Predict("question -> first")
            self.second = dspy.Predict("question -> second")
            self.set_lm(lm)

        def forward(self, question: str) -> Any:
            return dspy.Prediction(
                first=self.first(question=question).first,
                second=self.second(question=question).second,
            )

    program = TwoPredictorProgram()

    def bootstrap(program: Any, dataset: list[Any], **kwargs: Any) -> list[dict[str, Any]]:
        del kwargs
        first, second = program.predictors()
        rows = []
        for example in dataset:
            first_prediction = dspy.Prediction(first="one")
            second_prediction = dspy.Prediction(second="two")
            rows.append({
                "example_ind": 0,
                "example": example,
                "prediction": dspy.Prediction(first="one", second="two"),
                "trace": [
                    (first, {"question": example.question}, first_prediction),
                    (second, {"question": example.question}, second_prediction),
                ],
                "score": fixture["success_reward"],
            })
        return rows

    original = grpo_module.bootstrap_trace_data
    grpo_module.bootstrap_trace_data = bootstrap
    try:
        GRPO(
            metric=lambda *_args: fixture["success_reward"],
            exclude_demos=True,
            num_threads=1,
            num_train_steps=1,
            num_dspy_examples_per_grpo_step=1,
            num_rollouts_per_grpo_step=fixture["rollouts_per_step"],
        ).compile(program, [dspy.Example(question="attribution").with_inputs("question")])
    finally:
        grpo_module.bootstrap_trace_data = original

    groups = [item["group"] for step in lm.job.steps for item in step]
    contents = [item["completion"]["content"] for group in groups for item in group]
    names = [name for name in ("first", "second") if any(f"<{name}>" in value for value in contents)]
    return {"predictor_group_names": names}


def observations(config: dict[str, Any]) -> dict[str, Any]:
    os.environ["PYTHON_DOTENV_DISABLED"] = "1"
    os.environ["DOTENV_DISABLED"] = "1"
    if credential_names():
        raise RuntimeError("credential-shaped environment reached the DSPy harness")
    return {
        **run_success_fixture(config),
        **run_predictor_fixture(config),
        **run_format_failure_fixture(config),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    root = Path(os.environ.get("PYTHONPATH", "").split(os.pathsep)[0]).resolve()
    runtime = verify_source(config, root)
    observed = observations(config)
    if observed != config["fixture"]["expected"]:
        raise RuntimeError(f"DSPy mmGRPO observations differ: {observed!r}")
    print(json.dumps({
        "schema_version": 1,
        "fixture_id": config["fixture_id"],
        "status": "passing",
        "provider_free": True,
        "credential_environment": {"provider_credential_names_present": []},
        "runtime_identity": runtime,
        "observations": observed,
    }, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
