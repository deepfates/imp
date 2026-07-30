#!/usr/bin/env python3
"""Fail-closed coordinator for the sealed Imp/DSPy matched treatment."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import ssl
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
TMP = ROOT / "tmp" / "matched_gepa_mipro_ifbench_gepa014"
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
PRIOR_SPEND_BOUND = Decimal("7.59315275")
WORKSHOP_CEILING = Decimal("100.00")
SHADOW_PREFIX = "PAIRED_SHADOW_JSON="

sys.path.insert(0, str(HERE))
from peer_bootstrap import (  # noqa: E402
    MODE_SUBSTITUTION_KEYS,
    build_environment,
    canonical_digest,
    canonical_spec,
    live_mode,
    peer_commands,
    require_mode_equivalence,
    shadow_mode,
)


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
    for key in ("OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"):
        env.pop(key, None)
    env["LITELLM_LOCAL_MODEL_COST_MAP"] = "True"
    return env


def commands() -> dict[str, tuple[list[str], Path]]:
    return peer_commands(
        ROOT,
        HERE,
        UPSTREAM_PYTHON,
        DSPY_ROOT,
        GEPA_ROOT,
        GEPA_ARTIFACT_ROOT,
        IFBENCH_SITE_PACKAGES,
    )


def bootstrap_spec(launch_commit: str) -> dict[str, object]:
    return canonical_spec(
        ROOT,
        HERE,
        launch_commit,
        commands(),
        TMP,
        GEPA_ARTIFACT_ROOT,
        IFBENCH_PYTHON,
        IFBENCH_NLTK_DATA,
    )


def peer_environment(mode: Any, launch_commit: str) -> dict[str, str]:
    return build_environment(os.environ, bootstrap_spec(launch_commit), mode, launch_commit)


def system_ca_file() -> str:
    cafile = ssl.get_default_verify_paths().cafile
    require(cafile is not None and Path(cafile).is_file(), "system TLS CA file is absent")
    return str(Path(cafile).resolve())


def parse_shadow_report(output: str, runtime: str) -> dict[str, Any]:
    payloads = [
        line.removeprefix(SHADOW_PREFIX)
        for line in output.splitlines()
        if line.startswith(SHADOW_PREFIX)
    ]
    require(len(payloads) == 1, f"{runtime} shadow did not emit exactly one report")
    report = json.loads(payloads[0])
    require(report.get("status") == "pass", f"{runtime} shadow status drift")
    require(report.get("runtime") == runtime, f"{runtime} shadow identity drift")
    require(
        report.get("provider_authority_present") is False,
        f"{runtime} shadow had provider authority",
    )
    require(
        report.get("held_out_loaded") is False,
        f"{runtime} shadow loaded held-out data",
    )
    require(
        report.get("transport_roles") == ["task", "optimizer"]
        and report.get("transport_count") == 2,
        f"{runtime} shadow did not complete exactly one transport per role",
    )
    require(
        report.get("bootstrap_digest") is not None,
        f"{runtime} shadow omitted canonical bootstrap identity",
    )
    return report


def shadow_peer_preflight(manifest: dict[str, Any], launch_commit: str) -> dict[str, Any]:
    """Execute the production peer entries against one owned local TLS server."""

    with tempfile.TemporaryDirectory(prefix="imp-ifbench-gepa014-shadow-") as temporary:
        root = Path(temporary)
        ready = root / "ready.json"
        ledger = root / "ledger.json"
        server = subprocess.Popen(
            [
                sys.executable,
                str(HERE / "shadow_tls_server.py"),
                "--ready",
                str(ready),
                "--ledger",
                str(ledger),
            ],
            cwd=ROOT,
            env=preflight_environment(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 15
            while not ready.is_file():
                require(server.poll() is None, "local TLS shadow server exited before readiness")
                require(time.monotonic() < deadline, "local TLS shadow server readiness timed out")
                time.sleep(0.05)
            readiness = json.loads(ready.read_text())
            ca_cert = str(Path(readiness["ca_cert"]).resolve())
            env = peer_environment(shadow_mode(readiness["base_url"], ca_cert), launch_commit)
            require(env["OPENROUTER_API_KEY"] == "", "shadow environment retained provider authority")
            expected_digest = canonical_digest(bootstrap_spec(launch_commit))
            # Constructing live authority is deliberately in-memory only here. No
            # peer or network receives it until this exact equivalence gate passes.
            live_env = peer_environment(
                live_mode({"OPENROUTER_API_KEY": "<provider-authority>"}, system_ca_file()),
                launch_commit,
            )
            require_mode_equivalence(env, live_env)
            reports: dict[str, Any] = {}
            for runtime, (command, cwd) in commands().items():
                completed = subprocess.run(
                    command,
                    cwd=cwd,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                    timeout=120,
                )
                require(
                    completed.returncode == 0,
                    f"{runtime} exact-entry shadow failed:\n{completed.stdout}",
                )
                reports[runtime] = parse_shadow_report(completed.stdout, runtime)
                require(
                    reports[runtime]["bootstrap_digest"] == expected_digest,
                    f"{runtime} shadow bootstrap digest drift",
                )
            require(
                reports["imp"].get("applications_started")
                == {"ssl": True, "req": True, "imp": True},
                "Imp shadow reached transport before all required applications started",
            )
            require(
                sorted(reports["imp"].get("catalog_roles", []))
                == ["optimizer", "task"],
                "Imp shadow did not execute both catalog guards",
            )
            effective = manifest["authenticated_gepa_bridge"]["effective_identity"]
            observed = reports["upstream"].get("effective_gepa_identity", {})
            require(
                Path(observed.get("module_path", "")).resolve()
                == (ROOT / effective["module_path"]).resolve()
                and observed.get("source_commit") == effective["source_commit"]
                and observed.get("source_tree") == effective["source_tree"]
                and observed.get("init_sha256") == effective["init_sha256"]
                and observed.get("api_sha256") == effective["api_sha256"]
                and observed.get("optimize_signature_sha256")
                == effective["optimize_signature_sha256"],
                "upstream shadow effective GEPA source/API identity drift",
            )
            require(
                sorted(
                    item.get("version")
                    for item in observed.get("distribution_metadata", [])
                )
                == sorted(
                    [
                        effective["installed_distribution_version"],
                        effective["source_distribution_version"],
                    ]
                )
                and observed.get("module_version") == effective["module_version"],
                "upstream shadow GEPA distribution diagnostics drift",
            )
            require(
                sorted(reports["upstream"].get("catalog_roles", []))
                == ["optimizer", "task"],
                "upstream shadow did not execute both catalog guards",
            )
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait()
        require(ledger.is_file(), "local TLS shadow server did not retain a ledger")
        ledger_payload = json.loads(ledger.read_text())
        requests = ledger_payload.get("requests", [])
        posts = [request for request in requests if request.get("method") == "POST"]
        gets = [request for request in requests if request.get("method") == "GET"]
        require(len(gets) == 6, f"shadow readiness/catalog count drift: {len(gets)}")
        require(len(posts) == 4, f"shadow transport count drift: {len(posts)}")
        require(
            sorted(request.get("model") for request in posts)
            == [
                "anthropic/claude-sonnet-4.6",
                "anthropic/claude-sonnet-4.6",
                "openai/gpt-5.4-mini",
                "openai/gpt-5.4-mini",
            ],
            "shadow task/optimizer model identities drifted",
        )
        require(
            all(request.get("tls_version") in {"TLSv1.2", "TLSv1.3"} for request in requests),
            "shadow request bypassed TLS",
        )
        return {
            "status": "pass",
            "provider_authority_present": False,
            "held_out_loaded": False,
            "peers": reports,
            "readiness_and_catalog_requests": len(gets),
            "transport_requests": len(posts),
            "ledger_sha256": hashlib.sha256(ledger.read_bytes()).hexdigest(),
            "bootstrap_digest": expected_digest,
            "mode_difference_keys": sorted(require_mode_equivalence(env, live_env)),
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
    accepted_draft = manifest["accepted_successor_draft"]
    accepted_draft_path = resolve(accepted_draft["path"])
    require(
        sha256_file(accepted_draft_path) == accepted_draft["sha256"],
        "accepted successor draft drift",
    )
    bridge = manifest["authenticated_gepa_bridge"]
    require(
        sha256_file(resolve(bridge["path"])) == bridge["sha256"],
        "authenticated GEPA bridge drift",
    )
    require(
        git(DSPY_ROOT, "rev-parse", "HEAD")
        == manifest["authorities"]["dspy"]["commit"],
        "DSPy source revision drift",
    )
    require(
        git(GEPA_ROOT, "rev-parse", "HEAD")
        == manifest["authorities"]["gepa"]["commit"],
        "GEPA source revision drift",
    )
    for predecessor in ("v2", "v3"):
        expected_tree = manifest["immutable_predecessors"][predecessor]["tree"]
        actual_tree = git(
            ROOT,
            "rev-parse",
            f"HEAD^{{tree}}:examples/matched_gepa_mipro_ifbench_{predecessor}",
        )
        require(actual_tree == expected_tree, f"terminal {predecessor} tree drift")
    require(
        manifest["launch_status"]
        in (
            "draft_unsealed_pending_surface_review",
            "blocked_live_preflight",
            "sealed",
            "terminal_zero_call_stopped",
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
    with tempfile.TemporaryDirectory(prefix="imp-ifbench-gepa014-gate-") as temporary:
        output = Path(temporary) / "result.json"
        gate_env = {
            **preflight_environment(),
            "NLTK_DATA": str(IFBENCH_NLTK_DATA),
            "MATCHED_IFBENCH_GEPA014_EXPECTED_COMMIT": git(ROOT, "rev-parse", "HEAD"),
        }
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
            env=gate_env,
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
    with tempfile.TemporaryDirectory(
        prefix="imp-ifbench-gepa014-failure-gate-"
    ) as temporary:
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
    public_contract = manifest["public_workflow_compatibility"]
    for kind in ("gate", "test", "documentation"):
        path = resolve(public_contract[f"{kind}_path"])
        require(
            sha256_file(path) == public_contract[f"{kind}_sha256"],
            f"public-workflow {kind} source drift",
        )
    with tempfile.TemporaryDirectory(
        prefix="imp-ifbench-gepa014-public-workflow-"
    ) as temporary:
        public_output = Path(temporary) / "result.json"
        completed = subprocess.run(
            [
                str(UPSTREAM_PYTHON),
                str(resolve(public_contract["gate_path"])),
                "--dspy-root",
                str(DSPY_ROOT),
                "--gepa-root",
                str(GEPA_ROOT),
                "--output",
                str(public_output),
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
            "public GEPA/MIPRO workflow gate failed:\n"
            f"{completed.stderr}\n{completed.stdout}",
        )
        public_report = json.loads(public_output.read_text())
    effective_public = {
        "network_authority": public_report.get("network_authority"),
        "held_out_loaded": public_report.get("held_out_loaded"),
        "gepa_metric_calls": public_report.get("gepa", {}).get("total_metric_calls"),
        "gepa_candidates": public_report.get("gepa", {}).get("candidate_count"),
        "mipro_trials": public_report.get("mipro_v2", {}).get("trial_count"),
        "mipro_prompt_calls": public_report.get("mipro_v2", {}).get("prompt_calls"),
        "mipro_task_calls": public_report.get("mipro_v2", {}).get("task_calls"),
        "ordinary_evaluator_failure": public_report.get("mipro_v2", {}).get(
            "evaluator_failure_outcome"
        ),
        "operational_failure": public_report.get("mipro_v2", {}).get(
            "operational_failure"
        ),
    }
    require(
        effective_public == public_contract["required_result"],
        "public GEPA/MIPRO workflow semantics drift",
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
        "public_workflow_compatibility": effective_public,
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
    compatibility_commit = manifest["compatibility_boundary"]["imp_commit"]
    require(
        compatibility_commit == "10328114f96975ebccf71f57a052bfe045b99a88",
        "Imp compatibility boundary drift",
    )
    subprocess.check_call(
        [
            "git",
            "-C",
            str(ROOT),
            "merge-base",
            "--is-ancestor",
            compatibility_commit,
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

    shadow = shadow_peer_preflight(manifest, compatibility["launch_commit"])
    imp = shadow["peers"]["imp"]
    upstream = shadow["peers"]["upstream"]

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
        "shadow_execution": shadow,
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
        result.get("lm_results") if runtime == "imp" else result.get("response_ledger")
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
        and in_flight_count == transmitted_count - completed_count - failed_count
        and reserved_not_transmitted == reserved_count - transmitted_count,
        f"{runtime} rescue lifecycle ledger diverges",
    )
    if runtime == "upstream":
        require(
            ledger.get("transmission_observation") == "forward_finally_transport_bound",
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
            result.get("failure_cardinality_gate_result_sha256") == failure_gate_sha,
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
    env = peer_environment(live_mode(os.environ, system_ca_file()), launch_commit)
    require_mode_equivalence(
        peer_environment(
            shadow_mode("https://127.0.0.1:1", "/owned-shadow-ca.pem"), launch_commit
        ),
        env,
    )
    (TMP / "sealed").mkdir(parents=True, exist_ok=False)
    peers = [
        subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        for command, cwd in commands().values()
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


def coordinate(
    preflight_only: bool = False,
    compatibility_only: bool = False,
    shadow_only: bool = False,
) -> int:
    if compatibility_only:
        print(
            json.dumps(compatibility_preflight(), indent=2, sort_keys=True), flush=True
        )
        return 0
    if shadow_only:
        compatibility = compatibility_preflight()
        manifest = json.loads(MANIFEST.read_text())
        report = shadow_peer_preflight(manifest, compatibility["launch_commit"])
        print(json.dumps(report, indent=2, sort_keys=True), flush=True)
        return 0
    report = preflight(preflight_only)
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if preflight_only else run_peers(report["source_commit"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight-only", action="store_true")
    parser.add_argument("--compatibility-only", action="store_true")
    parser.add_argument("--shadow-only", action="store_true")
    args = parser.parse_args()
    raise SystemExit(
        coordinate(args.preflight_only, args.compatibility_only, args.shadow_only)
    )


if __name__ == "__main__":
    main()
