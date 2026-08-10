#!/usr/bin/env python3
"""Fail-closed coordinator for the one-seed 16k dress rehearsal.

Adapted from examples/matched_gepa_mipro_ifbench_gepa014/run_paired.py (sealed).
Kept: source authentication (DSPy/GEPA commit+tree pins, version bridge), the
shadow TLS mode, the clean-worktree check, coordinated launch/stop, and result
collection. Removed: the v3-equivalence gate, failure-cardinality replay pin,
accepted-successor-draft / predecessor sha checks, and launch_status.
"""

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
CANONICAL_TMP = ROOT / "tmp" / "matched_ifbench_rehearsal16k"
TMP = CANONICAL_TMP
DSPY_ROOT = ROOT / "tmp" / "dspy-3.2.1"
GEPA_ROOT = ROOT / "tmp" / "gepa-v0.1.4"
GEPA_ARTIFACT_ROOT = ROOT / "tmp" / "gepa-artifact"
UPSTREAM_PYTHON = ROOT / "tmp" / "dspy-parity-venv" / "bin" / "python"
IFBENCH_SITE_PACKAGES = (
    ROOT / "tmp" / "ifbench-parity-venv" / "lib" / "python3.13" / "site-packages"
)
IFBENCH_NLTK_DATA = ROOT / "tmp" / "ifbench-parity-venv" / "nltk_data"
IFBENCH_PYTHON = ROOT / "tmp" / "ifbench-parity-venv" / "bin" / "python"
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
    return (HERE / "run_upstream.py").read_text()


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
    # Cost guard redesign: task calls reserve at the measured-p99
    # reservation_output_tokens (4096), not the 16384 max_tokens request cap.
    task_cost = Decimal(request["task"]["reservation_input_tokens"]) * Decimal(
        models["task"]["catalog_prompt_per_token"]
    ) + Decimal(request["task"]["reservation_output_tokens"]) * Decimal(
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
        CANONICAL_TMP,
        GEPA_ARTIFACT_ROOT,
        IFBENCH_PYTHON,
        IFBENCH_NLTK_DATA,
    )


def require_bootstrap_contract(manifest: dict[str, Any], launch_commit: str) -> str:
    digest = canonical_digest(bootstrap_spec(launch_commit))
    require(
        manifest.get("bootstrap_contract")
        == {
            "schema_version": 1,
            "digest": digest,
            "identity": "canonical commands, working directories, fixed environment, and explicit credential/endpoint/trust substitutions",
        },
        "manifest bootstrap contract drift",
    )
    return digest


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

    with tempfile.TemporaryDirectory(prefix="imp-ifbench-r16k-shadow-") as temporary:
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
            expected_digest = require_bootstrap_contract(manifest, launch_commit)
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


# In credential-free modes (zero provider calls) the rehearsal surface under
# test is expected to be uncommitted pre-ratification. Shadow tolerates
# untracked ("??") entries anywhere plus tracked modifications confined to
# these prefixes; live launches require a strictly clean tree.
SHADOW_MODIFIED_PREFIXES = (
    "examples/matched_ifbench_rehearsal16k/",
    "tmp/",
    ".tickets/",
)


def require_launch_tree(shadow_ok: bool) -> None:
    raw = subprocess.check_output(
        ["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=all"],
        text=True,
    )
    entries = [line for line in raw.splitlines() if line.strip() != ""]
    if not entries:
        return
    if shadow_ok:
        stray = [
            line
            for line in entries
            if not (
                line.startswith("?? ")
                or line[3:].startswith(SHADOW_MODIFIED_PREFIXES)
            )
        ]
        require(
            stray == [],
            "Imp worktree is dirty outside the rehearsal shadow tolerance:\n"
            + "\n".join(stray),
        )
        return
    require(False, "Imp worktree is dirty:\n" + "\n".join(entries))


