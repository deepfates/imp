#!/usr/bin/env python3
"""Observe pinned DSPy 3.2.1 BootstrapFewShot and RandomSearch without providers."""

from __future__ import annotations

import argparse
import contextlib
import io
import importlib.metadata
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "benchmarks/config/classical-optimizer-differential-v1.json"
DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
SETUP = """git clone https://github.com/stanfordnlp/dspy.git tmp/dspy-3.2.1
git -C tmp/dspy-3.2.1 checkout --detach 29448ae12756abdd14bd8796c819247ebb83673c
IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh"""
_CREDENTIAL_EXACT = {
    "ACCESS_TOKEN", "API_KEY", "AUTHORIZATION", "AUTH_TOKEN", "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AZURE_CLIENT_SECRET", "CREDENTIALS",
    "DATABASE_URL", "GOOGLE_APPLICATION_CREDENTIALS", "PASSWORD", "PGPASSWORD",
    "PRIVATE_KEY", "SECRET", "TOKEN",
}
_CREDENTIAL_SUFFIXES = (
    "_API_KEY", "_ACCESS_KEY", "_ACCESS_TOKEN", "_AUTH_TOKEN", "_CLIENT_SECRET",
    "_CREDENTIAL", "_CREDENTIALS", "_DATABASE_URL", "_PASSWORD", "_PRIVATE_KEY",
    "_SECRET", "_SECRET_KEY", "_TOKEN",
)


def credential_names(environment: Dict[str, str]) -> List[str]:
    return sorted(
        key for key in environment
        if key.upper() in _CREDENTIAL_EXACT or key.upper().endswith(_CREDENTIAL_SUFFIXES)
    )


def scrubbed_environment(environment: Dict[str, str]) -> Dict[str, str]:
    return {key: value for key, value in environment.items() if key not in credential_names(environment)}


_SANITIZED_ENVIRONMENT = scrubbed_environment(dict(os.environ))
os.environ.clear()
os.environ.update(_SANITIZED_ENVIRONMENT)
os.environ["PYTHON_DOTENV_DISABLED"] = "1"
os.environ["DOTENV_DISABLED"] = "1"
del _SANITIZED_ENVIRONMENT
try:
    import dspy
except ModuleNotFoundError as error:
    raise SystemExit(f"DSPy 3.2.1 fixture environment is missing. Exact setup:\n{SETUP}") from error
_SANITIZED_ENVIRONMENT = scrubbed_environment(dict(os.environ))
os.environ.clear()
os.environ.update(_SANITIZED_ENVIRONMENT)
del _SANITIZED_ENVIRONMENT


class FixtureLM(dspy.BaseLM):
    def __init__(self) -> None:
        super().__init__(model="fake/classical-optimizer-fixture", cache=False)
        self.questions: List[str] = []

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        assert credential_names(dict(os.environ)) == []
        content = "\n".join([str(prompt or "")] + [str(x.get("content", "")) for x in messages or []])
        matches = re.findall(r"\[\[ ## question ## \]\]\s*([^\n]+)", content)
        question = matches[-1].strip() if matches else "unknown"
        self.questions.append(question)
        answer = "constant" if question.startswith(("r", "v")) else "generated"
        output = f"[[ ## answer ## ]]\n{answer}\n[[ ## completed ## ]]"
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=output))],
            usage={}, model=self.model, _hidden_params={},
        )


class QA(dspy.Signature):
    question = dspy.InputField()
    answer = dspy.OutputField()


def examples(rows: List[Dict[str, str]]) -> List[Any]:
    return [dspy.Example(**row).with_inputs("question") for row in rows]


def demo_record(demo: Any) -> Dict[str, Any]:
    return {
        "question": demo.question,
        "answer": demo.answer,
        "augmented": bool(demo.get("augmented", False)),
    }


def bootstrap_observations(config: Dict[str, Any]) -> Dict[str, Any]:
    lm = FixtureLM()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())
    rows = examples(config["trainset"])
    compiled = dspy.BootstrapFewShot(
        metric=lambda example, prediction, trace=None: example.answer == prediction.answer,
        max_bootstrapped_demos=config["max_bootstrapped_demos"],
        max_labeled_demos=config["max_labeled_demos"],
        max_rounds=config["max_rounds"],
        max_errors=10,
    ).compile(dspy.Predict(QA), trainset=rows)
    demos = [demo_record(demo) for demo in compiled.demos]
    expected_questions = {row["question"] for row in config["trainset"]}
    teacher_questions = [question for question in lm.questions if question in expected_questions]
    return {
        "teacher_questions": teacher_questions,
        "accepted_questions": [demo["question"] for demo in demos if demo["augmented"]],
        "augmented_answers": [demo["answer"] for demo in demos if demo["augmented"]],
        "attempt_count": len(teacher_questions),
        "compiled_demo_count": len(demos),
    }


