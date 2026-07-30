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
import urllib.request
from decimal import Decimal
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MANIFEST = HERE / "contract.json"
TMP = ROOT / "tmp" / "matched_gepa_mipro_ifbench"
DSPY_ROOT = ROOT / "tmp" / "dspy-3.2.1"
GEPA_ROOT = ROOT / "tmp" / "gepa-v0.1.4"
GEPA_ARTIFACT_ROOT = ROOT / "tmp" / "gepa-artifact"
UPSTREAM_PYTHON = ROOT / "tmp" / "dspy-parity-venv" / "bin" / "python"
IFBENCH_SITE_PACKAGES = ROOT / "tmp" / "ifbench-parity-venv" / "lib" / "python3.13" / "site-packages"
IFBENCH_NLTK_DATA = ROOT / "tmp" / "ifbench-parity-venv" / "nltk_data"
IFBENCH_PYTHON = ROOT / "tmp" / "ifbench-parity-venv" / "bin" / "python"
PRIOR_SPEND_BOUND = Decimal("6.221975")
WORKSHOP_CEILING = Decimal("100.00")
PREFLIGHT_PREFIX = "PAIRED_PREFLIGHT_JSON="


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted((path for path in root.rglob("*") if path.is_file()), key=lambda item: item.relative_to(root).as_posix()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
        digest.update(b"\n")
    return digest.hexdigest()


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
    ifbench = manifest["runtime_dependencies"]["ifbench"]
    require(sha256_file(resolve(ifbench["requirements_path"])) == ifbench["requirements_sha256"], "IFBench requirements digest drift")
    require(IFBENCH_SITE_PACKAGES.resolve() == resolve(ifbench["site_packages_path"]), "IFBench site-packages path drift")
    require(IFBENCH_NLTK_DATA.resolve() == resolve(ifbench["nltk_data_path"]), "IFBench NLTK data path drift")
    require(tree_sha256(IFBENCH_NLTK_DATA) == ifbench["nltk_data_sha256"], "IFBench NLTK data drift")
    probe = subprocess.check_output(
        [str(UPSTREAM_PYTHON), "-c", "import importlib.metadata as m,json,sys; sys.path.insert(0,sys.argv[1]); print(json.dumps({n:m.version(n) for n in json.loads(sys.argv[2])},sort_keys=True))", str(IFBENCH_SITE_PACKAGES), json.dumps(sorted(ifbench["packages"]))],
        text=True,
        env=preflight_environment(),
    ).strip()
    require(json.loads(probe) == ifbench["packages"], "IFBench package drift")
    return {
        "status": "pass",
        "python": version,
        "packages": actual,
        "ifbench_packages": ifbench["packages"],
        "provider_authority_present": False,
        "held_out_loaded": False,
    }


def live_catalog_snapshot(manifest: dict[str, Any]) -> dict[str, Any]:
    snapshots: dict[str, Any] = {}
    for role in ("task", "optimizer"):
        expected = manifest["models"][role]
        url = f"https://openrouter.ai/api/v1/models/{expected['logical']}/endpoints"
        with urllib.request.urlopen(url, timeout=30) as response:
            body = json.load(response)
        required = {"max_tokens", "seed", "response_format"} if role == "task" else {"max_tokens", "temperature"}
        eligible = [
            endpoint for endpoint in body.get("data", {}).get("endpoints", [])
            if endpoint.get("provider_name") == expected["endpoint_provider"]
            and endpoint.get("tag") in manifest["execution"]["openrouter"][f"{role}_order"]
            and Decimal(endpoint.get("pricing", {}).get("prompt", "Infinity")) <= Decimal(expected["catalog_prompt_per_token"])
            and Decimal(endpoint.get("pricing", {}).get("completion", "Infinity")) <= Decimal(expected["catalog_completion_per_token"])
            and required.issubset(set(endpoint.get("supported_parameters", [])))
        ]
        require(len(eligible) > 0, f"no current exact first-party {role} endpoint satisfies capability/price guard")
        snapshots[role] = {
            "url": url,
            "logical_model": expected["logical"],
            "provider": expected["endpoint_provider"],
            "eligible": eligible,
            "sha256": hashlib.sha256(json.dumps(eligible, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        }
    return snapshots


def preflight(preflight_only: bool) -> dict[str, Any]:
    require(Path.cwd().resolve() == ROOT, f"coordinator must run from {ROOT}")
    require(os.environ.get("OPENROUTER_API_KEY", "").strip() != "", "OPENROUTER_API_KEY is absent")
    require(git(ROOT, "status", "--porcelain", "--untracked-files=all") == "", "Imp worktree is dirty")
    manifest = json.loads(MANIFEST.read_text())
    manifest_sha = sha256_file(MANIFEST)
    require(manifest["launch_status"] in ("blocked_live_preflight", "sealed"), "manifest launch state drift")
    if not preflight_only:
        require(manifest["launch_status"] == "sealed", "manifest is not sealed")
    require("required ancestor 88b630397e0ee65b13bd33cf337ce17099cdc89d" in manifest["source_commits"]["imp"], "Imp source binding drift")
    subprocess.check_call(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", "88b630397e0ee65b13bd33cf337ce17099cdc89d", "HEAD"])
    require(git(GEPA_ROOT, "rev-parse", "HEAD") == manifest["authorities"]["gepa"]["commit"], "GEPA revision drift")
    require(git(GEPA_ARTIFACT_ROOT, "rev-parse", "HEAD") == manifest["authorities"]["gepa_artifact"]["commit"], "GEPA artifact revision drift")
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
    maximum = worst_case_usd(manifest)
    require(maximum == Decimal("74.55283200"), f"sealed maximum spend drift: {maximum}")
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
    catalog = live_catalog_snapshot(manifest)

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
        "catalog_snapshot": catalog,
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
    env["IMP_MATCHED_IFBENCH_OUTPUT"] = str(TMP / "imp-result.json")
    env["UPSTREAM_MATCHED_IFBENCH_OUTPUT"] = str(TMP / "upstream-result.json")
    env["IMP_MATCHED_IFBENCH_UPSTREAM_SELECTION"] = str(TMP / "upstream-result.json.selection-sealed.json")
    env["IMP_MATCHED_IFBENCH_IMP_SELECTION"] = str(TMP / "imp-result.json.selection-sealed.json")
    env["IMP_GEPA_ARTIFACT_ROOT"] = str(GEPA_ARTIFACT_ROOT)
    env["IMP_GEPA_PYTHON"] = str(IFBENCH_PYTHON)
    env["IMP_IFBENCH_NLP_BRIDGE"] = str(ROOT / "scripts" / "ifbench_nlp_check.py")
    env["IMP_IFBENCH_NLP_PYTHON"] = str(IFBENCH_PYTHON)
    env["NLTK_DATA"] = str(IFBENCH_NLTK_DATA)
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
                "--gepa-artifact-root",
                str(GEPA_ARTIFACT_ROOT),
                "--ifbench-site-packages",
                str(IFBENCH_SITE_PACKAGES),
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
    report = preflight(preflight_only)
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if preflight_only else run_peers()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    raise SystemExit(coordinate(args.preflight_only))


if __name__ == "__main__":
    main()
