#!/usr/bin/env python3
"""Unsealed v3 upstream runner using the explicit stock-DSPy task module.

All transport, accounting, optimizer, scoring, and held-out behavior remains
owned by the permanently stopped v1 runner. This entry point replaces only its
program factory and GEPA's failed-trace adapter before invoking it. It has no
network authority until a v3
manifest is separately reviewed and sealed.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
V1_RUNNER = HERE.parent / "matched_gepa_mipro_ifbench" / "run_upstream.py"
V3_MANIFEST = HERE / "contract.json"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


manifest_contract = json.loads(V3_MANIFEST.read_text())
if sha256_file(V1_RUNNER) != manifest_contract["execution_base"]["runner_sha256"]:
    raise RuntimeError("delegated v1 upstream implementation drift")

COMPATIBILITY_MODULE = (
    HERE / manifest_contract["failure_cardinality_compat"]["module_path"]
).resolve()
if sha256_file(COMPATIBILITY_MODULE) != manifest_contract[
    "failure_cardinality_compat"
]["module_sha256"]:
    raise RuntimeError("failure-preserving DSPy compatibility source drift")
sys.path.insert(0, str(COMPATIBILITY_MODULE.parent))
from dspy_gepa_failure_compat import patched_dspy_gepa

sys.path.insert(0, str(V1_RUNNER.parent))
SPEC = importlib.util.spec_from_file_location("matched_ifbench_v1_upstream", V1_RUNNER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load stopped v1 runner at {V1_RUNNER}")
v1 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = v1
SPEC.loader.exec_module(v1)

v1.MANIFEST_PATH = HERE / "contract.json"
v1.OUTPUT = Path(
    os.environ.get(
        "UPSTREAM_MATCHED_IFBENCH_V3_OUTPUT",
        v1.IMP_ROOT / "tmp" / "matched_gepa_mipro_ifbench_v3" / "upstream-result.json",
    )
)
v1.SELECTION_OUTPUT = Path(str(v1.OUTPUT) + ".selection-sealed.json")
os.environ["IMP_MATCHED_IFBENCH_IMP_SELECTION"] = os.environ.get(
    "UPSTREAM_MATCHED_IFBENCH_V3_IMP_SELECTION",
    str(
        v1.IMP_ROOT
        / "tmp"
        / "matched_gepa_mipro_ifbench_v3"
        / "imp-result.json.selection-sealed.json"
    ),
)

v1_source_commits = v1.source_commits
v1_atomic_write = v1.atomic_write
v1_compile_arm = v1.compile_arm


def require_expected_launch_commit() -> str:
    expected = os.environ.get("MATCHED_IFBENCH_V3_EXPECTED_COMMIT")
    if expected is None or len(expected) != 40:
        raise RuntimeError(
            "MATCHED_IFBENCH_V3_EXPECTED_COMMIT is required as a full commit"
        )
    actual = subprocess.check_output(
        ["git", "-C", str(v1.IMP_ROOT), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != expected:
        raise RuntimeError(f"v3 launch commit drift: {actual} != {expected}")
    return expected


def source_commits(manifest: dict[str, Any]) -> dict[str, str]:
    commits = v1_source_commits(manifest)
    expected = require_expected_launch_commit()
    if commits["imp"] != expected:
        raise RuntimeError(f"v3 launch commit drift: {commits['imp']} != {expected}")
    return commits


v1.source_commits = source_commits


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
                "manifest_sha256": sha256_file(V3_MANIFEST),
                "provider_free_gate_result_sha256": manifest_contract[
                    "provider_free_gate"
                ]["result_sha256"],
                "failure_cardinality_gate_result_sha256": manifest_contract[
                    "failure_cardinality_compat"
                ]["result_sha256"],
                "launch_commit": os.environ.get(
                    "MATCHED_IFBENCH_V3_EXPECTED_COMMIT", "unavailable"
                ),
                "rescue_accounting": rescue_accounting(value),
                "response_ledger": [
                    call
                    for call in value.get("calls", [])
                    if call.get("raw_response", {}).get("response") is not None
                ],
            }
        )
    v1_atomic_write(path, value)


v1.atomic_write = atomic_write


def build_program(dspy: Any, task_lm: Any):
    from ifbench_stock_module import IFBenchCoT2StageModule

    program = IFBenchCoT2StageModule()
    program.set_lm(task_lm)
    return program


# v1 has one program factory used before baseline, GEPA, or MIPRO dispatch.
# Replacing that factory guarantees every v3 upstream arm receives the
# translated class without changing the stopped source or manifest.
v1.build_program = build_program


def compile_arm(*args: Any, **kwargs: Any):
    arm = args[1] if len(args) > 1 else kwargs.get("arm")
    if arm == "gepa":
        with patched_dspy_gepa():
            return v1_compile_arm(*args, **kwargs)
    return v1_compile_arm(*args, **kwargs)


v1.compile_arm = compile_arm


if __name__ == "__main__":
    require_expected_launch_commit()
    v1.main()