def compatibility_preflight(shadow_ok: bool = False) -> dict[str, Any]:
    require(Path.cwd().resolve() == ROOT, f"coordinator must run from {ROOT}")
    require_launch_tree(shadow_ok)
    manifest = json.loads(MANIFEST.read_text())
    manifest_sha = sha256_file(MANIFEST)
    bootstrap_digest = require_bootstrap_contract(
        manifest, git(ROOT, "rev-parse", "HEAD")
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
    failure_compat = manifest["failure_cardinality_compat"]
    require(
        sha256_file(resolve(failure_compat["module_path"]))
        == failure_compat["module_sha256"],
        "failure-preserving DSPy compatibility source drift",
    )
    paired_surface = manifest["paired_surface"]
    for name, binding in paired_surface.items():
        path = HERE / binding["path"]
        require(path.is_file(), f"paired surface {name} is absent")
        require(
            sha256_file(path) == binding["sha256"],
            f"paired surface {name} source drift",
        )
    return {
        "status": "pass",
        "manifest_sha256": manifest_sha,
        "launch_commit": git(ROOT, "rev-parse", "HEAD"),
        "bootstrap_digest": bootstrap_digest,
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
    # Reservation ceiling: 9,376 task x $0.02208 + 78 optimizer x $0.096.
    maximum = worst_case_usd(manifest)
    require(
        maximum == Decimal("214.51008000"),
        f"reservation ceiling drift: {maximum}",
    )
    # Hard cap on ACTUAL spend (enforced per-runtime as new_spend_max/2 in
    # both peers' reconcile paths): $60 across both runtimes.
    require(
        Decimal(str(manifest["budget"]["new_spend_max"])) == Decimal("60.0"),
        "hard spend cap drift",
    )

    shadow = shadow_peer_preflight(manifest, compatibility["launch_commit"])
    imp = shadow["peers"]["imp"]
    upstream = shadow["peers"]["upstream"]

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
        "reservation_ceiling": str(maximum),
        "hard_spend_cap": str(manifest["budget"]["new_spend_max"]),
        "imp": imp,
        "upstream": upstream,
        "shadow_execution": shadow,
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
        + Decimal(request["task"]["reservation_output_tokens"])
        * Decimal(models["task"]["catalog_completion_per_token"]),
        "optimizer": Decimal(request["optimizer"]["reservation_input_tokens"])
        * Decimal(models["optimizer"]["catalog_cache_write_per_token"])
        + Decimal(request["optimizer"]["max_tokens"])
        * Decimal(models["optimizer"]["catalog_completion_per_token"]),
    }
    require(
        rates == {"task": Decimal("0.022080"), "optimizer": Decimal("0.09600")},
        "manifest reservation rates drift",
    )
    return rates


def require_rescued_stop_artifacts(
    manifest: dict[str, Any], launch_commit: str
) -> None:
    manifest_sha = sha256_file(MANIFEST)
    expected_sources = {
        "imp": launch_commit,
        "dspy": manifest["authorities"]["dspy"]["commit"],
        "gepa": manifest["authorities"]["gepa"]["commit"],
    }
    rates = reservation_rates(manifest)
    runtime_maximum = worst_case_usd(manifest) / Decimal(2)
    require(runtime_maximum == Decimal("107.25504000"), "runtime reservation cap drift")
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
            result.get("launch_commit") == launch_commit,
            f"{runtime} launch binding drift",
        )
        require(
            result.get("bootstrap_digest")
            == require_bootstrap_contract(manifest, launch_commit),
            f"{runtime} stopped bootstrap binding drift",
        )
        if result.get("status") != "stopped":
            # A stopped record writes source bookkeeping as "unavailable";
            # the stop error is the finding - do not mask it with a
            # binding-drift misfire (2026-08-09 rehearsal stop 1 lesson).
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
    expected_bootstrap_digest = require_bootstrap_contract(manifest, launch_commit)
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
    require_completed_peer_artifacts(manifest, launch_commit, expected_bootstrap_digest)
    return 0


def require_completed_peer_artifacts(
    manifest: dict[str, Any], launch_commit: str, expected_bootstrap_digest: str
) -> None:
    for runtime in ("imp", "upstream"):
        path = TMP / f"{runtime}-result.json"
        require(path.is_file(), f"{runtime} completed result artifact is absent")
        result = json.loads(path.read_text())
        require(result.get("status") == "complete", f"{runtime} result is not complete")
        require(
            result.get("manifest_sha256") == sha256_file(MANIFEST),
            f"{runtime} completed manifest binding drift",
        )
        require(
            result.get("source_commits", {}).get("imp") == launch_commit,
            f"{runtime} completed launch binding drift",
        )
        require(
            result.get("bootstrap_digest") == expected_bootstrap_digest,
            f"{runtime} completed bootstrap binding drift",
        )


def coordinate(
    preflight_only: bool = False,
    compatibility_only: bool = False,
    shadow_only: bool = False,
) -> int:
    if compatibility_only:
        print(
            json.dumps(compatibility_preflight(shadow_ok=True), indent=2, sort_keys=True),
            flush=True,
        )
        return 0
    if shadow_only:
        compatibility = compatibility_preflight(shadow_ok=True)
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
