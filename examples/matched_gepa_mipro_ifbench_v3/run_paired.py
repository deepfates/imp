#!/usr/bin/env python3
"""Fail-closed coordinator for the sealed Imp/DSPy matched treatment."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from decimal import Decimal
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MANIFEST = HERE / "contract.json"
TMP = ROOT / "tmp" / "matched_gepa_mipro_ifbench_v3"
DSPY_ROOT = ROOT / "tmp" / "dspy-3.2.1"
GEPA_ROOT = ROOT / "tmp" / "gepa-v0.1.4"
GEPA_ARTIFACT_ROOT = ROOT / "tmp" / "gepa-artifact"
MODIFIED_DSPY_ROOT = ROOT / "tmp" / "gepa-study-dspy"
UPSTREAM_PYTHON = ROOT / "tmp" / "dspy-parity-venv" / "bin" / "python"
IFBENCH_SITE_PACKAGES = (
    ROOT / "tmp" / "ifbench-parity-venv" / "lib" / "python3.13" / "site-packages"
)
IFBENCH_NLTK_DATA = ROOT / "tmp" / "ifbench-parity-venv" / "nltk_data"
IFBENCH_PYTHON = ROOT / "tmp" / "ifbench-parity-venv" / "bin" / "python"
PRIOR_SPEND_BOUND = Decimal("7.36267325")
WORKSHOP_CEILING = Decimal("100.00")
PREFLIGHT_PREFIX = "PAIRED_PREFLIGHT_JSON="


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(
        (path for path in root.rglob("*") if path.is_file()),
        key=lambda item: item.relative_to(root).as_posix(),
    ):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
        digest.update(b"\n")
    return digest.hexdigest()


def resolve(path: str) -> Path:
    return (HERE / path).resolve()


def delegated_upstream_source(manifest: dict[str, Any]) -> str:
    wrapper = HERE / "run_upstream.py"
    delegated = resolve(manifest["execution_base"]["runner_path"])
    require(
        sha256_file(delegated) == manifest["execution_base"]["runner_sha256"],
        "delegated v1 upstream implementation drift",
    )
    return wrapper.read_text() + "\n" + delegated.read_text()


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
    task_calls = (
        seed_count
        * runtime_count
        * sum(arm["task_logical"] for arm in ceilings.values())
    )
    optimizer_calls = (
        seed_count
        * runtime_count
        * sum(arm["optimizer_logical"] for arm in ceilings.values())
    )
    task_cost = Decimal(request["task"]["reservation_input_tokens"]) * Decimal(
        models["task"]["catalog_prompt_per_token"]
    ) + Decimal(request["task"]["max_tokens"]) * Decimal(
        models["task"]["catalog_completion_per_token"]
    )
    optimizer_cost = Decimal(
        request["optimizer"]["reservation_input_tokens"]
    ) * Decimal(models["optimizer"]["catalog_cache_write_per_token"]) + Decimal(
        request["optimizer"]["max_tokens"]
    ) * Decimal(models["optimizer"]["catalog_completion_per_token"])
    return task_cost * task_calls + optimizer_cost * optimizer_calls


def preflight_environment() -> dict[str, str]:
    env = dict(os.environ)
    env.pop("OPENROUTER_API_KEY", None)
    return env


def preflight_imp(expected_manifest_sha: str, expected_commit: str) -> dict[str, Any]:
    env = preflight_environment()
    env["MATCHED_IFBENCH_V3_EXPECTED_COMMIT"] = expected_commit
    completed = subprocess.run(
        ["mix", "run", "--no-start", "paired_preflight.exs"],
        cwd=HERE,
        env=env,
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
    require(
        report.get("manifest_sha256") == expected_manifest_sha, "Imp manifest drift"
    )
    require(report.get("source_commit") == expected_commit, "Imp source commit drift")
    require(
        report.get("provider_authority_present") is False,
        "Imp preflight had provider authority",
    )
    require(
        report.get("held_out_loaded") is False, "Imp preflight loaded held-out data"
    )
    return report


def preflight_upstream(manifest: dict[str, Any]) -> dict[str, Any]:
    expected = manifest["runtime_dependencies"]["upstream"]
    version = subprocess.check_output(
        [
            str(UPSTREAM_PYTHON),
            "-c",
            "import platform; print(platform.python_version())",
        ],
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
    require(
        sha256_file(resolve(ifbench["requirements_path"]))
        == ifbench["requirements_sha256"],
        "IFBench requirements digest drift",
    )
    require(
        IFBENCH_SITE_PACKAGES.resolve() == resolve(ifbench["site_packages_path"]),
        "IFBench site-packages path drift",
    )
    require(
        IFBENCH_NLTK_DATA.resolve() == resolve(ifbench["nltk_data_path"]),
        "IFBench NLTK data path drift",
    )
    require(
        tree_sha256(IFBENCH_NLTK_DATA) == ifbench["nltk_data_sha256"],
        "IFBench NLTK data drift",
    )
    probe = subprocess.check_output(
        [
            str(UPSTREAM_PYTHON),
            "-c",
            "import importlib.metadata as m,json,sys; sys.path.insert(0,sys.argv[1]); print(json.dumps({n:m.version(n) for n in json.loads(sys.argv[2])},sort_keys=True))",
            str(IFBENCH_SITE_PACKAGES),
            json.dumps(sorted(ifbench["packages"])),
        ],
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
        required = (
            {"max_tokens", "seed", "response_format"}
            if role == "task"
            else {"max_tokens", "temperature"}
        )
        eligible = [
            endpoint
            for endpoint in body.get("data", {}).get("endpoints", [])
            if endpoint.get("provider_name") == expected["endpoint_provider"]
            and endpoint.get("tag")
            in manifest["execution"]["openrouter"][f"{role}_order"]
            and Decimal(endpoint.get("pricing", {}).get("prompt", "Infinity"))
            <= Decimal(expected["catalog_prompt_per_token"])
            and Decimal(endpoint.get("pricing", {}).get("completion", "Infinity"))
            <= Decimal(expected["catalog_completion_per_token"])
            and required.issubset(set(endpoint.get("supported_parameters", [])))
        ]
        require(
            len(eligible) > 0,
            f"no current exact first-party {role} endpoint satisfies capability/price guard",
        )
        snapshots[role] = {
            "url": url,
            "logical_model": expected["logical"],
            "provider": expected["endpoint_provider"],
            "eligible": eligible,
            "sha256": hashlib.sha256(
                json.dumps(eligible, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
        }
    return snapshots


def compatibility_preflight() -> dict[str, Any]:
    require(Path.cwd().resolve() == ROOT, f"coordinator must run from {ROOT}")
    require(
        git(ROOT, "status", "--porcelain", "--untracked-files=all") == "",
        "Imp worktree is dirty",
    )
    manifest = json.loads(MANIFEST.read_text())
    manifest_sha = sha256_file(MANIFEST)
    require(
        manifest["launch_status"]
        in (
            "draft_unsealed_pending_compatibility_review",
            "blocked_live_preflight",
            "sealed",
            "stopped_incomplete_upstream_gepa_output_alignment",
        ),
        "manifest launch state drift",
    )
    paired_surface = manifest["paired_surface"]
    for name, binding in paired_surface.items():
        path = HERE / binding["path"]
        require(path.is_file(), f"paired surface {name} is absent")
        require(
            sha256_file(path) == binding["sha256"],
            f"paired surface {name} source drift",
        )
    gate_contract = manifest["provider_free_gate"]
    gate_source = HERE / gate_contract["source_path"]
    require(
        sha256_file(gate_source) == gate_contract["source_sha256"],
        "provider-free gate source drift",
    )
    require(
        git(MODIFIED_DSPY_ROOT, "rev-parse", "HEAD")
        == manifest["authorities"]["gepa_artifact_modified_dspy"]["resolved_commit"],
        "modified DSPy fork revision drift",
    )
    with tempfile.TemporaryDirectory(prefix="imp-ifbench-v3-gate-") as temporary:
        output = Path(temporary) / "result.json"
        completed = subprocess.run(
            [
                str(UPSTREAM_PYTHON),
                str(gate_source),
                "--dspy-root",
                str(DSPY_ROOT),
                "--gepa-root",
                str(GEPA_ROOT),
                "--gepa-artifact-root",
                str(GEPA_ARTIFACT_ROOT),
                "--modified-dspy-root",
                str(MODIFIED_DSPY_ROOT),
                "--ifbench-site-packages",
                str(IFBENCH_SITE_PACKAGES),
                "--require-clean",
                "--output",
                str(output),
            ],
            cwd=ROOT,
            env={**preflight_environment(), "NLTK_DATA": str(IFBENCH_NLTK_DATA)},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        require(
            completed.returncode == 0,
            f"provider-free compatibility gate failed:\n{completed.stderr}\n{completed.stdout}",
        )
        materialized = output.read_bytes()
        report = json.loads(materialized)
    require(
        report.get("status") == "pass", "provider-free compatibility gate status drift"
    )
    require(
        report.get("clean_tree_gate") == {"required": True, "passed": True},
        "clean-tree gate drift",
    )
    require(
        report.get("data", {}).get("held_out", {}).get("status")
        == "sealed_digest_retained_not_read_preselection",
        "provider-free gate touched held-out bytes",
    )
    result_sha = hashlib.sha256(materialized).hexdigest()
    require(
        result_sha == gate_contract["result_sha256"], "provider-free gate result drift"
    )
    failure_contract = manifest["failure_cardinality_compat"]
    failure_module = resolve(failure_contract["module_path"])
    failure_gate = resolve(failure_contract["gate_path"])
    require(
        sha256_file(failure_module) == failure_contract["module_sha256"],
        "failure-cardinality compatibility source drift",
    )
    require(
        sha256_file(failure_gate) == failure_contract["gate_sha256"],
        "failure-cardinality gate source drift",
    )
    with tempfile.TemporaryDirectory(prefix="imp-ifbench-v3-failure-gate-") as temporary:
        failure_output = Path(temporary) / "result.json"
        completed = subprocess.run(
            [
                str(UPSTREAM_PYTHON),
                str(failure_gate),
                "--dspy-root",
                str(DSPY_ROOT),
                "--gepa-root",
                str(GEPA_ROOT),
                "--output",
                str(failure_output),
            ],
            cwd=ROOT,
            env=preflight_environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        require(
            completed.returncode == 0,
            "failure-cardinality gate failed:\n"
            f"{completed.stderr}\n{completed.stdout}",
        )
        failure_materialized = failure_output.read_bytes()
        failure_report = json.loads(failure_materialized)
    require(
        failure_report.get("status") == "pass",
        "failure-cardinality gate status drift",
    )
    failure_result_sha = hashlib.sha256(failure_materialized).hexdigest()
    require(
        failure_result_sha == failure_contract["result_sha256"],
        "failure-cardinality gate result drift",
    )
    return {
        "status": "pass",
        "manifest_sha256": manifest_sha,
        "launch_commit": git(ROOT, "rev-parse", "HEAD"),
        "gate_source_sha256": gate_contract["source_sha256"],
        "gate_result_sha256": result_sha,
        "failure_cardinality_module_sha256": failure_contract["module_sha256"],
        "failure_cardinality_gate_source_sha256": failure_contract["gate_sha256"],
        "failure_cardinality_gate_result_sha256": failure_result_sha,
        "paired_surface": {
            name: binding["sha256"] for name, binding in sorted(paired_surface.items())
        },
        "provider_authority_present": False,
        "held_out_loaded": False,
    }


def preflight(preflight_only: bool) -> dict[str, Any]:
    compatibility = compatibility_preflight()
    require(
        os.environ.get("OPENROUTER_API_KEY", "").strip() != "",
        "OPENROUTER_API_KEY is absent",
    )
    manifest = json.loads(MANIFEST.read_text())
    manifest_sha = sha256_file(MANIFEST)
    require(
        manifest["launch_status"] in ("blocked_live_preflight", "sealed"),
        "manifest launch state drift",
    )
    if not preflight_only:
        require(manifest["launch_status"] == "sealed", "manifest is not sealed")
    require(
        "required repair ancestor d88a5f7e415925cd6f7264b88d6f37bc03f01b33"
        in manifest["source_commits"]["imp"],
        "Imp source binding drift",
    )
    subprocess.check_call(
        [
            "git",
            "-C",
            str(ROOT),
            "merge-base",
            "--is-ancestor",
            "d88a5f7e415925cd6f7264b88d6f37bc03f01b33",
            "HEAD",
        ]
    )
    require(
        git(GEPA_ROOT, "rev-parse", "HEAD")
        == manifest["authorities"]["gepa"]["commit"],
        "GEPA revision drift",
    )
    require(
        git(GEPA_ARTIFACT_ROOT, "rev-parse", "HEAD")
        == manifest["authorities"]["gepa_artifact"]["commit"],
        "GEPA artifact revision drift",
    )
    dspy_source = json.loads(
        resolve(manifest["authorities"]["dspy"]["source_manifest"]).read_text()
    )
    require(
        dspy_source["commit"] == manifest["authorities"]["dspy"]["commit"],
        "DSPy revision drift",
    )
    require(
        sha256_file(ROOT / "mix.lock")
        == manifest["runtime_dependencies"]["imp"]["mix_lock_sha256"],
        "root Mix lock drift",
    )
    require(
        sha256_file(HERE / "mix.lock")
        == manifest["runtime_dependencies"]["imp"]["consumer_mix_lock_sha256"],
        "consumer Mix lock drift",
    )

    for role in ("task", "optimizer"):
        model = manifest["models"][role]
        require(model["endpoint_provider"] != "", f"{role} endpoint provider absent")
        require(model["logical"] != "", f"{role} logical route absent")
    require(
        manifest["execution"]["openrouter"]["allow_fallbacks"] is False,
        "fallback routing enabled",
    )
    require(
        manifest["execution"]["data_collection"] == "deny",
        "privacy routing drift",
    )

    active = [
        TMP / "imp-result.json",
        TMP / "upstream-result.json",
        TMP / "imp-result.json.selection-sealed.json",
        TMP / "upstream-result.json.selection-sealed.json",
    ]
    require(
        not any(path.exists() for path in active),
        "active result/selection state is not empty",
    )
    require(
        not (TMP / "sealed").exists(), "active sealed artifact directory is not empty"
    )
    maximum = worst_case_usd(manifest)
    require(maximum == Decimal("74.55283200"), f"sealed maximum spend drift: {maximum}")
    require(
        PRIOR_SPEND_BOUND + maximum <= WORKSHOP_CEILING,
        "workshop spend ceiling would be exceeded",
    )

    imp = preflight_imp(manifest_sha, compatibility["launch_commit"])
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
    require(
        symmetry.returncode == 0, f"cross-runtime guard gate failed:\n{symmetry.stdout}"
    )
    symmetry_report = json.loads(symmetry.stdout)
    require(symmetry_report.get("status") == "pass", "cross-runtime guard status drift")

    imp_source = (HERE / "run_imp.exs").read_text()
    upstream_source = delegated_upstream_source(manifest)
    require(
        "wait_for_peer_selection!" in imp_source and "held_out_rows!" in imp_source,
        "Imp held-out barrier drift",
    )
    require(
        "wait_for_peer_selection" in upstream_source
        and "held_out_path" in upstream_source,
        "upstream held-out barrier drift",
    )
    require(
        'data_collection: "deny"' in imp_source
        and '"data_collection": "deny"' in upstream_source,
        "peer privacy routing drift",
    )
    catalog = live_catalog_snapshot(manifest)

    return {
        "status": "pass",
        "source_commit": compatibility["launch_commit"],
        "manifest_sha256": manifest_sha,
        "prior_spend_bound": str(PRIOR_SPEND_BOUND),
        "workshop_ceiling": str(WORKSHOP_CEILING),
        "treatment_maximum": str(maximum),
        "combined_maximum": str(PRIOR_SPEND_BOUND + maximum),
        "imp": imp,
        "upstream": upstream,
        "guard_equivalence": symmetry_report,
        "catalog_snapshot": catalog,
        "compatibility_gate": compatibility,
        "held_out_barrier": "peer-confirmed selection receipts required before either held-out loader",
    }


def stop_peer(process: subprocess.Popen[Any]) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)


def require_number(value: Any, label: str) -> float:
    require(
        isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0,
        f"{label} is not a nonnegative number",
    )
    return float(value)


def validate_rescue_accounting(
    runtime: str, result: dict[str, Any], manifest: dict[str, Any]
) -> dict[str, int]:
    accounting = result.get("rescue_accounting")
    require(
        isinstance(accounting, dict), f"{runtime} rescue lacks normalized accounting"
    )
    budgets = accounting.get("call_budgets")
    require(isinstance(budgets, list), f"{runtime} rescue budgets are not a list")
    expected_ceilings = manifest["execution"]["call_ceilings"]
    expected_seeds = set(manifest["seeds"])
    seen: set[tuple[int, str]] = set()
    total = 0
    transports = 0
    task_logical = 0
    optimizer_logical = 0
    for budget in budgets:
        require(isinstance(budget, dict), f"{runtime} rescue budget is malformed")
        seed = budget.get("seed")
        arm = budget.get("arm")
        require(
            seed in expected_seeds and arm in expected_ceilings,
            f"{runtime} rescue budget identity drift",
        )
        key = (seed, arm)
        require(key not in seen, f"{runtime} rescue budget is duplicated: {key!r}")
        seen.add(key)
        ceiling = budget.get("ceiling")
        counts = budget.get("counts")
        require(
            ceiling == expected_ceilings[arm],
            f"{runtime} rescue budget ceiling drift for {key!r}",
        )
        require(isinstance(counts, dict), f"{runtime} rescue counts are malformed")
        require(set(counts) == set(ceiling), f"{runtime} rescue count fields drift")
        require(
            all(
                isinstance(count, int)
                and not isinstance(count, bool)
                and 0 <= count <= ceiling[name]
                for name, count in counts.items()
            ),
            f"{runtime} rescue counts exceed the current contract",
        )
        require(
            counts["task_logical"] + counts["optimizer_logical"]
            == counts["total_logical"]
            == counts["transports"],
            f"{runtime} rescue logical/transport counts diverge",
        )
        require(
            isinstance(budget.get("refusal_count"), int)
            and budget["refusal_count"] >= 0,
            f"{runtime} rescue refusal count is malformed",
        )
        total += counts["total_logical"]
        transports += counts["transports"]
        task_logical += counts["task_logical"]
        optimizer_logical += counts["optimizer_logical"]

    ledger = accounting.get("ledger")
    require(isinstance(ledger, dict), f"{runtime} rescue lacks ledger summary")
    reserved_count = ledger.get("reserved")
    transmitted_count = ledger.get("transmitted")
    completed_count = ledger.get("completed")
    in_flight_count = ledger.get("in_flight")
    reserved_not_transmitted = ledger.get("reserved_not_transmitted")
    require(
        all(
            isinstance(count, int) and not isinstance(count, bool) and count >= 0
            for count in (
                reserved_count,
                transmitted_count,
                completed_count,
                in_flight_count,
                reserved_not_transmitted,
            )
        ),
        f"{runtime} rescue ledger counts are malformed",
    )
    raw_responses = (
        result.get("lm_results")
        if runtime == "imp"
        else result.get("response_ledger")
    )
    raw_transports = (
        result.get("transport_events") if runtime == "imp" else result.get("calls")
    )
    require(
        isinstance(raw_responses, list) and len(raw_responses) == completed_count,
        f"{runtime} rescue response ledger was not retained",
    )
    require(
        isinstance(raw_transports, list) and len(raw_transports) == transmitted_count,
        f"{runtime} rescue transport ledger was not retained",
    )
    require(
        reserved_count == total == transports,
        f"{runtime} rescue reservation ledger diverges from its bound budgets",
    )
    failed_count = ledger.get("failed", 0)
    require(
        isinstance(failed_count, int)
        and not isinstance(failed_count, bool)
        and failed_count >= 0,
        f"{runtime} rescue failed count is malformed",
    )
    require(
        completed_count + failed_count <= transmitted_count <= reserved_count
        and in_flight_count
        == transmitted_count - completed_count - failed_count
        and reserved_not_transmitted == reserved_count - transmitted_count,
        f"{runtime} rescue lifecycle ledger diverges",
    )
    if runtime == "upstream":
        require(
            ledger.get("transmission_observation")
            == "forward_finally_transport_bound",
            "upstream rescue lacks transport-bound lifecycle evidence",
        )
    return {
        "task_logical": task_logical,
        "optimizer_logical": optimizer_logical,
        "total_logical": total,
    }


def reservation_rates(manifest: dict[str, Any]) -> dict[str, Decimal]:
    request = manifest["execution"]["request"]
    models = manifest["models"]
    rates = {
        "task": Decimal(request["task"]["reservation_input_tokens"])
        * Decimal(models["task"]["catalog_prompt_per_token"])
        + Decimal(request["task"]["max_tokens"])
        * Decimal(models["task"]["catalog_completion_per_token"]),
        "optimizer": Decimal(request["optimizer"]["reservation_input_tokens"])
        * Decimal(models["optimizer"]["catalog_cache_write_per_token"])
        + Decimal(request["optimizer"]["max_tokens"])
        * Decimal(models["optimizer"]["catalog_completion_per_token"]),
    }
    require(
        rates == {"task": Decimal("0.007104"), "optimizer": Decimal("0.08064")},
        "manifest reservation rates drift",
    )
    return rates


def require_rescued_stop_artifacts(
    manifest: dict[str, Any], launch_commit: str
) -> None:
    manifest_sha = sha256_file(MANIFEST)
    gate_sha = manifest["provider_free_gate"]["result_sha256"]
    failure_gate_sha = manifest["failure_cardinality_compat"]["result_sha256"]
    expected_sources = {
        "imp": launch_commit,
        "dspy": manifest["authorities"]["dspy"]["commit"],
        "gepa": manifest["authorities"]["gepa"]["commit"],
    }
    rates = reservation_rates(manifest)
    runtime_maximum = worst_case_usd(manifest) / Decimal(2)
    require(runtime_maximum == Decimal("37.27641600"), "runtime reservation cap drift")
    tolerance = Decimal("0.000000001")
    for runtime in ("imp", "upstream"):
        path = TMP / f"{runtime}-result.json"
        require(path.is_file(), f"{runtime} did not rescue a stopped artifact")
        result = json.loads(path.read_text())
        require(
            result.get("status") == "stopped", f"{runtime} rescue status is not stopped"
        )
        require(
            result.get("manifest_sha256") == manifest_sha,
            f"{runtime} manifest binding drift",
        )
        require(
            result.get("provider_free_gate_result_sha256") == gate_sha,
            f"{runtime} provider-free gate binding drift",
        )
        require(
            result.get("failure_cardinality_gate_result_sha256")
            == failure_gate_sha,
            f"{runtime} failure-cardinality gate binding drift",
        )
        require(
            result.get("launch_commit") == launch_commit,
            f"{runtime} launch binding drift",
        )
        require(
            result.get("source_commits") == expected_sources,
            f"{runtime} source commit binding drift",
        )
        actual = require_number(result.get("actual_cost"), f"{runtime} actual cost")
        reserved = require_number(
            result.get("usd_reserved"), f"{runtime} reserved cost"
        )
        require(
            actual <= reserved + 1e-6,
            f"{runtime} actual cost exceeds its reserved cost",
        )
        counts = validate_rescue_accounting(runtime, result, manifest)
        expected_reserved = (
            Decimal(counts["task_logical"]) * rates["task"]
            + Decimal(counts["optimizer_logical"]) * rates["optimizer"]
        )
        reserved_decimal = Decimal(str(reserved))
        if counts["total_logical"] == 0:
            require(
                actual == 0 and reserved == 0,
                f"{runtime} empty ledgers carry nonzero cost",
            )
        else:
            require(
                actual > 0 or reserved > 0,
                f"{runtime} nonempty ledgers lack bound cost accounting",
            )
        require(
            abs(reserved_decimal - expected_reserved) <= tolerance,
            f"{runtime} reserved cost does not match manifest-bound calls",
        )
        require(
            reserved_decimal <= runtime_maximum + tolerance,
            f"{runtime} reserved cost exceeds the per-runtime maximum",
        )


def run_peers(launch_commit: str) -> int:
    manifest = json.loads(MANIFEST.read_text())
    env = dict(os.environ)
    env["MATCHED_IFBENCH_V3_EXPECTED_COMMIT"] = launch_commit
    env["IMP_MATCHED_IFBENCH_V3_OUTPUT"] = str(TMP / "imp-result.json")
    env["UPSTREAM_MATCHED_IFBENCH_V3_OUTPUT"] = str(TMP / "upstream-result.json")
    env["IMP_MATCHED_IFBENCH_V3_UPSTREAM_SELECTION"] = str(
        TMP / "upstream-result.json.selection-sealed.json"
    )
    env["UPSTREAM_MATCHED_IFBENCH_V3_IMP_SELECTION"] = str(
        TMP / "imp-result.json.selection-sealed.json"
    )
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
        require_rescued_stop_artifacts(manifest, launch_commit)
        return failure
    return 0


def coordinate(preflight_only: bool = False, compatibility_only: bool = False) -> int:
    if compatibility_only:
        print(
            json.dumps(compatibility_preflight(), indent=2, sort_keys=True), flush=True
        )
        return 0
    report = preflight(preflight_only)
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if preflight_only else run_peers(report["source_commit"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--compatibility-only", action="store_true")
    args = parser.parse_args()
    raise SystemExit(coordinate(args.preflight_only, args.compatibility_only))


if __name__ == "__main__":
    main()
