#!/usr/bin/env python3
"""Authenticated DSPy 3.2.1 + GEPA 0.1.4 matched upstream peer.

All transport, accounting, optimizer, scoring, and held-out behavior remains
owned by the permanently stopped v1 runner. This entry point first authenticates
and installs the exact GEPA 0.1.4 source bridge, then replaces only the program
factory and GEPA's failed-trace adapter before invoking the inherited runtime.
It has no network authority until the successor manifest is separately sealed.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import os
import platform
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Any


# LiteLLM loads .env and a remote cost map during import. In shadow mode an
# explicit empty key prevents ambient dotenv credential acquisition, while the
# local bundled cost map prevents any non-owned bootstrap network request.
if os.environ.get("MATCHED_IFBENCH_GEPA014_SHADOW") == "1":
    os.environ.setdefault("OPENROUTER_API_KEY", "")
    os.environ["LITELLM_LOCAL_MODEL_COST_MAP"] = "True"


HERE = Path(__file__).resolve().parent
V1_RUNNER = HERE.parent / "matched_gepa_mipro_ifbench" / "run_upstream.py"
SUCCESSOR_MANIFEST = HERE / "contract.json"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


manifest_contract = json.loads(SUCCESSOR_MANIFEST.read_text())
COMPATIBILITY_MODULE = (
    HERE / manifest_contract["failure_cardinality_compat"]["module_path"]
).resolve()
IMP_ROOT = HERE.parents[1]
v1: Any | None = None
_source_bridge: Any | None = None
_patched_dspy_gepa: Any | None = None
_v1_source_commits: Any | None = None
_v1_atomic_write: Any | None = None
_v1_compile_arm: Any | None = None
_effective_gepa_identity: dict[str, Any] | None = None


class LaunchAdmissionError(RuntimeError):
    """Refusal raised before any optional treatment dependency is imported."""


def require_expected_launch_commit() -> str:
    expected = os.environ.get("MATCHED_IFBENCH_GEPA014_EXPECTED_COMMIT")
    if expected is None or len(expected) != 40:
        raise LaunchAdmissionError(
            "MATCHED_IFBENCH_GEPA014_EXPECTED_COMMIT is required as a full commit"
        )
    actual = subprocess.check_output(
        ["git", "-C", str(IMP_ROOT), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != expected:
        raise LaunchAdmissionError(
            f"GEPA 0.1.4 successor launch commit drift: {actual} != {expected}"
        )
    return expected


def source_commits(manifest: dict[str, Any]) -> dict[str, str]:
    if _v1_source_commits is None:
        raise RuntimeError("authenticated upstream runtime is not loaded")
    commits = _v1_source_commits(manifest)
    expected = require_expected_launch_commit()
    if commits["imp"] != expected:
        raise RuntimeError(
            f"GEPA 0.1.4 successor launch commit drift: {commits['imp']} != {expected}"
        )
    return commits


def load_authenticated_runtime() -> Any:
    """Load optional treatment dependencies only after exact commit admission."""

    global v1, _source_bridge, _patched_dspy_gepa, _v1_source_commits
    global _v1_atomic_write, _v1_compile_arm, _effective_gepa_identity
    require_expected_launch_commit()
    if v1 is not None:
        return v1
    if sha256_file(V1_RUNNER) != manifest_contract["execution_base"]["runner_sha256"]:
        raise RuntimeError("delegated v1 upstream implementation drift")
    if (
        sha256_file(COMPATIBILITY_MODULE)
        != manifest_contract["failure_cardinality_compat"]["module_sha256"]
    ):
        raise RuntimeError("failure-preserving DSPy compatibility source drift")

    bridge_contract = manifest_contract["authenticated_gepa_bridge"]
    bridge_path = (HERE / bridge_contract["path"]).resolve()
    if sha256_file(bridge_path) != bridge_contract["sha256"]:
        raise RuntimeError("authenticated GEPA source bridge drift")
    bridge_spec = importlib.util.spec_from_file_location(
        "matched_ifbench_gepa014_source_bridge", bridge_path
    )
    if bridge_spec is None or bridge_spec.loader is None:
        raise RuntimeError("cannot load authenticated GEPA source bridge")
    bridge_module = importlib.util.module_from_spec(bridge_spec)
    sys.modules[bridge_spec.name] = bridge_module
    bridge_spec.loader.exec_module(bridge_module)
    source_roots = manifest_contract["runtime_dependencies"]["upstream"]["source_roots"]
    dspy_root = (IMP_ROOT / source_roots["dspy"]).resolve()
    gepa_root = (IMP_ROOT / source_roots["gepa"]).resolve()
    already_loaded = any(
        name == "dspy"
        or name.startswith("dspy.")
        or name == "gepa"
        or name.startswith("gepa.")
        for name in sys.modules
    )
    if already_loaded:
        if os.environ.get("MATCHED_IFBENCH_GEPA014_COMPATIBILITY_GATE") != "1":
            raise RuntimeError("DSPy/GEPA imported before authenticated source bridge")
        _source_bridge = bridge_module.VersionBridge(
            dspy_root=dspy_root,
            gepa_root=gepa_root,
            dspy_commit=bridge_module.DSPY_COMMIT,
            gepa_commit=bridge_module.GEPA_COMMIT,
            dspy_version=bridge_module.DSPY_VERSION,
            gepa_version=bridge_module.GEPA_VERSION,
            dspy_declared_gepa=bridge_module.DSPY_DECLARED_GEPA,
            acceptance_first_release=bridge_module.ACCEPTANCE_FIRST_RELEASE,
        )
    else:
        _source_bridge = bridge_module.install_source_bridge(dspy_root, gepa_root)

    sys.path.insert(0, str(COMPATIBILITY_MODULE.parent))
    from dspy_gepa_failure_compat import patched_dspy_gepa

    import dspy
    import gepa

    _effective_gepa_identity = bridge_module.authenticate_loaded_runtime(
        _source_bridge, dspy, gepa
    )

    sys.path.insert(0, str(V1_RUNNER.parent))
    spec = importlib.util.spec_from_file_location(
        "matched_ifbench_v1_upstream", V1_RUNNER
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load stopped v1 runner at {V1_RUNNER}")
    runtime = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = runtime
    spec.loader.exec_module(runtime)

    runtime.MANIFEST_PATH = SUCCESSOR_MANIFEST
    runtime.OUTPUT = Path(
        os.environ.get(
            "UPSTREAM_MATCHED_IFBENCH_GEPA014_OUTPUT",
            IMP_ROOT
            / "tmp"
            / "matched_gepa_mipro_ifbench_gepa014"
            / "upstream-result.json",
        )
    )
    runtime.SELECTION_OUTPUT = Path(str(runtime.OUTPUT) + ".selection-sealed.json")
    os.environ["IMP_MATCHED_IFBENCH_IMP_SELECTION"] = os.environ.get(
        "UPSTREAM_MATCHED_IFBENCH_GEPA014_IMP_SELECTION",
        str(
            IMP_ROOT
            / "tmp"
            / "matched_gepa_mipro_ifbench_gepa014"
            / "imp-result.json.selection-sealed.json"
        ),
    )

    _patched_dspy_gepa = patched_dspy_gepa
    _v1_source_commits = runtime.source_commits
    _v1_atomic_write = runtime.atomic_write
    _v1_compile_arm = runtime.compile_arm
    runtime.source_commits = source_commits
    runtime.verify_runtime_dependencies = verify_runtime_dependencies
    runtime.atomic_write = atomic_write
    runtime.build_program = build_program
    runtime.compile_arm = compile_arm
    v1 = runtime
    return runtime


def verify_runtime_dependencies(manifest: dict[str, Any]) -> None:
    """Verify the installed DSPy environment and the effective GEPA source.

    DSPy 3.2.1 owns an installed GEPA 0.0.27 distribution, while this explicit
    bridge executes the authenticated 0.1.4 source checkout. Distribution lookup
    follows ``sys.path`` and therefore reports the checkout's stale 0.1.3
    egg-info after the bridge is installed. Treating that value as runtime
    identity caused the sealed live path to reject the very source it had
    authenticated. The imported module, source tree, and API signature own the
    effective identity; distribution metadata remains a separately checked
    environment fact.
    """

    if v1 is None or _effective_gepa_identity is None:
        raise RuntimeError("authenticated upstream runtime is not loaded")
    expected = manifest["runtime_dependencies"]["upstream"]
    if platform.python_version() != expected["python"]:
        raise RuntimeError(
            f"upstream Python drift: {platform.python_version()} != {expected['python']}"
        )

    actual = {
        name: importlib.metadata.version(name)
        for name in expected["packages"]
        if name != "gepa"
    }
    if actual != {name: version for name, version in expected["packages"].items() if name != "gepa"}:
        raise RuntimeError(f"upstream dependency version drift: {actual!r}")

    installed_gepa = [
        distribution
        for distribution in importlib.metadata.distributions()
        if (distribution.metadata.get("Name") or "").lower() == "gepa"
        and Path(distribution._path).resolve().is_relative_to(Path(sys.prefix).resolve())
    ]
    if len(installed_gepa) != 1 or installed_gepa[0].version != expected["packages"]["gepa"]:
        found = [
            {"version": distribution.version, "path": str(Path(distribution._path).resolve())}
            for distribution in installed_gepa
        ]
        raise RuntimeError(f"installed DSPy GEPA dependency drift: {found!r}")

    effective = manifest["authenticated_gepa_bridge"]["effective_identity"]
    observed = _effective_gepa_identity
    module_path = Path(observed["module_path"]).resolve()
    expected_module = (IMP_ROOT / effective["module_path"]).resolve()
    checks = {
        "module_path": module_path == expected_module,
        "source_commit": observed["source_commit"] == effective["source_commit"],
        "source_tree": observed["source_tree"] == effective["source_tree"],
        "init_sha256": observed["init_sha256"] == effective["init_sha256"],
        "api_sha256": observed["api_sha256"] == effective["api_sha256"],
        "optimize_signature_sha256": observed["optimize_signature_sha256"]
        == effective["optimize_signature_sha256"],
        "module_version": observed["module_version"] == effective["module_version"],
        "source_distribution_version": any(
            item["version"] == effective["source_distribution_version"]
            and Path(item["metadata_path"]).resolve().is_relative_to(
                (IMP_ROOT / effective["source_root"]).resolve()
            )
            for item in observed["distribution_metadata"]
        ),
        "installed_distribution_version": installed_gepa[0].version
        == effective["installed_distribution_version"],
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    if failed:
        raise RuntimeError("effective GEPA source/API identity drift: " + ", ".join(failed))

    lock = (HERE / expected["lock_path"]).resolve()
    if v1.sha256_file(lock) != expected["lock_sha256"]:
        raise RuntimeError("upstream dependency lock digest drift")
    freeze = subprocess.check_output(
        [sys.executable, "-m", "pip", "freeze", "--all"], text=True
    ).splitlines()
    materialized = "\n".join(sorted(freeze)) + "\n"
    if materialized.encode() != lock.read_bytes():
        raise RuntimeError("materialized upstream environment differs from committed lock")


def shadow_preflight(runtime: Any) -> None:
    """Run the authenticated production peer through two local TLS transports."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--gepa-artifact-root", type=Path, required=True)
    parser.add_argument("--ifbench-site-packages", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("OPENROUTER_API_KEY", "").strip() != "":
        raise RuntimeError("upstream shadow preflight received provider authority")
    base_url = os.environ["MATCHED_IFBENCH_GEPA014_SHADOW_BASE_URL"]
    ca_cert = Path(os.environ["MATCHED_IFBENCH_GEPA014_SHADOW_CA_CERT"]).resolve()
    if os.environ.get("SSL_CERT_FILE") != str(ca_cert):
        raise RuntimeError("upstream shadow TLS trust does not match the owned CA")

    tls_context = __import__("ssl").create_default_context(cafile=str(ca_cert))
    with urllib.request.urlopen(base_url + "/health", context=tls_context, timeout=5) as response:
        readiness = json.load(response)
    if readiness != {"status": "ready"}:
        raise RuntimeError("upstream shadow TLS readiness response drift")

    manifest = runtime.load_manifest(args)
    runtime.verify_clean_imp_tree()
    verify_runtime_dependencies(manifest)
    dspy, RecordingLM = runtime.install_runtime(args)
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))
    catalog_roles = []
    for role in ("task", "optimizer"):
        expected = manifest["models"][role]
        with urllib.request.urlopen(
            base_url + f"/api/v1/models/{expected['logical']}/endpoints",
            context=tls_context,
            timeout=5,
        ) as response:
            endpoints = json.load(response).get("data", {}).get("endpoints", [])
        eligible = runtime.eligible_endpoints(
            endpoints,
            expected,
            role,
            manifest["execution"]["openrouter"][f"{role}_order"],
        )
        if not eligible:
            raise RuntimeError(f"upstream shadow {role} catalog guard failed")
        catalog_roles.append(role)
    capture = runtime.Capture(manifest)
    capture.register_budget(
        0,
        "shadow",
        {
            "task_logical": 1,
            "optimizer_logical": 1,
            "total_logical": 2,
            "transports": 2,
        },
    )
    request = manifest["execution"]["request"]
    capture.set_phase(0, "shadow", "task")
    task = RecordingLM(
        manifest["models"]["task"]["upstream"],
        api_base=base_url + "/v1",
        api_key="local-shadow-only",
        cache=False,
        num_retries=0,
        capture=capture,
        role="task",
        seed=17,
        max_tokens=request["task"]["max_tokens"],
        extra_body=runtime.openrouter_body(manifest, "task"),
    )
    task.forward(messages=[{"role": "user", "content": "shadow task"}], seed=17)
    capture.set_phase(0, "shadow", "optimizer")
    optimizer = RecordingLM(
        manifest["models"]["optimizer"]["upstream"],
        api_base=base_url + "/v1",
        api_key="local-shadow-only",
        cache=False,
        num_retries=0,
        capture=capture,
        role="optimizer",
        temperature=request["optimizer"]["temperature"],
        max_tokens=request["optimizer"]["max_tokens"],
        extra_body=runtime.openrouter_body(manifest, "optimizer"),
    )
    optimizer.forward(
        messages=[{"role": "user", "content": "shadow optimizer"}], temperature=0.0
    )
    roles = [call["role"] for call in capture.calls]
    if roles != ["task", "optimizer"]:
        raise RuntimeError(f"upstream shadow transport roles drift: {roles!r}")
    print(
        "PAIRED_SHADOW_JSON="
        + json.dumps(
            {
                "status": "pass",
                "runtime": "upstream",
                "provider_authority_present": False,
                "held_out_loaded": False,
                "transport_roles": roles,
                "transport_count": len(capture.calls),
                "catalog_roles": catalog_roles,
                "effective_gepa_identity": _effective_gepa_identity,
                "tls_ca_sha256": sha256_file(ca_cert),
            },
            sort_keys=True,
        ),
        flush=True,
    )