def random_search_observations(config: Dict[str, Any]) -> Dict[str, Any]:
    lm = FixtureLM()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())
    metric = lambda example, prediction, trace=None: example.answer == prediction.answer
    compiled = dspy.BootstrapFewShotWithRandomSearch(
        metric=metric,
        num_candidate_programs=config["num_candidate_programs"],
        max_bootstrapped_demos=config["max_bootstrapped_demos"],
        max_labeled_demos=config["max_labeled_demos"],
        max_rounds=config["max_rounds"],
        max_errors=10,
    ).compile(
        dspy.Predict(QA),
        trainset=examples(config["trainset"]),
        valset=examples(config["valset"]),
        restrict=config["restrict"],
    )
    candidates = compiled.candidate_programs
    kinds = {
        -3: "zero_shot", -2: "labels_only", -1: "unshuffled_bootstrap",
        0: "shuffled_bootstrap", 1: "shuffled_bootstrap", 2: "shuffled_bootstrap",
    }
    return {
        "candidate_seeds": list(config["restrict"]),
        "candidate_kinds": [kinds[seed] for seed in config["restrict"]],
        "ranked_seeds": [row["seed"] for row in candidates],
        "demo_counts": [len(row["program"].demos) for row in candidates],
        "scores": [float(row["score"]) for row in candidates],
        "subscores": [[float(score) for score in row["subscores"]] for row in candidates],
    }


def sha256(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def runtime_identity(fixture: Dict[str, Any]) -> Dict[str, Any]:
    source = fixture["source"]
    ledger_path = ROOT / "benchmarks/authorities.json"
    ledger = json.loads(ledger_path.read_text())
    family = next((item for item in ledger["families"] if item["id"] == source["authority_family"]), None)
    if family is None or any(source[key] != family["upstream_repository"][key] for key in ("repository", "version", "git_ref", "commit", "source_manifest")):
        raise SystemExit(f"fixture is not bound to the canonical DSPy authority. Exact setup:\n{SETUP}")
    manifest_path = ROOT / source["source_manifest"]["path"]
    manifest = json.loads(manifest_path.read_text())
    manifest_files = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
    if sha256(manifest_path) != source["source_manifest"]["sha256"] or len(manifest_files) != source["source_manifest"]["file_count"]:
        raise SystemExit(f"canonical DSPy authority manifest mismatch. Exact setup:\n{SETUP}")
    for key in ("bootstrap_source", "random_search_source"):
        entry = source[key]
        if manifest_files.get(entry["path"]) != entry["sha256"]:
            raise SystemExit(f"canonical DSPy source hash mismatch. Exact setup:\n{SETUP}")
    references = family["upstream_tests"]["references"]
    for key in ("bootstrap_upstream_test", "random_search_upstream_test"):
        entry = source[key]
        if f"{entry['path']}#sha256={entry['sha256']}" not in references:
            raise SystemExit(f"canonical DSPy upstream-test hash mismatch. Exact setup:\n{SETUP}")
    root = Path(dspy.__file__).resolve().parents[1]
    commit = git(root, "rev-parse", "HEAD")
    clean = git(root, "status", "--porcelain") == ""
    tag = git(root, "describe", "--tags", "--exact-match", "HEAD")
    if commit != DSPY_COMMIT or not clean or tag != fixture["source"]["version"]:
        raise SystemExit(f"unauthenticated DSPy checkout. Exact setup:\n{SETUP}")
    for relative, expected in manifest_files.items():
        path = root / relative
        if not path.is_file() or sha256(path) != expected:
            raise SystemExit(f"DSPy source materialization mismatch at {relative}. Exact setup:\n{SETUP}")
    for key in ("bootstrap_upstream_test", "random_search_upstream_test"):
        entry = source[key]
        if sha256(root / entry["path"]) != entry["sha256"]:
            raise SystemExit(f"DSPy upstream test mismatch at {entry['path']}. Exact setup:\n{SETUP}")
    return {
        "distribution_version": importlib.metadata.version("dspy"),
        "module_version": getattr(dspy, "__version__", None),
        "git_commit": commit,
        "git_clean": clean,
        "git_tag": tag,
        "source_root": str(root.relative_to(ROOT)),
        "authority_manifest_verified_files": len(manifest_files),
        "authority_manifest_sha256": sha256(manifest_path),
        "authority_ledger_sha256": sha256(ledger_path),
    }


def worker(fixture: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    # DSPy's optimizers print progress summaries. Keep the machine-readable
    # receipt on stdout and discard only those human progress messages.
    with contextlib.redirect_stdout(io.StringIO()):
        bootstrap = bootstrap_observations(fixture["bootstrap_few_shot"])
        random_search = random_search_observations(fixture["random_search"])
    assert bootstrap == fixture["bootstrap_few_shot"]["expected"]
    assert random_search == fixture["random_search"]["expected"]
    return {
        "schema_version": 1,
        "runner": "python-dspy-classical-optimizer-differential",
        "fixture_id": fixture["fixture_id"],
        "status": "passing",
        "source": fixture["source"],
        "runtime_identity": runtime_identity(fixture),
        "credential_environment": {"provider_credential_names_present": credential_names(dict(os.environ))},
        "fixture_identity": {"script_sha256": sha256(Path(__file__)), "config_sha256": sha256(config_path)},
        "observations": {"bootstrap_few_shot": bootstrap, "random_search": random_search},
        "scopes": fixture["scopes"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(args.config.read_text())
    if args.worker:
        report = worker(fixture, args.config)
    else:
        command = [sys.executable, str(Path(__file__)), "--worker", "--config", str(args.config)]
        completed = subprocess.run(command, capture_output=True, text=True, env=scrubbed_environment(dict(os.environ)))
        if completed.returncode:
            raise SystemExit(f"isolated classical optimizer worker failed:\n{completed.stderr}\n{completed.stdout}")
        report = json.loads(completed.stdout)
        report["isolation"] = {"isolated_process": True}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
