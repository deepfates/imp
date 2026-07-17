#!/usr/bin/env python3
"""Provider-free observations for pinned DSPy BootstrapFinetune/BetterTogether."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.metadata
import json
import os
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "benchmarks/config/weight-composition-differential-v1.json"
DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
SETUP = "IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh"
_EXACT = {"ACCESS_TOKEN", "API_KEY", "AUTHORIZATION", "AUTH_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AZURE_CLIENT_SECRET", "CREDENTIALS", "DATABASE_URL", "GOOGLE_APPLICATION_CREDENTIALS", "PASSWORD", "PGPASSWORD", "PRIVATE_KEY", "SECRET", "TOKEN"}
_SUFFIXES = ("_API_KEY", "_ACCESS_KEY", "_ACCESS_TOKEN", "_AUTH_TOKEN", "_CLIENT_SECRET", "_CREDENTIAL", "_CREDENTIALS", "_DATABASE_URL", "_PASSWORD", "_PRIVATE_KEY", "_SECRET", "_SECRET_KEY", "_TOKEN")


def credential_names(env: Dict[str, str]) -> List[str]:
    return sorted(k for k in env if k.upper() in _EXACT or k.upper().endswith(_SUFFIXES))


def scrubbed_environment(env: Dict[str, str]) -> Dict[str, str]:
    return {k: v for k, v in env.items() if k not in credential_names(env)}


_safe = scrubbed_environment(dict(os.environ))
os.environ.clear()
os.environ.update(_safe)
os.environ.update({"PYTHON_DOTENV_DISABLED": "1", "DOTENV_DISABLED": "1"})
del _safe
try:
    import dspy
    import dspy.teleprompt.bootstrap_finetune as bootstrap_module
    import dspy.teleprompt.bettertogether as together_module
except ModuleNotFoundError as error:
    raise SystemExit(f"DSPy fixture environment is missing. Exact setup: {SETUP}") from error
_safe = scrubbed_environment(dict(os.environ))
os.environ.clear()
os.environ.update(_safe)
del _safe


class RecordingAdapter:
    def format_finetune_data(self, signature, demos, inputs, outputs):  # noqa: ANN001
        return {"tag": signature, "inputs": inputs, "outputs": outputs}


class NoOpOptimizer(dspy.teleprompt.teleprompt.Teleprompter):
    def __init__(self, label: str):
        self.label = label

    def compile(self, student, **kwargs):  # noqa: ANN001
        result = student.deepcopy()
        result.history.append(self.label)
        return result


class FixtureProgram:
    def __init__(self):
        self.history: List[str] = []
        self._compiled = False

    def predictors(self):
        return []

    def deepcopy(self):
        return copy.deepcopy(self)


class ObservedBetterTogether(together_module.BetterTogether):
    def __init__(self, scores):  # noqa: ANN001
        super().__init__(metric=lambda *args: 1, p=NoOpOptimizer("p"), w=NoOpOptimizer("w"))
        self.scores = iter(scores)
        self.prefixes: List[str] = []

    def _evaluate_on_valset(self, *args, **kwargs):  # noqa: ANN001
        return next(self.scores)

    def _add_candidate(self, candidates, student, strategy, score):  # noqa: ANN001
        self.prefixes.append(strategy)
        return super()._add_candidate(candidates, student, strategy, score)


def bootstrap_observations() -> Dict[str, Any]:
    adapter = RecordingAdapter()
    lm = object()
    optimizer = bootstrap_module.BootstrapFinetune(multitask=False, adapter=adapter)
    first = SimpleNamespace(signature="first", demos=[])
    second = SimpleNamespace(signature="second", demos=[])
    trace = [{"trace": [(first, {"q": "q"}, {"a": "one"}), (second, {"q": "q"}, {"a": "two"})]}]
    original_infer = bootstrap_module.infer_data_format
    bootstrap_module.infer_data_format = lambda _adapter: "fixture"
    try:
        first_rows, _ = optimizer._prepare_finetune_data(trace, lm, pred_ind=0)
        second_rows, _ = optimizer._prepare_finetune_data(trace, lm, pred_ind=1)
    finally:
        bootstrap_module.infer_data_format = original_infer
    return {
        "shared": {"multitask_job_count": 1, "per_predictor_job_count": 2, "trace_call_members": ["first", "second"]},
        "dspy_deviation": {
            "requested_predictor_0_rows": [row["tag"] for row in first_rows],
            "requested_predictor_1_rows": [row["tag"] for row in second_rows],
            "cause": "pred_ind loop-variable shadowing in DSPy 3.2.1",
        },
    }


def better_together_observations(config: Dict[str, Any]) -> Dict[str, Any]:
    original_launch, original_kill = together_module.launch_lms, together_module.kill_lms
    together_module.launch_lms = lambda _program: None
    together_module.kill_lms = lambda _program: None
    try:
        validated = ObservedBetterTogether(config["scores"])
        steps = validated._prepare_strategy(config["strategy"])
        selected = validated._run_strategies(
            FixtureProgram(), [], None, [object()], None, 10, False, 0,
            steps, False, {},
        )
        no_validation = ObservedBetterTogether([None] * 4)
        latest = no_validation._run_strategies(
            FixtureProgram(), [], None, None, None, 10, False, 0,
            steps, False, {},
        )
    finally:
        together_module.launch_lms, together_module.kill_lms = original_launch, original_kill
    return {
        "shared": {
            "steps": steps,
            "candidate_prefixes": validated.prefixes,
            "selected_with_validation": " -> ".join(selected.history),
            "selected_without_validation": " -> ".join(latest.history),
            "earlier_tie_wins": " -> ".join(selected.history) == "p",
        }
    }


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_sha256(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(payload).hexdigest()


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


def runtime_identity(fixture: Dict[str, Any]) -> Dict[str, Any]:
    source = fixture["source"]
    ledger_path = ROOT / "benchmarks/authorities.json"
    ledger = json.loads(ledger_path.read_text())
    manifest_path = ROOT / source["source_manifest"]["path"]
    manifest = json.loads(manifest_path.read_text())
    manifest_files = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
    if sha256(manifest_path) != source["source_manifest"]["sha256"] or len(manifest_files) != source["source_manifest"]["file_count"]:
        raise SystemExit("DSPy authority manifest mismatch")
    for family in source["families"].values():
        authority = next((item for item in ledger["families"] if item["id"] == family["authority_family"]), None)
        if authority is None or any(source[k] != authority["upstream_repository"][k] for k in ("repository", "version", "git_ref", "commit", "source_manifest")):
            raise SystemExit("DSPy family authority mismatch")
        source_entry = family["source"]
        if manifest_files.get(source_entry["path"]) != source_entry["sha256"]:
            raise SystemExit(f"DSPy authority source mismatch: {source_entry['path']}")
        for key in ("source", "upstream_test"):
            entry = family[key]
            if sha256(Path(dspy.__file__).resolve().parents[1] / entry["path"]) != entry["sha256"]:
                raise SystemExit(f"DSPy materialized file mismatch: {entry['path']}")
        reference = f"{family['upstream_test']['path']}#sha256={family['upstream_test']['sha256']}"
        if reference not in authority["upstream_tests"]["references"]:
            raise SystemExit("DSPy upstream test is not ledger-bound")
    root = Path(dspy.__file__).resolve().parents[1]
    commit, clean, tag = git(root, "rev-parse", "HEAD"), git(root, "status", "--porcelain") == "", git(root, "describe", "--tags", "--exact-match", "HEAD")
    if commit != DSPY_COMMIT or not clean or tag != source["version"]:
        raise SystemExit(f"unauthenticated DSPy checkout. Exact setup: {SETUP}")
    for relative, expected in manifest_files.items():
        if not (root / relative).is_file() or sha256(root / relative) != expected:
            raise SystemExit(f"DSPy materialization mismatch: {relative}")
    family_hashes = {
        name: canonical_sha256(next(item for item in ledger["families"] if item["id"] == family["authority_family"]))
        for name, family in source["families"].items()
    }
    return {"distribution_version": importlib.metadata.version("dspy"), "module_version": getattr(dspy, "__version__", None), "git_commit": commit, "git_clean": clean, "git_tag": tag, "source_root": str(root.relative_to(ROOT)), "authority_manifest_verified_files": len(manifest_files), "authority_manifest_sha256": sha256(manifest_path), "authority_family_sha256": family_hashes}


def worker(fixture: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    bootstrap = bootstrap_observations()
    together = better_together_observations(fixture["better_together"])
    assert bootstrap["shared"] == fixture["bootstrap_finetune"]["expected_shared"]
    assert bootstrap["dspy_deviation"] == fixture["bootstrap_finetune"]["expected_dspy_deviation"]
    assert together["shared"] == fixture["better_together"]["expected_shared"]
    return {"schema_version": 1, "runner": "python-dspy-weight-composition-differential", "fixture_id": fixture["fixture_id"], "status": "passing", "provider_free": True, "source": fixture["source"], "runtime_identity": runtime_identity(fixture), "credential_environment": {"provider_credential_names_present": credential_names(dict(os.environ))}, "fixture_identity": {"script_sha256": sha256(Path(__file__)), "config_sha256": sha256(config_path)}, "observations": {"bootstrap_finetune": bootstrap, "better_together": together}, "scopes": fixture["scopes"]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--worker", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(args.config.read_text())
    if args.worker:
        report = worker(fixture, args.config)
    else:
        completed = subprocess.run([sys.executable, str(Path(__file__)), "--worker", "--config", str(args.config)], capture_output=True, text=True, env=scrubbed_environment(dict(os.environ)))
        if completed.returncode:
            raise SystemExit(f"isolated worker failed:\n{completed.stderr}\n{completed.stdout}")
        report = json.loads(completed.stdout)
        report["isolation"] = {"isolated_process": True}
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
