#!/usr/bin/env python3
"""Fail-closed coordinator for the sealed Imp/DSPy matched treatment."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import sys
import time
from decimal import Decimal
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MANIFEST = HERE / "contract.json"
TMP = ROOT / "tmp" / "matched_instruction_optimizers_trec"
DSPY_ROOT = ROOT / "tmp" / "dspy-3.2.1"
GEPA_ROOT = ROOT / "tmp" / "gepa-v0.1.4"
UPSTREAM_PYTHON = ROOT / "tmp" / "dspy-parity-venv" / "bin" / "python"
PRIOR_SPEND_BOUND = Decimal("3.08335175")
WORKSHOP_CEILING = Decimal("100.00")
PREFLIGHT_PREFIX = "PAIRED_PREFLIGHT_JSON="


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve(path: str) -> Path:
    return (HERE / path).resolve()


def git(path: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), *args], text=True, stderr=subprocess.STDOUT
    ).strip()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def worst_case_usd(manifest: dict[str, Any]) -> Decimal:
    request = manifest["execution"]["request"]
    models = manifest["models"]
    ceilings = manifest["execution"]["call_ceilings"]
    seed_count = len(manifest["seeds"])
    runtime_count = 2
    task_calls = seed_count * runtime_count * sum(
        arm["task_logical"] for arm in ceilings.values()
    )
    optimizer_calls = seed_count * runtime_count * sum(
        arm["optimizer_logical"] for arm in ceilings.values()
    )
    task_cost = (
        Decimal(request["task"]["reservation_input_tokens"])
        * Decimal(models["task"]["catalog_prompt_per_token"])
        + Decimal(request["task"]["max_tokens"])
        * Decimal(models["task"]["catalog_completion_per_token"])
    )
    optimizer_cost = (
        Decimal(request["optimizer"]["reservation_input_tokens"])
        * Decimal(models["optimizer"]["catalog_cache_write_per_token"])
        + Decimal(request["optimizer"]["max_tokens"])
        * Decimal(models["optimizer"]["catalog_completion_per_token"])
    )
    return task_cost * task_calls + optimizer_cost * optimizer_calls


def preflight_environment() -> dict[str, str]:
    env = dict(os.environ)
    env.pop("OPENROUTER_API_KEY", None)
    return env


def preflight_imp(expected_manifest_sha: str) -> dict[str, Any]:
    completed = subprocess.run(
        ["mix", "run", "--no-start", "paired_preflight.exs"],
        cwd=HERE,
        env=preflight_environment(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    require(completed.returncode == 0, f"Imp preflight failed:\n{completed.stdout}")
    payloads = [
        line.removeprefix(PREFLIGHT_PREFIX)
        for line in completed.stdout.splitlines()
        if line.startswith(PREFLIGHT_PREFIX)
    ]
    require(len(payloads) == 1, "Imp preflight did not emit exactly one report")
    report = json.loads(payloads[0])
    require(report.get("status") == "pass", "Imp preflight status drift")
    require(report.get("cwd") == str(HERE), "Imp consumer cwd drift")
    require(report.get("manifest_sha256") == expected_manifest_sha, "Imp manifest drift")
    require(report.get("provider_authority_present") is False, "Imp preflight had provider authority")
    require(report.get("held_out_loaded") is False, "Imp preflight loaded held-out data")
    return report


def preflight_upstream(manifest: dict[str, Any]) -> dict[str, Any]:
    expected = manifest["runtime_dependencies"]["upstream"]
    version = subprocess.check_output(
        [str(UPSTREAM_PYTHON), "-c", "import platform; print(platform.python_version())"],
        text=True,
        env=preflight_environment(),
    ).strip()
    require(version == expected["python"], f"upstream Python drift: {version}")
    lock = resolve(expected["lock_path"])
    require(sha256_file(lock) == expected["lock_sha256"], "upstream lock digest drift")
    freeze = subprocess.check_output(
        [str(UPSTREAM_PYTHON), "-m", "pip", "freeze", "--all"],
        text=True,
        env=preflight_environment(),
    ).splitlines()
    require(
        ("\n".join(sorted(freeze)) + "\n").encode() == lock.read_bytes(),
        "upstream materialized environment differs from lock",
    )
    actual = {
        package: subprocess.check_output(
            [
                str(UPSTREAM_PYTHON),
                "-c",
                f"import importlib.metadata; print(importlib.metadata.version({package!r}))",
            ],
            text=True,
            env=preflight_environment(),
        ).strip()
        for package in expected["packages"]
    }
    require(actual == expected["packages"], f"upstream package drift: {actual!r}")
    return {
        "status": "pass",
        "python": version,
        "packages": actual,
        "provider_authority_present": False,
        "held_out_loaded": False,
    }


def preflight() -> dict[str, Any]:
    require(Path.cwd().resolve() == ROOT, f"coordinator must run from {ROOT}")
    require(os.environ.get("OPENROUTER_API_KEY", "").strip() != "", "OPENROUTER_API_KEY is absent")
    require(git(ROOT, "status", "--porcelain", "--untracked-files=all") == "", "Imp worktree is dirty")
    manifest = json.loads(MANIFEST.read_text())
    manifest_sha = sha256_file(MANIFEST)
    require(manifest["launch_status"] == "sealed", "manifest is not sealed")
    require(manifest["source_commits"]["imp"] == "resolved from clean launch git_sha", "Imp source binding drift")
    require(git(GEPA_ROOT, "rev-parse", "HEAD") == manifest["authorities"]["gepa"]["commit"], "GEPA revision drift")
    dspy_source = json.loads(resolve(manifest["authorities"]["dspy"]["source_manifest"]).read_text())
    require(dspy_source["commit"] == manifest["authorities"]["dspy"]["commit"], "DSPy revision drift")
    require(sha256_file(ROOT / "mix.lock") == manifest["runtime_dependencies"]["imp"]["mix_lock_sha256"], "root Mix lock drift")
    require(sha256_file(HERE / "mix.lock") == manifest["runtime_dependencies"]["imp"]["consumer_mix_lock_sha256"], "consumer Mix lock drift")

    for role in ("task", "optimizer"):
        model = manifest["models"][role]
        require(model["endpoint_provider"] != "", f"{role} endpoint provider absent")
        require(model["logical"] != "", f"{role} logical route absent")
    require(manifest["execution"]["openrouter"]["allow_fallbacks"] is False, "fallback routing enabled")

    active = [
        TMP / "imp-result.json",
        TMP / "upstream-result.json",
        TMP / "imp-result.json.selection-sealed.json",
        TMP / "upstream-result.json.selection-sealed.json",
    ]
    require(not any(path.exists() for path in active), "active result/selection state is not empty")
    require(not (TMP / "sealed").exists(), "active sealed artifact directory is not empty")
    stopped = {
        "pre_guard_equivalence": TMP / "upstream-result-pre-guard-equivalence-stopped.json",
        "pre_paired_coordinator_imp": TMP / "imp-result-pre-paired-coordinator-stopped.json",
        "pre_paired_coordinator_upstream": TMP / "upstream-result-pre-paired-coordinator-stopped.json",
    }
    require(all(path.is_file() for path in stopped.values()), "required stopped artifact is absent")
    require(
        Decimal(str(json.loads(stopped["pre_guard_equivalence"].read_text())["actual_cost"]))
        == Decimal("0.010035750000000001"),
        "pre-guard stopped cost drift",
    )
    require(
        Decimal(str(json.loads(stopped["pre_paired_coordinator_upstream"].read_text())["actual_cost"]))
        == Decimal("0.006646500000000001"),
        "pre-coordinator stopped cost drift",
    )

    maximum = worst_case_usd(manifest)
    require(maximum == Decimal("59.10912000"), f"sealed maximum spend drift: {maximum}")
    require(PRIOR_SPEND_BOUND + maximum <= WORKSHOP_CEILING, "workshop spend ceiling would be exceeded")

    imp = preflight_imp(manifest_sha)
    upstream = preflight_upstream(manifest)

    symmetry = subprocess.run(
        [sys.executable, str(HERE / "guard_equivalence.py")],
        cwd=ROOT,
        env=preflight_environment(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    require(symmetry.returncode == 0, f"cross-runtime guard gate failed:\n{symmetry.stdout}")
    symmetry_report = json.loads(symmetry.stdout)
    require(symmetry_report.get("status") == "pass", "cross-runtime guard status drift")

    imp_source = (HERE / "run_imp.exs").read_text()
    upstream_source = (HERE / "run_upstream.py").read_text()
    require("wait_for_peer_selection!" in imp_source and "held_out_rows!" in imp_source, "Imp held-out barrier drift")
    require("wait_for_peer_selection" in upstream_source and "held_out_path" in upstream_source, "upstream held-out barrier drift")

    return {
        "status": "pass",
        "source_commit": git(ROOT, "rev-parse", "HEAD"),
        "manifest_sha256": manifest_sha,
        "prior_spend_bound": str(PRIOR_SPEND_BOUND),
        "workshop_ceiling": str(WORKSHOP_CEILING),
        "treatment_maximum": str(maximum),
        "combined_maximum": str(PRIOR_SPEND_BOUND + maximum),
        "imp": imp,
        "upstream": upstream,
        "guard_equivalence": symmetry_report,
        "held_out_barrier": "peer-confirmed selection receipts required before either held-out loader",
    }


def stop_peer(process: subprocess.Popen[Any]) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)


def require_rescued_stop_artifacts() -> None:
    for runtime in ("imp", "upstream"):
        path = TMP / f"{runtime}-result.json"
        require(path.is_file(), f"{runtime} did not rescue a stopped artifact")
        result = json.loads(path.read_text())
        require(result.get("status") == "stopped", f"{runtime} rescue status is not stopped")
        require(
            isinstance(result.get("actual_cost"), (int, float)) and result["actual_cost"] >= 0,
            f"{runtime} rescue lacks actual cost",
        )
        require(
            isinstance(result.get("usd_reserved"), (int, float)) and result["usd_reserved"] >= 0,
            f"{runtime} rescue lacks reserved cost",
        )


def run_peers() -> int:
    env = dict(os.environ)
    env["IMP_MATCHED_TREC_OUTPUT"] = str(TMP / "imp-result.json")
    env["UPSTREAM_MATCHED_TREC_OUTPUT"] = str(TMP / "upstream-result.json")
    env["IMP_MATCHED_TREC_UPSTREAM_SELECTION"] = str(TMP / "upstream-result.json.selection-sealed.json")
    env["IMP_MATCHED_TREC_IMP_SELECTION"] = str(TMP / "imp-result.json.selection-sealed.json")
    (TMP / "sealed").mkdir(parents=True, exist_ok=False)
    peers = [
        subprocess.Popen(
            ["mix", "run", "run_imp.exs"],
            cwd=HERE,
            env=env,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        ),
        subprocess.Popen(
            [
                str(UPSTREAM_PYTHON),
                str(HERE / "run_upstream.py"),
                "--dspy-root",
                str(DSPY_ROOT),
                "--gepa-root",
                str(GEPA_ROOT),
            ],
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        ),
    ]
    failure: int | None = None
    try:
        while True:
            statuses = [peer.poll() for peer in peers]
            failures = [status for status in statuses if status not in (None, 0)]
            if failures:
                for peer in peers:
                    stop_peer(peer)
                failure = failures[0]
                break
            if all(status == 0 for status in statuses):
                break
            time.sleep(0.25)
    except BaseException:
        for peer in peers:
            stop_peer(peer)
        raise
    finally:
        for peer in peers:
            try:
                peer.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(peer.pid, signal.SIGKILL)
                peer.wait()
    if failure is not None:
        require_rescued_stop_artifacts()
        return failure
    return 0


def coordinate(preflight_only: bool = False) -> int:
    report = preflight()
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if preflight_only else run_peers()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    raise SystemExit(coordinate(args.preflight_only))


if __name__ == "__main__":
    main()
