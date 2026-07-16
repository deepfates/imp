#!/usr/bin/env python3
"""Provider-free, source-authenticated DSPy ReAct failure-schedule runner."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import inspect
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "benchmarks/config/rag-tool-failure-differential-v1.json"
AUTHORITY_PATH = ROOT / "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
TAG = "3.2.1"
SENSITIVE_ENV_SUFFIXES = (
    "API_KEY",
    "ACCESS_KEY",
    "AUTH_TOKEN",
    "BEARER_TOKEN",
    "CLIENT_SECRET",
    "CREDENTIAL",
    "CREDENTIALS",
    "DATABASE_URL",
    "PASSWORD",
    "PRIVATE_KEY",
    "SECRET_KEY",
    "TOKEN",
    "COOKIE",
    "CONNECTION_STRING",
)


@dataclass
class FakeResponse:
    choices: list[Any]
    usage: dict[str, Any]
    model: str
    _hidden_params: dict[str, Any]


class FixtureTools:
    def __init__(self) -> None:
        self.unstable_attempts: dict[str, int] = {}
        self.idempotency_ledger: set[str] = set()

    def unstable_lookup(self, request_id: str) -> str:
        """Fail once for each request ID, then return the fixture passage answer."""

        attempts = self.unstable_attempts.get(request_id, 0) + 1
        self.unstable_attempts[request_id] = attempts
        if attempts == 1:
            raise RuntimeError("transient_failure")
        return "Paris"

    def timed_retriever(self, query: str) -> str:
        """Inject a fixture timeout observation for one retrieval request."""

        if query != "capital-france":
            raise ValueError("unexpected_query")
        raise TimeoutError("deadline_exceeded")

    def idempotent_lookup(self, idempotency_key: str) -> dict[str, str]:
        """Return a deterministic fresh/replay result using a fixture ledger."""

        status = "replay" if idempotency_key in self.idempotency_ledger else "fresh"
        self.idempotency_ledger.add(idempotency_key)
        return {"status": status, "value": "Paris"}

    def ghost_lookup(self, query: str) -> str:
        """Declared to the action signature, then removed from the runtime registry."""

        return query

    def broken_lookup(self, query: str) -> str:
        """Inject a permanent fixture failure."""

        if query != "capital-france":
            raise ValueError("unexpected_query")
        raise RuntimeError("permanent_failure")

    def stable_lookup(self, query: str) -> str:
        """Return the stable fixture passage answer."""

        if query != "capital-france":
            raise ValueError("unexpected_query")
        return "Paris"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out")
    parser.add_argument("--dspy-source", required=True)
    args = parser.parse_args()

    scrub = scrub_credentials_before_import()
    config = json.loads(CONFIG_PATH.read_text())
    source_root = Path(args.dspy_source).resolve()
    authenticated = authenticate_source_checkout(config, source_root)
    dspy = import_pinned_dspy(source_root)
    runtime = authenticate_imported_runtime(dspy, source_root, authenticated)
    assert_credentials_absent("after DSPy import")
    rows = [run_scenario(dspy, scenario) for scenario in config["scenarios"]]
    assert_credentials_absent("after DSPy execution")
    clean_after = git_output(source_root, ["status", "--porcelain=v1", "--untracked-files=all"])
    if clean_after:
        raise RuntimeError("DSPy source checkout became dirty during execution")
    report = {
        "schema_version": 1,
        "runner": "python-dspy-rag-tool-failure-differential",
        "protocol_id": config["protocol_id"],
        "dspy_version": runtime["distribution_version"],
        "credential_isolation": {
            "dummy_canary_present_before_scrub": scrub["dummy_canary_present"],
            "only_dummy_canary_present_before_scrub": scrub["only_dummy_canary_present"],
            "sensitive_values_present_after_scrub": False,
            "dotenv_disabled": os.environ.get("PYTHON_DOTENV_DISABLED") == "1",
            "checked_before_import": True,
            "checked_after_import": True,
            "checked_during_every_lm_call": True,
        },
        "source": {
            "repository": "stanfordnlp/dspy",
            "version": "3.2.1",
            "commit": COMMIT,
            "authority_sha256": file_sha256(AUTHORITY_PATH),
            "config_sha256": file_sha256(CONFIG_PATH),
            "script_sha256": file_sha256(Path(__file__)),
            "source_materialization": "clean_git_checkout_of_pinned_tag",
            "git_tag": TAG,
            "git_clean_before": True,
            "git_clean_after": True,
            "authority_manifest_verified_files": authenticated["verified_files"],
            "authority_manifest_sha256": file_sha256(AUTHORITY_PATH),
            "distribution_version": runtime["distribution_version"],
            "module_version": runtime["module_version"],
            "imported_from_pinned_checkout": True,
        },
        "rows": rows,
    }

    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        path = Path(args.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload)
        print(path)
    else:
        print(payload, end="")
    return 0


def authenticate_source_checkout(config: dict[str, Any], source_root: Path) -> dict[str, Any]:
    if not (source_root / ".git").is_dir():
        raise RuntimeError("DSPy runtime source is not a git checkout")
    authority = json.loads(AUTHORITY_PATH.read_text())
    if authority.get("commit") != COMMIT:
        raise RuntimeError("DSPy authority commit mismatch")
    if len(authority.get("files", [])) != 296:
        raise RuntimeError("DSPy authority does not contain the canonical 296-file manifest")
    commit = git_output(source_root, ["rev-parse", "HEAD"])
    tag = git_output(source_root, ["describe", "--tags", "--exact-match", "HEAD"])
    status = git_output(source_root, ["status", "--porcelain=v1", "--untracked-files=all"])
    if commit != COMMIT or tag != TAG or status:
        raise RuntimeError(
            f"DSPy checkout is not clean pinned {TAG}: commit={commit!r}, tag={tag!r}, dirty={bool(status)}"
        )
    for row in authority["files"]:
        path = source_root / row["path"]
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != row["sha256"]:
            raise RuntimeError(f"DSPy canonical manifest mismatch: {row['path']}")
    exercised = config["reference"]["exercised_sources"]
    manifest_paths = {row["path"] for row in authority["files"]}
    if any(path not in manifest_paths for path in exercised):
        raise RuntimeError("exercised DSPy source is absent from the canonical manifest")
    return {"commit": commit, "tag": tag, "verified_files": len(authority["files"])}


def import_pinned_dspy(source_root: Path):  # noqa: ANN201
    sys.path.insert(0, str(source_root))
    dspy = importlib.import_module("dspy")
    return dspy


def authenticate_imported_runtime(dspy, source_root: Path, authenticated: dict[str, Any]):  # noqa: ANN001,ANN201
    imported_root = Path(dspy.__file__).resolve().parents[1]
    if imported_root != source_root or authenticated["commit"] != COMMIT:
        raise RuntimeError("DSPy was not imported from the authenticated checkout")
    distribution_version = importlib.metadata.version("dspy")
    if distribution_version != TAG:
        raise RuntimeError(
            f"isolated Python distribution is {distribution_version!r}; expected {TAG!r}"
        )
    react_path = Path(inspect.getfile(dspy.ReAct)).resolve()
    tool_path = Path(inspect.getfile(dspy.Tool)).resolve()
    if react_path != source_root / "dspy/predict/react.py" or tool_path != source_root / "dspy/adapters/types/tool.py":
        raise RuntimeError("DSPy ReAct or Tool resolved outside the authenticated checkout")
    return {
        "distribution_version": distribution_version,
        "module_version": getattr(dspy, "__version__", None),
    }


def run_scenario(dspy, scenario: dict[str, Any]) -> dict[str, Any]:  # noqa: ANN001
    tools = FixtureTools()
    responses = [action_response(action) for action in scenario["actions"]]
    responses.append(extract_response(scenario["answer"]))
    lm = make_queue_lm(dspy, responses)
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())

    class FailureSignature(dspy.Signature):
        """Follow the preregistered tool trajectory and report its terminal result."""

        question = dspy.InputField()
        answer = dspy.OutputField()

    functions = [
        tools.unstable_lookup,
        tools.timed_retriever,
        tools.idempotent_lookup,
        tools.ghost_lookup,
        tools.broken_lookup,
        tools.stable_lookup,
    ]
    react = dspy.ReAct(FailureSignature, functions, max_iters=scenario["max_iters"])
    if scenario["id"] == "unknown_tool_then_finish":
        del react.tools["ghost_lookup"]

    prediction = react(question=scenario["id"])
    trace = normalize_trajectory(prediction.toDict().get("trajectory") or {})
    terminal = classify_terminal(trace, scenario["max_iters"], str(prediction.answer))
    return {
        "id": scenario["id"],
        "trace": trace,
        "terminal": terminal,
        "lm_calls": len(lm.history),
        "remaining_responses": len(lm.responses),
    }


def action_response(action: dict[str, Any]) -> str:
    return (
        "[[ ## next_thought ## ]]\nFollow the preregistered schedule.\n"
        f"[[ ## next_tool_name ## ]]\n{action['tool']}\n"
        f"[[ ## next_tool_args ## ]]\n{json.dumps(action['arguments'], sort_keys=True)}"
    )


def extract_response(answer: str) -> str:
    return f"[[ ## reasoning ## ]]\nNormalize the observed terminal.\n[[ ## answer ## ]]\n{answer}"


def normalize_trajectory(trajectory: dict[str, Any]) -> list[dict[str, Any]]:
    trace = []
    index = 0
    while f"tool_name_{index}" in trajectory:
        tool = trajectory[f"tool_name_{index}"]
        arguments = trajectory.get(f"tool_args_{index}", {})
        observation = trajectory.get(f"observation_{index}")
        trace.append(normalize_event(tool, arguments, observation))
        index += 1
    return trace


def normalize_event(tool: str, arguments: dict[str, Any], observation: Any) -> dict[str, Any]:
    base = {"tool": tool, "arguments": arguments}
    if tool == "finish" and observation == "Completed.":
        return {**base, "outcome": "terminal"}
    if tool == "unstable_lookup" and observation == "Paris":
        return {**base, "outcome": "success", "value": "Paris"}
    if tool == "stable_lookup" and observation == "Paris":
        return {**base, "outcome": "success", "value": "Paris"}
    if tool == "idempotent_lookup" and isinstance(observation, dict):
        if observation in (
            {"status": "fresh", "value": "Paris"},
            {"status": "replay", "value": "Paris"},
        ):
            return {**base, "outcome": observation["status"], "value": observation["value"]}
    if is_execution_error(observation, tool, "transient_failure"):
        return {**base, "outcome": "transient_error"}
    if is_execution_error(observation, tool, "deadline_exceeded"):
        return {**base, "outcome": "timeout_error"}
    if is_execution_error(observation, tool, "permanent_failure"):
        return {**base, "outcome": "permanent_error"}
    if tool == "ghost_lookup" and isinstance(observation, str):
        if observation.startswith("Execution error in ghost_lookup:") and "ghost_lookup" in observation:
            return {**base, "outcome": "unknown_tool_error"}
    return {**base, "outcome": "unrecognized", "observation_sha256": value_sha256(observation)}


def is_execution_error(observation: Any, tool: str, marker: str) -> bool:
    return (
        isinstance(observation, str)
        and observation.startswith(f"Execution error in {tool}:")
        and marker in observation
    )


def make_queue_lm(dspy, responses: list[str]):  # noqa: ANN001,ANN201
    class QueueLM(dspy.BaseLM):
        def __init__(self) -> None:
            super().__init__(model="fake/rag-tool-failure-differential", cache=False)
            self.responses = list(responses)

        def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001,ARG002
            assert_credentials_absent("during queued LM call")
            if not self.responses:
                raise RuntimeError("fixture response queue exhausted")
            content = self.responses.pop(0)
            return FakeResponse(
                choices=[SimpleNamespace(message=SimpleNamespace(content=content))],
                usage={},
                model=self.model,
                _hidden_params={},
            )

    return QueueLM()


def classify_terminal(trace: list[dict[str, Any]], max_iters: int, answer: str) -> dict[str, Any]:
    outcomes = [event.get("outcome") for event in trace]
    reason = "finish" if trace and trace[-1].get("outcome") == "terminal" else "max_iters"
    if reason == "max_iters" and len(trace) != max_iters:
        state = "invalid_terminal"
    elif "transient_error" in outcomes and "success" in outcomes:
        state = "recovered"
    elif "timeout_error" in outcomes:
        state = "timeout_observed"
    elif "unknown_tool_error" in outcomes:
        state = "unknown_observed"
    elif "permanent_error" in outcomes:
        state = "failure_observed"
    elif "fresh" in outcomes and "replay" in outcomes:
        state = "success"
    elif reason == "max_iters":
        state = "budget_exhausted"
    else:
        state = "invalid_terminal"
    return {"reason": reason, "state": state, "answer": answer}


def scrub_credentials_before_import() -> dict[str, Any]:
    names = sensitive_env_names()
    dummy_canary_present = "IMP_RAG_FAILURE_DUMMY_API_KEY" in os.environ
    only_dummy_canary_present = names == ["IMP_RAG_FAILURE_DUMMY_API_KEY"]
    for name in names:
        os.environ.pop(name, None)
    os.environ["PYTHON_DOTENV_DISABLED"] = "1"
    os.environ["DOTENV_DISABLED"] = "1"
    assert_credentials_absent("before DSPy import")
    return {
        "dummy_canary_present": dummy_canary_present,
        "only_dummy_canary_present": only_dummy_canary_present,
    }


def sensitive_env_names() -> list[str]:
    return sorted(
        name
        for name in os.environ
        if sensitive_env_name(name)
    )


def sensitive_env_name(name: str) -> bool:
    upper = name.upper()
    return upper == "PGPASSWORD" or any(
        upper == suffix or upper.endswith(f"_{suffix}") for suffix in SENSITIVE_ENV_SUFFIXES
    )


def assert_credentials_absent(stage: str) -> None:
    names = sensitive_env_names()
    if names:
        raise RuntimeError(f"credential-bearing environment was visible {stage}")


def git_output(root: Path, args: list[str]) -> str:
    process = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=False
    )
    if process.returncode != 0:
        raise RuntimeError(f"failed to authenticate DSPy checkout: {' '.join(args)}")
    return process.stdout.strip()


def value_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, default=str).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def file_sha256(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
