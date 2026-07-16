#!/usr/bin/env python3
"""Run a pinned, provider-free DSPy COPRO isolation differential."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import logging
import os
import re
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "test/fixtures/dspy_copro_isolation_differential.json"
REQUIRED_NOT_CLAIMED = {
    "exact Python RNG parity",
    "provider behavior or effectiveness",
    "full optimizer parity",
}
SETUP_INSTRUCTIONS = """git clone https://github.com/stanfordnlp/dspy.git tmp/dspy-3.2.1
git -C tmp/dspy-3.2.1 checkout --detach 29448ae12756abdd14bd8796c819247ebb83673c
IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh
PYTHONPATH=tmp/dspy-3.2.1 tmp/dspy-parity-venv/bin/python scripts/dspy_copro_isolation_differential.py"""

try:
    import dspy
except ModuleNotFoundError as error:
    raise SystemExit(f"DSPy 3.2.1 fixture environment is missing. Exact setup:\n{SETUP_INSTRUCTIONS}") from error


PROPOSAL_PATTERN = re.compile(
    r"\[\[ ## proposed_instruction ## \]\]\s*(.*?)\s*"
    r"\[\[ ## proposed_prefix_for_output_field ## \]\]\s*(.*?)\s*"
    r"\[\[ ## completed ## \]\]",
    re.DOTALL,
)


class PoisonLM(dspy.BaseLM):
    """Mutable state installed only in the parent to make leakage observable."""

    def __init__(self) -> None:
        super().__init__(model="fake/poisoned-parent-state", cache=False)

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        raise AssertionError("the poisoned parent LM must never receive a child request")


class FixtureLM(dspy.BaseLM):
    def __init__(self, fixture: Dict[str, Any]) -> None:
        super().__init__(model="fake/copro-isolation-fixture", cache=False)
        self.fixture = fixture
        self.transport_calls: List[Dict[str, Any]] = []

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        content = "\n".join(
            [str(prompt or "")]
            + [str(message.get("content", "")) for message in (messages or [])]
        )

        if "proposed_instruction" in content and "proposed_prefix_for_output_field" in content:
            requested = int(kwargs.get("n") or 1)
            choices = [
                SimpleNamespace(message=SimpleNamespace(content=proposal_response(item)))
                for item in self.fixture["proposals"]
            ]
            self.transport_calls.append(
                {"kind": "proposal", "requested_n": requested, "emitted_choice_count": len(choices)}
            )
            return response(choices)

        candidate_key = task_candidate_key(content, self.fixture)
        self.transport_calls.append({"kind": "task", "candidate_key": candidate_key})
        return response(
            [SimpleNamespace(message=SimpleNamespace(content=f"[[ ## answer ## ]]\n{candidate_key}"))]
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()

    fixture = json.loads(args.config.read_text())
    result = run_worker(fixture, args.config) if args.worker else run_isolated(fixture, args.config)
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(encoded)
    else:
        print(encoded, end="")
    return 0 if result["status"] == "passing" else 1


def run_isolated(fixture: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    """Install mutable state, then start COPRO in a fresh Python process."""
    dspy.configure(lm=PoisonLM(), adapter=dspy.ChatAdapter())
    command = [sys.executable, str(Path(__file__).resolve()), "--worker", "--config", str(config_path)]
    completed = subprocess.run(command, capture_output=True, text=True, env=os.environ.copy())
    if completed.returncode != 0:
        raise RuntimeError(
            "isolated DSPy COPRO worker failed:\n"
            f"stdout={completed.stdout}\nstderr={completed.stderr}"
        )

    worker = json.loads(completed.stdout)
    worker["isolation"] = {
        "isolated_process": worker.pop("worker_pid") != os.getpid(),
        "parent_poison_model": "fake/poisoned-parent-state",
        "worker_lm_model": worker.pop("worker_lm_model"),
        "poison_marker_seen": worker.pop("poison_marker_seen"),
    }
    return worker


def run_worker(fixture: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    runtime_identity = verify_pinned_source(fixture)
    logging.disable(logging.CRITICAL)

    not_claimed = set(fixture["scope"]["not_claimed"])
    assert REQUIRED_NOT_CLAIMED <= not_claimed, (
        "COPRO isolation evidence must retain its RNG, provider/effectiveness, "
        f"and full-parity exclusions; missing={sorted(REQUIRED_NOT_CLAIMED - not_claimed)!r}"
    )

    copro = fixture["copro"]
    lm = FixtureLM(fixture)
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())
    trainset = [dspy.Example(question="fixture", answer="base").with_inputs("question")]

    compiled = dspy.COPRO(
        metric=metric(fixture),
        breadth=copro["breadth"],
        depth=copro["depth"],
        track_stats=True,
    ).compile(
        dspy.Predict(QASignature),
        trainset=trainset,
        eval_kwargs={"display_progress": False, "display_table": 0, "num_threads": 1},
    )

    proposal_calls = observed_proposal_calls(lm.history)
    proposal_transport_calls = [call for call in lm.transport_calls if call["kind"] == "proposal"]
    task_requests = [call for call in lm.transport_calls if call["kind"] == "task"]
    candidate_programs = [candidate_record(candidate) for candidate in compiled.candidate_programs]
    latest = next(iter(compiled.results_latest.values()))
    best = next(iter(compiled.results_best.values()))
    expected = fixture["copro"]
    observed_proposal_order = [
        {"instruction": choice["instruction"], "prefix": choice["prefix"]}
        for call in proposal_calls
        for choice in call["responses"]
    ]
    observations = {
        "proposal_request_count": len(proposal_calls),
        "proposal_n": [call["requested_n"] for call in proposal_calls],
        "proposal_order": observed_proposal_order,
        "proposal_call_history": proposal_calls,
        "lm_history_call_count": len(lm.history),
        "evaluation_order": [request["candidate_key"] for request in task_requests],
        "candidate_program_order": [candidate["key"] for candidate in candidate_programs],
        "candidate_programs": candidate_programs,
        "candidate_program_count": len(candidate_programs),
        "total_calls": getattr(compiled, "total_calls", None),
        "results_latest": normalize_stats(latest),
        "results_best": normalize_stats(best),
    }

    assert observations["proposal_request_count"] == 1
    assert observations["proposal_n"] == [expected["breadth"] - 1]
    assert observations["proposal_order"] == expected["proposal_order"]
    assert len(proposal_transport_calls) == observations["proposal_request_count"]
    assert all(call["response_choice_count"] == call["requested_n"] for call in proposal_calls)
    assert all(
        transport["emitted_choice_count"] == observed["response_choice_count"]
        for transport, observed in zip(proposal_transport_calls, proposal_calls)
    )
    assert observations["evaluation_order"] == expected["evaluation_order"]
    assert observations["candidate_program_order"] == expected["candidate_program_order"]
    assert observations["candidate_program_count"] == expected["candidate_program_count"]
    assert observations["total_calls"] == expected["total_calls"]
    assert_stats(observations["results_latest"], expected["results_latest"])
    assert_stats(observations["results_best"], expected["results_best"])
    assert sum(candidate["key"] == "candidate_a" for candidate in candidate_programs) == 1

    return {
        "schema_version": 1,
        "fixture_id": fixture["fixture_id"],
        "status": "passing",
        "runner": "python-dspy-copro-isolation-differential",
        "source": fixture["source"],
        "runtime_identity": runtime_identity,
        "fixture_identity": {
            "script_sha256": sha256(Path(__file__).resolve()),
            "config_sha256": sha256(config_path),
        },
        "worker_pid": os.getpid(),
        "worker_lm_model": lm.model,
        "poison_marker_seen": any(
            "poisoned-parent-state" in json.dumps(call) for call in lm.transport_calls
        ),
        "observations": observations,
        "scope": fixture["scope"],
    }


class QASignature(dspy.Signature):
    """Answer the fixture question."""

    question = dspy.InputField()
    answer = dspy.OutputField()


def metric(fixture: Dict[str, Any]):
    scores = fixture["copro"]["scores"]

    def score(example, prediction, trace=None):  # noqa: ANN001
        return scores[str(getattr(prediction, "answer", ""))]

    return score


def proposal_response(item: Dict[str, Any]) -> str:
    return (
        "[[ ## proposed_instruction ## ]]\n"
        f"{item['instruction']}\n"
        "[[ ## proposed_prefix_for_output_field ## ]]\n"
        f"{item['prefix']}\n"
        "[[ ## completed ## ]]"
    )


def observed_proposal_calls(history: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    calls = []
    for history_index, entry in enumerate(history):
        content = "\n".join(str(message.get("content", "")) for message in entry.get("messages") or [])
        if "proposed_instruction" not in content or "proposed_prefix_for_output_field" not in content:
            continue

        responses = []
        for choice_index, output in enumerate(entry.get("outputs") or []):
            parsed = parse_proposal_output(str(output))
            parsed.update(
                {
                    "choice_index": choice_index,
                    "response_sha256": hashlib.sha256(str(output).encode("utf-8")).hexdigest(),
                }
            )
            responses.append(parsed)

        calls.append(
            {
                "history_index": history_index,
                "requested_n": int(entry.get("kwargs", {}).get("n") or 1),
                "response_choice_count": len(responses),
                "responses": responses,
            }
        )
    return calls


def parse_proposal_output(output: str) -> Dict[str, str]:
    match = PROPOSAL_PATTERN.search(output)
    if not match:
        raise AssertionError(f"DSPy LM history contained an unparseable proposal response: {output!r}")
    return {"instruction": match.group(1).strip(), "prefix": match.group(2).strip()}


def response(choices: List[Any]) -> Any:
    return SimpleNamespace(
        choices=choices,
        usage={},
        model="fake/copro-isolation-fixture",
        _hidden_params={},
    )


def task_candidate_key(content: str, fixture: Dict[str, Any]) -> str:
    candidates = fixture["proposals"] + [{"key": "base", "instruction": "Answer the fixture question."}]
    for item in sorted(candidates, key=lambda value: len(value["instruction"]), reverse=True):
        if item["instruction"] in content:
            return item["key"]
    raise AssertionError(f"fixture task request did not contain a known candidate instruction: {content}")


def candidate_record(candidate: Dict[str, Any]) -> Dict[str, Any]:
    predictor = candidate["program"].predictors()[0]
    signature = predictor.signature
    prefix = list(signature.fields.values())[-1].json_schema_extra.get("prefix", "")
    return {
        "key": instruction_key(signature.instructions),
        "instruction": signature.instructions,
        "prefix": prefix,
        "score": candidate["score"],
        "depth": candidate["depth"],
    }


def instruction_key(instruction: str) -> str:
    return {
        "Candidate A": "candidate_a",
        "Candidate B": "candidate_b",
        "Answer the fixture question.": "base",
    }[instruction]


def normalize_stats(stats: Dict[str, Any]) -> Dict[str, Any]:
    return {key: list(value) for key, value in stats.items()}


def assert_stats(actual: Dict[str, Any], expected: Dict[str, Any]) -> None:
    assert actual["depth"] == expected["depth"]
    for key in ("max", "average", "min", "std"):
        assert len(actual[key]) == len(expected[key])
        for actual_value, expected_value in zip(actual[key], expected[key]):
            assert abs(actual_value - expected_value) < 1e-12, (key, actual_value, expected_value)


def verify_pinned_source(fixture: Dict[str, Any]) -> Dict[str, Any]:
    source = fixture["source"]
    ledger_path = ROOT / "benchmarks/authorities.json"
    ledger = json.loads(ledger_path.read_text())
    family = next(
        (item for item in ledger["families"] if item["id"] == source["authority_family"]),
        None,
    )
    if family is None:
        raise setup_error(f"canonical authority family is missing: {source['authority_family']}")

    canonical = family["upstream_repository"]
    for key in ("repository", "version", "git_ref", "commit"):
        if source[key] != canonical[key]:
            raise setup_error(
                f"fixture source identity disagrees with canonical ledger field {key}: "
                f"fixture={source[key]!r}, ledger={canonical[key]!r}"
            )
    if source["source_manifest"] != canonical["source_manifest"]:
        raise setup_error("fixture source manifest reference disagrees with the canonical authority ledger")

    manifest_reference = source["source_manifest"]
    manifest_path = ROOT / manifest_reference["path"]
    if not manifest_path.is_file() or sha256(manifest_path) != manifest_reference["sha256"]:
        raise setup_error(f"canonical source manifest identity mismatch: {manifest_path}")

    manifest = json.loads(manifest_path.read_text())
    files = manifest.get("files", [])
    if manifest.get("commit") != source["commit"] or len(files) != manifest_reference["file_count"]:
        raise setup_error("canonical source manifest commit or file count mismatch")

    manifest_files = {entry["path"]: entry["sha256"] for entry in files}
    copro_source = source["copro_source"]
    if manifest_files.get(copro_source["path"]) != copro_source["sha256"]:
        raise setup_error("COPRO source identity is not present in the canonical source manifest")

    upstream_test = source["upstream_test"]
    upstream_test_reference = f"{upstream_test['path']}#sha256={upstream_test['sha256']}"
    if upstream_test_reference not in family["upstream_tests"]["references"]:
        raise setup_error("COPRO upstream test identity disagrees with the canonical authority ledger")

    target = Path(dspy.__file__).resolve().parents[1]
    if not (target / ".git").is_dir():
        raise setup_error(f"DSPy was not imported from the pinned source checkout: {target}")

    git_commit = git_output(target, ["rev-parse", "HEAD"])
    git_tag = git_output(target, ["describe", "--tags", "--exact-match", "HEAD"])
    git_status = git_output(target, ["status", "--porcelain=v1", "--untracked-files=all"])
    if git_commit != source["commit"] or git_tag != source["version"] or git_status:
        raise setup_error(
            "DSPy source checkout is not the clean canonical release: "
            f"commit={git_commit!r}, tag={git_tag!r}, dirty={bool(git_status)}"
        )

    for relative, expected_hash in manifest_files.items():
        path = target / relative
        if not path.is_file() or sha256(path) != expected_hash:
            raise setup_error(f"DSPy source manifest mismatch at {relative}")

    upstream_test_path = target / upstream_test["path"]
    if not upstream_test_path.is_file() or sha256(upstream_test_path) != upstream_test["sha256"]:
        raise setup_error(f"DSPy upstream test mismatch at {upstream_test['path']}")

    distribution_version = importlib.metadata.version("dspy")
    if distribution_version != source["version"]:
        raise setup_error(
            f"isolated Python environment has dspy {distribution_version!r}; expected {source['version']!r}"
        )

    return {
        "distribution_version": distribution_version,
        "module_version": getattr(dspy, "__version__", None),
        "source_root": str(target.relative_to(ROOT)),
        "git_commit": git_commit,
        "git_tag": git_tag,
        "git_clean": True,
        "authority_manifest_sha256": sha256(manifest_path),
        "authority_manifest_verified_files": len(files),
        "authority_ledger_sha256": sha256(ledger_path),
    }


def git_output(root: Path, args: List[str]) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise setup_error(
            f"failed to verify DSPy source checkout with git {' '.join(args)}: {completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def setup_error(message: str) -> RuntimeError:
    return RuntimeError(f"{message}\nExact setup:\n{SETUP_INSTRUCTIONS}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