def rescue_accounting(value: dict[str, Any]) -> dict[str, Any]:
    budgets = []
    for key, budget in sorted(value.get("call_budgets", {}).items()):
        seed_text, arm = key.split(":", 1)
        budgets.append(
            {
                "seed": int(seed_text),
                "arm": arm,
                "ceiling": budget["ceiling"],
                "counts": budget["counts"],
                "refusal_count": len(budget["refusals"]),
            }
        )
    calls = value.get("calls", [])
    reserved = sum(budget["counts"]["total_logical"] for budget in budgets)
    transmitted = len(calls)
    completed = sum(
        call.get("raw_response", {}).get("response") is not None for call in calls
    )
    failed = sum(call.get("error") is not None for call in calls)
    in_flight = transmitted - completed - failed
    return {
        "call_budgets": budgets,
        "ledger": {
            "reserved": reserved,
            "transmitted": transmitted,
            "completed": completed,
            "failed": failed,
            "in_flight": in_flight,
            "reserved_not_transmitted": reserved - transmitted,
            "transmission_observation": "forward_finally_transport_bound",
        },
    }


def atomic_write(path: Path, value: Any) -> None:
    if isinstance(value, dict) and value.get("status") == "stopped":
        value = dict(value)
        value.update(
            {
                "manifest_sha256": sha256_file(SUCCESSOR_MANIFEST),
                "provider_free_gate_result_sha256": manifest_contract[
                    "provider_free_gate"
                ]["result_sha256"],
                "failure_cardinality_gate_result_sha256": manifest_contract[
                    "failure_cardinality_compat"
                ]["result_sha256"],
                "launch_commit": os.environ.get(
                    "MATCHED_IFBENCH_GEPA014_EXPECTED_COMMIT", "unavailable"
                ),
                "rescue_accounting": rescue_accounting(value),
                "response_ledger": [
                    call
                    for call in value.get("calls", [])
                    if call.get("raw_response", {}).get("response") is not None
                ],
            }
        )
    if _v1_atomic_write is None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + f".tmp-{os.getpid()}")
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, path)
    else:
        _v1_atomic_write(path, value)


def build_program(dspy: Any, task_lm: Any):
    from ifbench_stock_module import IFBenchCoT2StageModule

    program = IFBenchCoT2StageModule()
    program.set_lm(task_lm)
    return program


def compile_arm(*args: Any, **kwargs: Any):
    if _v1_compile_arm is None or _patched_dspy_gepa is None:
        raise RuntimeError("authenticated upstream runtime is not loaded")
    arm = args[1] if len(args) > 1 else kwargs.get("arm")
    if arm == "gepa":
        with _patched_dspy_gepa():
            return _v1_compile_arm(*args, **kwargs)
    return _v1_compile_arm(*args, **kwargs)


if __name__ == "__main__":
    authenticated_runtime = load_authenticated_runtime()
    if os.environ.get("MATCHED_IFBENCH_GEPA014_SHADOW") == "1":
        shadow_preflight(authenticated_runtime)
    else:
        authenticated_runtime.main()
