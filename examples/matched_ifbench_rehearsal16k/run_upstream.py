#!/usr/bin/env python3
"""Authenticated DSPy 3.2.1 + GEPA 0.1.4 upstream peer, 16k dress rehearsal.

Standalone adaptation of the sealed gepa014 upstream composition
(examples/matched_gepa_mipro_ifbench_gepa014/run_upstream.py delegating to
examples/matched_gepa_mipro_ifbench/run_upstream.py). Kept: exact-commit launch
admission, the authenticated DSPy/GEPA source bridge, the stock-DSPy-adapted
IFBench module, the failure-preserving GEPA adapter patch, two-phase
seal-then-held-out, pre-dispatch call/USD reservation, and the shadow TLS mode.
Rehearsal changes: one seed; task max_tokens 16384 (source-faithful per the
gepa-artifact authors, tmp/gepa-artifact/scripts/run_experiments.py:59);
~1/3-paper optimizer budgets; the p99 reservation cost guard with an 8192-token
per-call hard stop; no launch_status / equivalence-gate / predecessor checks.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.metadata
import importlib.util
import json
import os
import platform
import re
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
IMP_ROOT = HERE.parents[1]
MANIFEST_PATH = HERE / "contract.json"
OUTPUT = Path(
    os.environ.get(
        "UPSTREAM_MATCHED_IFBENCH_R16K_OUTPUT",
        IMP_ROOT / "tmp" / "matched_ifbench_rehearsal16k" / "upstream-result.json",
    )
)
SELECTION_OUTPUT = Path(str(OUTPUT) + ".selection-sealed.json")
ID_RE = re.compile(rb'"source_id"\s*:\s*"([^"]+)"')
ACTIVE_CAPTURE: "Capture | None" = None

manifest_contract = json.loads(MANIFEST_PATH.read_text())
COMPATIBILITY_MODULE = (
    HERE / manifest_contract["failure_cardinality_compat"]["module_path"]
).resolve()
_source_bridge: Any | None = None
_patched_dspy_gepa: Any | None = None
_effective_gepa_identity: dict[str, Any] | None = None
_bootstrap_digest: str | None = None

sys.path.insert(0, str(HERE))
from peer_bootstrap import (  # noqa: E402
    canonical_spec,
    peer_commands,
    require_runtime_environment,
)


class OperationalSafetyAbort(BaseException):
    """Bypasses DSPy's ordinary Exception containment for route/cost/budget drift."""


class CoordinatedStop(BaseException):
    """Requests the normal stopped-artifact path before coordinator termination."""


class LaunchAdmissionError(RuntimeError):
    """Refusal raised before any optional treatment dependency is imported."""


MIPRO_OPTIMIZER_ENVELOPE = re.compile(
    r"\A\s*\[\[ ## (observations|summary|proposed_instruction) ## \]\]\s*\n"
    r"(?s:.+?)\s*\n\s*\[\[ ## completed ## \]\]\s*\Z"
)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def require_expected_launch_commit() -> str:
    expected = os.environ.get("MATCHED_IFBENCH_R16K_EXPECTED_COMMIT")
    if expected is None or len(expected) != 40:
        raise LaunchAdmissionError(
            "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT is required as a full commit"
        )
    actual = subprocess.check_output(
        ["git", "-C", str(IMP_ROOT), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != expected:
        raise LaunchAdmissionError(
            f"rehearsal launch commit drift: {actual} != {expected}"
        )
    return expected


def authenticate_bootstrap_environment() -> str:
    expected = require_expected_launch_commit()
    commands = peer_commands(
        IMP_ROOT,
        HERE,
        IMP_ROOT / "tmp" / "dspy-parity-venv" / "bin" / "python",
        IMP_ROOT / "tmp" / "dspy-3.2.1",
        IMP_ROOT / "tmp" / "gepa-v0.1.4",
        IMP_ROOT / "tmp" / "gepa-artifact",
        IMP_ROOT
        / "tmp"
        / "ifbench-parity-venv"
        / "lib"
        / "python3.13"
        / "site-packages",
    )
    spec = canonical_spec(
        IMP_ROOT,
        HERE,
        expected,
        commands,
        IMP_ROOT / "tmp" / "matched_ifbench_rehearsal16k",
        IMP_ROOT / "tmp" / "gepa-artifact",
        IMP_ROOT / "tmp" / "ifbench-parity-venv" / "bin" / "python",
        IMP_ROOT / "tmp" / "ifbench-parity-venv" / "nltk_data",
    )
    digest = require_runtime_environment(os.environ, spec)
    if digest != manifest_contract["bootstrap_contract"]["digest"]:
        raise RuntimeError("peer bootstrap digest differs from manifest binding")
    return digest


def install_authenticated_runtime(args: argparse.Namespace):
    """Authenticate sources, install the bridge, then import DSPy/GEPA."""

    global _source_bridge, _patched_dspy_gepa, _effective_gepa_identity
    global _bootstrap_digest
    require_expected_launch_commit()
    _bootstrap_digest = authenticate_bootstrap_environment()
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
        "matched_ifbench_r16k_source_bridge", bridge_path
    )
    if bridge_spec is None or bridge_spec.loader is None:
        raise RuntimeError("cannot load authenticated GEPA source bridge")
    bridge_module = importlib.util.module_from_spec(bridge_spec)
    sys.modules[bridge_spec.name] = bridge_module
    bridge_spec.loader.exec_module(bridge_module)
    source_roots = manifest_contract["runtime_dependencies"]["upstream"]["source_roots"]
    dspy_root = (IMP_ROOT / source_roots["dspy"]).resolve()
    gepa_root = (IMP_ROOT / source_roots["gepa"]).resolve()
    if any(
        name == "dspy"
        or name.startswith("dspy.")
        or name == "gepa"
        or name.startswith("gepa.")
        for name in sys.modules
    ):
        raise RuntimeError("DSPy/GEPA imported before authenticated source bridge")
    _source_bridge = bridge_module.install_source_bridge(dspy_root, gepa_root)

    sys.path.insert(0, str(args.ifbench_site_packages))
    sys.path.insert(0, str(IMP_ROOT / "scripts"))
    from ifbench_upstream_eval import (
        install_optional_import_stubs,
        install_spacy_stub_if_needed,
    )

    install_spacy_stub_if_needed()
    install_optional_import_stubs()
    sys.path.insert(0, str(args.gepa_artifact_root))
    sys.path.insert(0, str(COMPATIBILITY_MODULE.parent))
    from dspy_gepa_failure_compat import patched_dspy_gepa

    import dspy
    import gepa

    _effective_gepa_identity = bridge_module.authenticate_loaded_runtime(
        _source_bridge, dspy, gepa
    )
    _patched_dspy_gepa = patched_dspy_gepa
    return dspy


def atomic_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".tmp-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(json_safe(value), handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def wait_for_peer_selection(manifest: dict[str, Any]) -> None:
    peer = Path(
        os.environ.get(
            "UPSTREAM_MATCHED_IFBENCH_R16K_IMP_SELECTION",
            str(
                IMP_ROOT
                / "tmp/matched_ifbench_rehearsal16k/imp-result.json.selection-sealed.json"
            ),
        )
    )
    deadline = time.monotonic() + 1800
    while True:
        if peer.is_file():
            receipt = json.loads(peer.read_text())
            if not (
                receipt.get("runtime") == "imp"
                and receipt.get("status") == "selection_sealed"
                and receipt.get("held_out_loaded") is False
                and receipt.get("manifest_sha256") == manifest["manifest_sha256"]
                # One seed x three arms.
                and len(receipt.get("selections", [])) == 3
            ):
                raise RuntimeError("Imp selection barrier receipt drift")
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("timed out before Imp sealed all selections")
        time.sleep(1)


def json_safe(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(key): json_safe(nested) for key, nested in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [json_safe(nested) for nested in value]
    if hasattr(value, "model_dump"):
        return json_safe(value.model_dump())
    if hasattr(value, "dict"):
        return json_safe(value.dict())
    if hasattr(value, "__dict__"):
        return json_safe(vars(value))
    return repr(value)


def field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value.get(name)
    return getattr(value, name, None)


def owned_git_head(path: Path) -> str:
    root = subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "--show-toplevel"], text=True
    ).strip()
    if Path(root).resolve() != path.resolve():
        raise RuntimeError(f"source root is not its own Git checkout: {path}")
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def source_commits(manifest: dict[str, Any]) -> dict[str, str]:
    commits = {
        "imp": owned_git_head(IMP_ROOT),
        "dspy": manifest["authorities"]["dspy"]["commit"],
        "gepa": manifest["authorities"]["gepa"]["commit"],
    }
    expected = require_expected_launch_commit()
    if commits["imp"] != expected:
        raise RuntimeError(
            f"rehearsal launch commit drift: {commits['imp']} != {expected}"
        )
    return commits


def verify_clean_imp_tree() -> None:
    changed = subprocess.check_output(
        ["git", "-C", str(IMP_ROOT), "status", "--porcelain", "--untracked-files=all"],
        text=True,
    ).strip()
    if changed:
        raise RuntimeError(f"Imp launch tree is not clean:\n{changed}")


def resolve(relative: str) -> Path:
    return (HERE / relative).resolve()


def gepa_budget_envelope(
    validation_size: int, minibatch_size: int, semantic_max_metric_calls: int
) -> dict[str, int]:
    """Pinned GEPA v0.1.4 iteration-boundary metric-call envelope (no network)."""

    increments = (minibatch_size, 2 * minibatch_size, 2 * minibatch_size + validation_size)
    reachable = {validation_size}
    while True:
        expanded = set(reachable)
        for count in reachable:
            if count < semantic_max_metric_calls:
                expanded.update(
                    count + increment
                    for increment in increments
                    if count + increment < semantic_max_metric_calls
                )
        if expanded == reachable:
            break
        reachable = expanded
    legal_starts = [count for count in reachable if count < semantic_max_metric_calls]
    return {
        "max_metric_calls": validation_size
        if not legal_starts
        else max(legal_starts) + max(increments)
    }


def load_manifest(args: argparse.Namespace) -> dict[str, Any]:
    manifest = json.loads(MANIFEST_PATH.read_text())
    manifest["manifest_sha256"] = sha256_file(MANIFEST_PATH)
    if (
        manifest.get("schema_version") != 3
        or manifest.get("intent")
        != "one_seed_engineering_rehearsal_source_faithful_config"
    ):
        raise RuntimeError("rehearsal manifest schema/intent drift")
    if manifest.get("seeds") != [2026072705] or manifest.get("arms") != [
        "baseline",
        "gepa",
        "mipro_v2",
    ]:
        raise RuntimeError("rehearsal seed/arm contract drift")
    # Call-ceiling arithmetic (one seed, per runtime; the two-stage program
    # makes one metric/eval program call = 2 task transports):
    #   baseline: selection 32x2 = 64 + held_out 64x2 = 128              -> 192
    #   gepa:     legal metric-call cap 1400 x2 = 2800 + 64 + 128        -> 2992
    #             optimizer: the source caps nothing (its only budget is
    #             metric calls); stop 3 measured 25 reflection calls by
    #             rollout 752/1200 (~2.5/iteration), extrapolating to ~40
    #             at budget exhaustion. 96 = ~2.4x that need, a
    #             reservation bound rather than an expectation           -> 96
    #   mipro_v2: compile = 2x((trials 9 + 2 full valset evals) x 32
    #             + train 16) = 736 (trials 8 -> 672 matched the sealed
    #             gepa014 compile slice exactly); + 64 + 128              -> 928
    #             trials capped at 9 by imp's DECLARED MIPROv2 fidelity
    #             boundary (Optuna TPE startup phase only; modeled TPE
    #             unimplemented, mipro_v2.ex:1097) — matched design means
    #             BOTH arms run the budget both can run faithfully
    #             optimizer: formula-exact 3 + 2x6 = 15 (pilot measured
    #             11 = 3 + 2x4 in both runtimes); 24 adds margin
    expected_ceilings = {
        "baseline": {
            "task_logical": 192,
            "optimizer_logical": 0,
            "transports": 192,
            "total_logical": 192,
        },
        "gepa": {
            "task_logical": 2992,
            "optimizer_logical": 96,
            "transports": 3088,
            "total_logical": 3088,
        },
        "mipro_v2": {
            "task_logical": 928,
            "optimizer_logical": 24,
            "transports": 952,
            "total_logical": 952,
        },
    }
    if manifest.get("execution", {}).get("call_ceilings") != expected_ceilings:
        raise RuntimeError("diagnostic call-ceiling contract drift")
    gepa = manifest["optimizer"]["gepa"]
    if gepa["semantic_max_metric_calls"] != 1200 or gepa["legal_metric_call_cap"] != 1400:
        raise RuntimeError("rehearsal GEPA budget contract drift")
    envelope = gepa_budget_envelope(32, gepa["minibatch_size"], 1200)
    # envelope(32, 8, 1200) = 1240; the sealed legal cap 1400 must cover it.
    if envelope["max_metric_calls"] > gepa["legal_metric_call_cap"]:
        raise RuntimeError(
            f"legal metric-call cap does not cover the pinned envelope: {envelope!r}"
        )
    mipro = manifest["optimizer"]["mipro_v2"]
    if mipro["num_candidates"] != 6 or mipro["trials"] != 9:
        raise RuntimeError("rehearsal MIPRO budget contract drift")
    request = manifest["execution"]["request"]
    if (
        request["task"]["max_tokens"] != 16384
        or request["task"]["reservation_output_tokens"] != 4096
        or request["task"]["hard_stop_completion_tokens"] != 8192
        or request["optimizer"]["max_tokens"] != 2048
    ):
        raise RuntimeError("rehearsal request envelope contract drift")
    receipt = json.loads(resolve(manifest["dataset"]["receipt_path"]).read_text())
    splits = receipt["split_ids"]
    if [len(splits.get(name, [])) for name in ("train", "selection", "held_out")] != [
        16,
        32,
        64,
    ]:
        raise RuntimeError("rehearsal split-size contract drift")
    all_ids = splits["train"] + splits["selection"] + splits["held_out"]
    if len(set(all_ids)) != 112:
        raise RuntimeError("rehearsal splits overlap")
    manifest["dataset"]["split_ids"] = splits
    for key in ("receipt_path", "train_path", "selection_path", "held_out_path"):
        manifest["dataset"][key] = str(resolve(manifest["dataset"][key]))

    expected = {name: manifest["authorities"][name]["commit"] for name in ("dspy", "gepa")}
    # The DSPy tree may be a receipt-authenticated export rather than a Git
    # checkout; never let Git walk upward and authenticate the Imp repo.
    if (args.dspy_root / ".git").exists():
        if owned_git_head(args.dspy_root) != expected["dspy"]:
            raise RuntimeError("pinned DSPy checkout commit drift")
    if owned_git_head(args.gepa_root) != expected["gepa"]:
        raise RuntimeError("pinned GEPA checkout commit drift")
    if (
        owned_git_head(args.gepa_artifact_root)
        != manifest["authorities"]["gepa_artifact"]["commit"]
    ):
        raise RuntimeError("pinned GEPA artifact checkout commit drift")

    for authority, root in (("dspy", args.dspy_root), ("gepa", args.gepa_root)):
        receipt = json.loads(
            resolve(manifest["authorities"][authority]["source_manifest"]).read_text()
        )
        if receipt["commit"] != expected[authority]:
            raise RuntimeError(f"{authority} source receipt commit drift")
        for entry in receipt["files"]:
            if sha256_file(root / entry["path"]) != entry["sha256"]:
                raise RuntimeError(f"{authority} pinned source drift: {entry['path']}")

    dataset = manifest["dataset"]
    if sha256_file(Path(dataset["receipt_path"])) != dataset["receipt_sha256"]:
        raise RuntimeError("IFBench receipt drift")
    for split in ("train", "selection"):
        if sha256_file(Path(dataset[f"{split}_path"])) != dataset[f"{split}_sha256"]:
            raise RuntimeError(f"IFBench {split} split drift")
    return manifest


def stream_rows(path: Path, wanted_ids: list[str]) -> list[dict[str, str]]:
    wanted = set(wanted_ids)
    found: dict[str, dict[str, str]] = {}
    with path.open("rb") as handle:
        for line in handle:
            match = ID_RE.search(line)
            if match is None:
                continue
            row_id = match.group(1).decode("utf-8")
            # Crucially, rows outside this phase are never JSON-decoded.
            if row_id in wanted:
                found[row_id] = json.loads(line)
    missing = wanted.difference(found)
    if missing:
        raise RuntimeError(f"missing frozen source rows: {sorted(missing)}")
    return [found[row_id] for row_id in wanted_ids]


def verify_models(manifest: dict[str, Any]) -> dict[str, Any]:
    snapshots = {}
    for role in ("task", "optimizer"):
        expected = manifest["models"][role]
        url = f"https://openrouter.ai/api/v1/models/{expected['logical']}/endpoints"
        with urllib.request.urlopen(url, timeout=30) as response:
            body = json.load(response)
        endpoints = body.get("data", {}).get("endpoints", [])
        tags = manifest["execution"]["openrouter"][f"{role}_order"]
        eligible = eligible_endpoints(endpoints, expected, role, tags)
        if not eligible:
            raise RuntimeError(
                f"no exact first-party {role} endpoint satisfies pricing/parameter guard"
            )
        encoded = json.dumps(eligible, sort_keys=True, separators=(",", ":")).encode()
        snapshots[role] = {
            "endpoint_url": url,
            "model": expected["logical"],
            "eligible_endpoints": eligible,
            "sha256": hashlib.sha256(encoded).hexdigest(),
        }
    return snapshots


def eligible_endpoints(
    endpoints: list[dict[str, Any]],
    expected: dict[str, Any],
    role: str,
    tags: list[str],
) -> list[dict[str, Any]]:
    required = (
        {"max_tokens", "seed", "response_format"}
        if role == "task"
        else {"max_tokens", "temperature"}
    )
    return sorted(
        (
            endpoint
            for endpoint in endpoints
            if endpoint.get("provider_name") == expected["endpoint_provider"]
            and endpoint.get("tag") in tags
            and float(endpoint.get("pricing", {}).get("prompt", "inf"))
            <= float(expected["catalog_prompt_per_token"])
            and float(endpoint.get("pricing", {}).get("completion", "inf"))
            <= float(expected["catalog_completion_per_token"])
            and required.issubset(set(endpoint.get("supported_parameters", [])))
        ),
        key=lambda endpoint: str(endpoint.get("tag", "")),
    )


class Capture:
    def __init__(self, manifest: dict[str, Any] | None = None) -> None:
        self.phase: dict[str, Any] | None = None
        self.calls: list[dict[str, Any]] = []
        self.call_budgets: dict[str, dict[str, Any]] = {}
        self.usd_reserved = 0.0
        self.actual_cost = 0.0
        self.role_usd: dict[str, float] = {}
        self.usd_limit: float | None = None
        self.actual_usd_cap: float | None = None
        if manifest is not None:
            request = manifest["execution"]["request"]
            models = manifest["models"]
            # COST GUARD REDESIGN (HEAVY_DESIGN_DRAFT option a): task calls
            # reserve at reservation_output_tokens = 4096 completion tokens
            # (a generous p99), NOT the 16384 max_tokens request cap. Basis
            # (measured pilot): held-out completion tokens median 505 / mean
            # 648 / max ~1024-capped; 4096 is ~6x the mean, while pricing
            # reservations at 16384 would make the reservation ceiling, not
            # spend, the binding constraint. Companion hard stop: any single
            # call whose ACTUAL completion tokens exceed
            # hard_stop_completion_tokens = 8192 (2x the reservation, ~12x
            # the pilot mean) aborts the campaign as a loud anomaly (see
            # RecordingLM.forward). Reservation/reconcile mechanics are
            # otherwise unchanged from the sealed pilot.
            self.role_usd = {
                "task": request["task"]["reservation_input_tokens"]
                * float(models["task"]["catalog_prompt_per_token"])
                + request["task"]["reservation_output_tokens"]
                * float(models["task"]["catalog_completion_per_token"]),
                "optimizer": request["optimizer"]["reservation_input_tokens"]
                * float(models["optimizer"]["catalog_cache_write_per_token"])
                + request["optimizer"]["max_tokens"]
                * float(models["optimizer"]["catalog_completion_per_token"]),
            }
            self.usd_limit = len(manifest["seeds"]) * sum(
                ceiling["task_logical"] * self.role_usd["task"]
                + ceiling["optimizer_logical"] * self.role_usd["optimizer"]
                for ceiling in manifest["execution"]["call_ceilings"].values()
            )
            # Hard cap on ACTUAL spend: this runtime's half of the campaign's
            # new_spend_max ($60 across both runtimes).
            self.actual_usd_cap = manifest["budget"]["new_spend_max"] / 2

    def set_phase(self, seed: int, arm: str, phase: str) -> None:
        self.phase = {"seed": seed, "arm": arm, "phase": phase}

    def register_budget(self, seed: int, arm: str, ceiling: dict[str, int]) -> None:
        key = f"{seed}:{arm}"
        if key in self.call_budgets:
            raise RuntimeError(f"duplicate call-budget registration for {key}")
        self.call_budgets[key] = {
            "ceiling": copy.deepcopy(ceiling),
            "counts": {
                "task_logical": 0,
                "optimizer_logical": 0,
                "total_logical": 0,
                "transports": 0,
            },
            "refusals": [],
        }

    # Read-only live telemetry, mirroring the imp arm: a throttled small
    # plain-JSON snapshot to run_root/live/upstream.json for the observatory.
    # Write-only side channel; failures are swallowed (telemetry must never
    # take down the run).
    def write_live_snapshot(self) -> None:
        now = time.monotonic()
        if now - getattr(self, "_live_written_at", 0.0) < 10.0:
            return
        self._live_written_at = now
        try:
            atomic_write(
                OUTPUT.parent / "live" / "upstream.json",
                {
                    "runtime": "upstream",
                    "phase": self.phase,
                    "call_budgets": {
                        key: {
                            "counts": budget.get("counts"),
                            "ceiling": budget.get("ceiling"),
                            "refusals": len(budget.get("refusals", [])),
                        }
                        for key, budget in self.call_budgets.items()
                    },
                    "usd_reserved": self.usd_reserved,
                    "actual_cost": self.actual_cost,
                    "responses": len(self.calls),
                    "updated_at": int(time.time()),
                },
            )
        except Exception:
            pass

    def reserve(self, role: str) -> None:
        self.write_live_snapshot()
        if self.phase is None:
            raise RuntimeError("LM dispatch lacks an active phase")
        key = f"{self.phase['seed']}:{self.phase['arm']}"
        budget = self.call_budgets[key]
        if self.usd_limit is not None:
            projected_usd = self.usd_reserved + self.role_usd[role]
            if projected_usd > self.usd_limit + 1e-12:
                raise RuntimeError(
                    f"global USD reservation {projected_usd} exceeds {self.usd_limit}"
                )
        projected = dict(budget["counts"])
        projected[f"{role}_logical"] += 1
        projected["total_logical"] += 1
        projected["transports"] += 1
        for name, count in projected.items():
            if count > budget["ceiling"][name]:
                budget["refusals"].append(
                    {
                        "role": role,
                        "phase": copy.deepcopy(self.phase),
                        "error": f"{name}={count} ceiling={budget['ceiling'][name]}",
                    }
                )
                raise RuntimeError(
                    f"{self.phase['arm']} call budget refused {role} before dispatch: "
                    f"{name}={count} ceiling={budget['ceiling'][name]}"
                )
        budget["counts"] = projected
        if self.usd_limit is not None:
            self.usd_reserved = projected_usd

    def reconcile_cost(self, cost: float) -> None:
        projected = self.actual_cost + cost
        if projected > self.usd_reserved + 1e-6 or (
            self.usd_limit is not None and projected > self.usd_limit + 1e-6
        ):
            raise RuntimeError(
                f"actual cumulative cost {projected} exceeds reserved {self.usd_reserved}"
            )
        if self.actual_usd_cap is not None and projected > self.actual_usd_cap + 1e-6:
            raise RuntimeError(
                f"actual cumulative cost {projected} exceeds this runtime's hard "
                f"spend cap {self.actual_usd_cap} (new_spend_max/2)"
            )
        self.actual_cost = projected


def install_runtime(args: argparse.Namespace):
    dspy = install_authenticated_runtime(args)
    hard_stop = manifest_contract["execution"]["request"]["task"][
        "hard_stop_completion_tokens"
    ]

    class RecordingLM(dspy.LM):
        def __init__(self, *lm_args, capture: Capture, role: str, **lm_kwargs):
            self.expected_model = lm_kwargs.pop("expected_model", None)
            super().__init__(*lm_args, **lm_kwargs)
            self.capture = capture
            self.role = role

        def __deepcopy__(self, memo):
            # DSPy copies both task programs and rollout LMs. The LM
            # configuration may be copied, but accounting ownership must stay
            # the one shared process ledger or optimizer calls would escape
            # the pre-dispatch cap.
            duplicate = type(self).__new__(type(self))
            memo[id(self)] = duplicate
            for name, value in self.__dict__.items():
                setattr(
                    duplicate,
                    name,
                    value if name == "capture" else copy.deepcopy(value, memo),
                )
            return duplicate

        def forward(self, prompt=None, messages=None, **kwargs):
            try:
                self.capture.reserve(self.role)
            except Exception as exc:
                raise OperationalSafetyAbort(str(exc)) from exc
            started = time.monotonic()
            response = None
            error = None
            try:
                response = super().forward(prompt=prompt, messages=messages, **kwargs)
                return response
            except Exception as exc:
                error = {"type": type(exc).__name__, "message": str(exc)}
                raise OperationalSafetyAbort(
                    f"{self.role} provider transport failed: {type(exc).__name__}: {exc}"
                ) from exc
            finally:
                usage = field(response, "usage")
                choices = field(response, "choices") or []
                choice = choices[0] if choices else None
                message = field(choice, "message")
                hidden = getattr(response, "_hidden_params", {}) or {}
                self.capture.calls.append(
                    {
                        "phase": copy.deepcopy(self.capture.phase),
                        "role": self.role,
                        "request_seed": kwargs.get(
                            "seed", getattr(self, "kwargs", {}).get("seed")
                        ),
                        "prompt": prompt,
                        "messages": copy.deepcopy(messages),
                        "raw_response": {
                            "response": json_safe(response),
                            "provider_metadata": json_safe(hidden),
                        },
                        "response_metadata": {
                            "model": field(response, "model"),
                            "provider": field(response, "provider")
                            or field(hidden, "provider"),
                            "gateway": field(hidden, "custom_llm_provider"),
                            "service_tier": field(response, "service_tier")
                            or field(hidden, "service_tier"),
                            "input_tokens": field(usage, "prompt_tokens"),
                            "output_tokens": field(usage, "completion_tokens"),
                            "finish_reason": field(choice, "finish_reason"),
                            "content": field(message, "content"),
                            "gateway_reported_cost": field(usage, "cost"),
                            "computed_cost": field(hidden, "response_cost"),
                        },
                        "error": error,
                        # One forward is one adapter transport dispatch on this
                        # ledger; litellm-internal transient retries
                        # (num_retries=3, the dspy 3.2.1 default) occur beneath
                        # it and are not separately observable here. Imp's arm
                        # mirrors the same 3-retry budget with per-attempt
                        # disclosure (run_imp.exs dispatch_with_retries/3).
                        "adapter_transport_dispatch": 1,
                        "wall_seconds": time.monotonic() - started,
                    }
                )
                if response is not None and error is None and self.expected_model is not None:
                    try:
                        completion_tokens = field(usage, "completion_tokens")
                        # Hard anomaly stop (cost-guard companion): a single
                        # completion beyond 8192 tokens is ~12x the measured
                        # pilot mean (648) and 2x the 4096 p99 reservation.
                        if (
                            self.role == "task"
                            and isinstance(completion_tokens, (int, float))
                            and completion_tokens > hard_stop
                        ):
                            raise RuntimeError(
                                f"task call completion tokens {completion_tokens} "
                                f"exceed the hard stop {hard_stop}"
                            )
                        gateway_cost = field(usage, "cost")
                        if isinstance(gateway_cost, (int, float)) and gateway_cost >= 0:
                            self.capture.reconcile_cost(gateway_cost)
                        validate_mipro_optimizer_envelope(
                            self.capture, self.role, field(message, "content")
                        )
                        transport_evidence(self.capture.calls[-1], self.expected_model)
                    except Exception as exc:
                        raise OperationalSafetyAbort(str(exc)) from exc

    return dspy, RecordingLM


def validate_mipro_optimizer_envelope(capture: Capture, role: str, content: Any) -> None:
    phase = capture.phase or {}
    if role != "optimizer" or phase.get("arm") != "mipro_v2":
        return
    if not isinstance(content, str) or MIPRO_OPTIMIZER_ENVELOPE.fullmatch(content) is None:
        raise RuntimeError("MIPRO optimizer response violated the exact Chat marker envelope")


def verify_runtime_dependencies(manifest: dict[str, Any]) -> None:
    """Verify the installed DSPy environment and the effective GEPA source.

    DSPy 3.2.1 owns an installed GEPA 0.0.27 distribution while the bridge
    executes the authenticated 0.1.4 source checkout; the imported module,
    source tree, and API signature own the effective identity, distribution
    metadata is a separately checked environment fact.
    """

    if _effective_gepa_identity is None:
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
    if actual != {
        name: version for name, version in expected["packages"].items() if name != "gepa"
    }:
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

    lock = resolve(expected["lock_path"])
    if sha256_file(lock) != expected["lock_sha256"]:
        raise RuntimeError("upstream dependency lock digest drift")
    freeze = subprocess.check_output(
        [sys.executable, "-m", "pip", "freeze", "--all"], text=True
    ).splitlines()
    materialized = "\n".join(sorted(freeze)) + "\n"
    if materialized.encode("utf-8") != lock.read_bytes():
        raise RuntimeError("materialized upstream environment differs from committed lock")


def transport_evidence(call: dict[str, Any], expected: dict[str, Any]) -> dict[str, Any]:
    response = call["response_metadata"]
    evidence = {
        "actual_model": response["model"],
        "actual_route": response["provider"],
        "gateway": response["gateway"],
        "service_tier": response["service_tier"],
        "request_seed": call["request_seed"],
        "transport_attempts": call["adapter_transport_dispatch"],
        "input_tokens": response["input_tokens"],
        "output_tokens": response["output_tokens"],
        "finish_reason": response["finish_reason"],
        "content": response["content"],
        "gateway_reported_cost": response["gateway_reported_cost"],
        "computed_cost": response["computed_cost"],
    }
    configured = expected["logical"]
    model_ok = evidence["actual_model"] in (configured, expected["upstream"])
    route_ok = str(evidence["actual_route"]).lower() == expected["endpoint_provider"].lower()
    tokens_ok = (
        isinstance(evidence["input_tokens"], (int, float))
        and isinstance(evidence["output_tokens"], (int, float))
        and evidence["input_tokens"] <= expected["max_input_tokens"]
        and evidence["output_tokens"] <= expected["max_output_tokens"]
    )
    seed_ok = (
        evidence["request_seed"] == call["phase"]["seed"]
        if call["role"] == "task"
        else evidence["request_seed"] is None
    )
    if not (
        model_ok
        and route_ok
        and seed_ok
        and evidence["transport_attempts"] == 1
        and tokens_ok
        and isinstance(evidence["finish_reason"], str)
        and isinstance(evidence["content"], str)
        and evidence["gateway"] == "openrouter"
        and evidence["service_tier"] in (None, "default", "standard")
        and isinstance(evidence["gateway_reported_cost"], (int, float))
        and evidence["gateway_reported_cost"] >= 0
        and isinstance(evidence["computed_cost"], (int, float))
        and evidence["computed_cost"] >= 0
        and abs(
            Decimal(str(evidence["gateway_reported_cost"]))
            - Decimal(str(evidence["computed_cost"]))
        )
        <= Decimal("0.000001")
    ):
        raise RuntimeError(f"missing or drifted upstream transport evidence: {evidence!r}")
    evidence["cost"] = {
        "gateway_reported": evidence["gateway_reported_cost"],
        "adapter_computed": evidence["computed_cost"],
        "tolerance": 1e-6,
    }
    return evidence


def model_contract(manifest: dict[str, Any], role: str) -> dict[str, Any]:
    return {
        **manifest["models"][role],
        "max_input_tokens": manifest["execution"]["request"][role]["max_input_tokens"],
        "max_output_tokens": manifest["execution"]["request"][role]["max_tokens"],
    }


def openrouter_body(manifest: dict[str, Any], role: str) -> dict[str, Any]:
    routing = manifest["execution"]["openrouter"]
    return {
        "provider": {
            "only": routing[f"{role}_only"],
            "order": routing[f"{role}_order"],
            "allow_fallbacks": False,
            "require_parameters": True,
            "data_collection": "deny",
            "max_price": routing[f"{role}_max_price_per_million"],
        },
        "usage": {"include": True},
    }


def call_counts(calls: list[dict[str, Any]]) -> dict[str, int]:
    task = sum(call["role"] == "task" for call in calls)
    optimizer = sum(call["role"] == "optimizer" for call in calls)
    return {
        "task_logical": task,
        "optimizer_logical": optimizer,
        "total_logical": task + optimizer,
        "transports": sum(call["adapter_transport_dispatch"] for call in calls),
    }


def validate_call_slice(
    calls: list[dict[str, Any]],
    arm: str,
    manifest: dict[str, Any],
    reserved_held_out_task: int,
) -> dict[str, int]:
    ceiling = dict(manifest["execution"]["call_ceilings"][arm])
    for key in ("task_logical", "total_logical", "transports"):
        ceiling[key] -= reserved_held_out_task
    counts = call_counts(calls)
    if (
        any(counts[key] > limit for key, limit in ceiling.items())
        or counts["total_logical"] != counts["transports"]
    ):
        raise RuntimeError(
            f"{arm} exceeded or mismatched call ceiling: counts={counts!r} ceiling={ceiling!r}"
        )
    for call in calls:
        transport_evidence(call, model_contract(manifest, call["role"]))
    return counts


def validate_combined_ceiling(
    arm: str, first: dict[str, int], second: dict[str, int], manifest: dict[str, Any]
) -> dict[str, int]:
    combined = {key: first[key] + second[key] for key in first}
    ceiling = manifest["execution"]["call_ceilings"][arm]
    if (
        any(combined[key] > limit for key, limit in ceiling.items())
        or combined["total_logical"] != combined["transports"]
    ):
        raise RuntimeError(
            f"{arm} exceeded complete call ceiling: counts={combined!r} ceiling={ceiling!r}"
        )
    return combined


def build_program(dspy: Any, task_lm: Any):
    from ifbench_stock_module import IFBenchCoT2StageModule

    program = IFBenchCoT2StageModule()
    program.set_lm(task_lm)
    return program


def examples(dspy: Any, rows: list[dict[str, str]], feedback_allowed: bool) -> list[Any]:
    return [
        dspy.Example(
            prompt=row["prompt"],
            instruction_id_list=copy.deepcopy(row["instruction_id_list"]),
            kwargs=copy.deepcopy(row["kwargs"]),
            feedback_allowed=feedback_allowed,
            source_id=row["source_id"],
        ).with_inputs("prompt")
        for row in rows
    ]


def semantic_metric(dspy: Any):
    from gepa_artifact.benchmarks.IFBench.ifbench_metric import metric_with_feedback

    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        scored = pred
        if pred_name is not None and pred_trace:
            predictor_output = pred_trace[-1][2]
            value = getattr(predictor_output, "response", None)
            if value is None:
                value = getattr(predictor_output, "final_response", None)
            scored = dspy.Prediction(response=value)
        return metric_with_feedback(gold, scored, trace)

    return metric


def scalar_metric(gold, pred, trace=None) -> float:
    from gepa_artifact.benchmarks.IFBench.ifbench_metric import metric

    return metric(gold, pred, trace)


def _trial_ledger(arm, compiled):
    # Per-trial optimizer evidence (upstream auditability gap from the pilot:
    # stock seals carried no trial scores, making selections unadjudicable).
    # Read-only over what pinned DSPy attaches with track_stats=True;
    # absence is recorded honestly, never fatal.
    try:
        sys.path.insert(0, str(IMP_ROOT / "scripts"))
        from upstream_trial_sealing import extract_trial_ledger

        return extract_trial_ledger(arm=("mipro" if arm == "mipro_v2" else arm), program=compiled)
    except Exception as error:  # noqa: BLE001 - sealing must never kill the run
        return {"available": False, "reason": f"ledger extraction failed: {error!r}"}


def compile_arm(
    dspy: Any,
    arm: str,
    program: Any,
    train: list[Any],
    selection: list[Any],
    seed: int,
    task_lm: Any,
    optimizer_lm: Any,
    metric: Any,
    config: dict[str, Any],
) -> Any:
    if arm == "baseline":
        return program
    if arm == "gepa":
        gepa = config["optimizer"]["gepa"]
        if _patched_dspy_gepa is None:
            raise RuntimeError("failure-preserving GEPA adapter is not loaded")
        # Semantic budget 1200 metric calls: ~1/3 of the paper's 3,593-call
        # IFBench regime; the failure-preserving stock-DSPy adapter patch
        # stays active for the whole GEPA compile, exactly as in gepa014.
        with _patched_dspy_gepa():
            return dspy.GEPA(
                metric=metric,
                max_metric_calls=gepa["semantic_max_metric_calls"],
                reflection_minibatch_size=gepa["minibatch_size"],
                candidate_selection_strategy="pareto",
                reflection_lm=optimizer_lm,
                component_selector="round_robin",
                use_merge=False,
                num_threads=1,
                track_stats=True,
                seed=seed,
                gepa_kwargs={"acceptance_criterion": "strict_improvement"},
            ).compile(program, trainset=train, valset=selection)
    if arm == "mipro_v2":
        mipro = config["optimizer"]["mipro_v2"]
        return dspy.MIPROv2(
            metric=scalar_metric,
            prompt_model=optimizer_lm,
            task_model=task_lm,
            auto=None,
            # 6 candidates / 9 trials: the largest MIPROv2 budget imp's pinned
            # Optuna-startup fidelity supports (see call-ceiling note).
            num_candidates=mipro["num_candidates"],
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            num_threads=1,
            track_stats=True,
            # Refusal tolerance (carried from the sealed pilot, owner-approved):
            # 48 = train(16)+selection(32); refused/unparseable rows score 0
            # like native dspy.Evaluate. Operational errors stay fatal.
            max_errors=48,
            seed=seed,
        ).compile(
            program,
            trainset=train,
            valset=selection,
            num_trials=mipro["trials"],
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            seed=seed,
            minibatch=False,
            program_aware_proposer=False,
            data_aware_proposer=True,
            tip_aware_proposer=True,
            fewshot_aware_proposer=False,
            view_data_batch_size=10,
        )
    raise RuntimeError(f"unknown arm {arm}")


def evaluate(
    program: Any,
    rows: list[dict[str, str]],
    task_lm: Any,
    capture: Capture,
    expected_model: dict[str, Any],
) -> list[dict[str, Any]]:
    output = []
    for row in rows:
        before = len(capture.calls)
        started = time.monotonic()
        error = None
        prediction = None
        try:
            prediction = program(prompt=row["prompt"])
            actual = getattr(prediction, "response", None)
        except Exception as exc:
            actual = None
            error = {"type": type(exc).__name__, "message": str(exc)}
        calls = [call for call in capture.calls[before:] if call["role"] == "task"]
        if len(calls) not in (1, 2):
            raise RuntimeError(
                f"{row['source_id']} used an invalid two-stage call envelope: {len(calls)}"
            )
        evidences = [transport_evidence(call, expected_model) for call in calls]
        score = (
            0.0
            if prediction is None
            else scalar_metric(examples(__import__("dspy"), [row], False)[0], prediction)
        )
        output.append(
            {
                "source_id": row["source_id"],
                "instruction_id_list": row["instruction_id_list"],
                "raw_response": [call["raw_response"] for call in calls],
                "parsed_response": actual,
                "score": score,
                "error": error,
                "rendered_messages": [call["messages"] for call in calls],
                "transport_evidence": evidences,
                "input_tokens": sum(evidence["input_tokens"] for evidence in evidences),
                "output_tokens": sum(evidence["output_tokens"] for evidence in evidences),
                "gateway_reported_cost": sum(
                    evidence["gateway_reported_cost"] for evidence in evidences
                ),
                "adapter_computed_cost": sum(
                    evidence["computed_cost"] for evidence in evidences
                ),
                "transport_attempts": [
                    evidence["transport_attempts"] for evidence in evidences
                ],
                "wall_seconds": time.monotonic() - started,
            }
        )
    return output


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "mean_constraint_score": sum(row["score"] for row in rows) / len(rows),
        "parse_errors": sum(row["error"] is not None for row in rows),
        "count": len(rows),
    }


def parameter_snapshot(program: Any) -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "instruction": predictor.signature.instructions,
            "demos": json_safe(getattr(predictor, "demos", [])),
        }
        for name, predictor in program.named_predictors()
    ]


def seal(
    seed: int,
    arm: str,
    program: Any,
    selection_rows: list[dict[str, Any]],
    manifest: dict[str, Any],
    preheld_call_counts: dict[str, int],
) -> dict[str, Any]:
    payload = {
        "schema_version": 3,
        "runtime": "upstream",
        "seed": seed,
        "arm": arm,
        "manifest_sha256": manifest["manifest_sha256"],
        "source_commits": source_commits(manifest),
        "selection": aggregate(selection_rows),
        "selection_rows": selection_rows,
        "selected_parameters": parameter_snapshot(program),
        "trial_ledger": _trial_ledger(arm, program),
        "preheld_call_counts": preheld_call_counts,
    }
    payload["payload_sha256"] = sha256_bytes(
        json.dumps(json_safe(payload), sort_keys=True, separators=(",", ":")).encode()
    )
    path = OUTPUT.parent / "sealed" / f"upstream-{seed}-{arm}.json"
    atomic_write(path, payload)
    return {
        "program": program,
        "artifact_path": str(path),
        "artifact_sha256": sha256_file(path),
        **payload,
    }


def run(args: argparse.Namespace) -> None:
    global ACTIVE_CAPTURE
    manifest = load_manifest(args)
    commits = source_commits(manifest)
    verify_clean_imp_tree()
    dspy, RecordingLM = install_runtime(args)
    verify_runtime_dependencies(manifest)
    catalog_snapshot = verify_models(manifest)
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))
    capture = Capture(manifest)
    ACTIVE_CAPTURE = capture
    request = manifest["execution"]["request"]
    splits = manifest["dataset"]["split_ids"]
    train_rows = stream_rows(Path(manifest["dataset"]["train_path"]), splits["train"])
    selection_source = stream_rows(
        Path(manifest["dataset"]["selection_path"]), splits["selection"]
    )
    metric = semantic_metric(dspy)
    sealed = []

    for seed in manifest["seeds"]:
        for arm in manifest["arms"]:
            capture.register_budget(seed, arm, manifest["execution"]["call_ceilings"][arm])
            before_arm = len(capture.calls)
            task_lm = RecordingLM(
                manifest["models"]["task"]["upstream"],
                api_base="https://openrouter.ai/api/v1",
                api_key=os.environ["OPENROUTER_API_KEY"],
                cache=False,
                num_retries=3,  # dspy 3.2.1 default: transient transport retries (lm.py:41)
                capture=capture,
                role="task",
                seed=seed,
                expected_model=model_contract(manifest, "task"),
                max_tokens=request["task"]["max_tokens"],
                extra_body=openrouter_body(manifest, "task"),
            )
            optimizer_lm = RecordingLM(
                manifest["models"]["optimizer"]["upstream"],
                api_base="https://openrouter.ai/api/v1",
                api_key=os.environ["OPENROUTER_API_KEY"],
                cache=False,
                num_retries=3,  # dspy 3.2.1 default: transient transport retries (lm.py:41)
                capture=capture,
                role="optimizer",
                temperature=request["optimizer"]["temperature"],
                expected_model=model_contract(manifest, "optimizer"),
                max_tokens=request["optimizer"]["max_tokens"],
                extra_body=openrouter_body(manifest, "optimizer"),
            )
            program = build_program(dspy, task_lm)
            capture.set_phase(seed, arm, "compile")
            selected = compile_arm(
                dspy,
                arm,
                program,
                examples(dspy, train_rows, True),
                examples(dspy, selection_source, False),
                seed,
                task_lm,
                optimizer_lm,
                metric,
                manifest,
            )
            capture.set_phase(seed, arm, "selection")
            selected_rows = evaluate(
                selected, selection_source, task_lm, capture, model_contract(manifest, "task")
            )
            preheld_call_counts = validate_call_slice(
                capture.calls[before_arm:], arm, manifest, reserved_held_out_task=128
            )
            sealed.append(
                seal(seed, arm, selected, selected_rows, manifest, preheld_call_counts)
            )

    # Durably record every selected artifact before the held-out loader exists.
    atomic_write(
        SELECTION_OUTPUT,
        {
            "schema_version": 3,
            "runtime": "upstream",
            "status": "selection_sealed",
            "held_out_loaded": False,
            "manifest_sha256": manifest["manifest_sha256"],
            "source_commits": commits,
            "selections": [
                {key: value for key, value in item.items() if key != "program"}
                for item in sealed
            ],
        },
    )
    wait_for_peer_selection(manifest)
    held_out_path = Path(manifest["dataset"]["held_out_path"])
    if sha256_file(held_out_path) != manifest["dataset"]["held_out_sha256"]:
        raise RuntimeError("IFBench held-out split drift")
    held_out = stream_rows(held_out_path, splits["held_out"])
    completed = []
    for selected in sealed:
        capture.set_phase(selected["seed"], selected["arm"], "held_out")
        before_held = len(capture.calls)
        rows = evaluate(
            selected["program"], held_out, None, capture, model_contract(manifest, "task")
        )
        held_calls = capture.calls[before_held:]
        held_counts = call_counts(held_calls)
        expected_held = {
            "task_logical": 128,
            "optimizer_logical": 0,
            "total_logical": 128,
            "transports": 128,
        }
        if (
            any(held_counts[key] > limit for key, limit in expected_held.items())
            or held_counts["total_logical"] != held_counts["transports"]
        ):
            raise RuntimeError(
                f"{selected['arm']} held-out call accounting drift: "
                f"counts={held_counts!r} ceiling={expected_held!r}"
            )
        for call in held_calls:
            transport_evidence(call, model_contract(manifest, call["role"]))
        validate_combined_ceiling(
            selected["arm"], selected["preheld_call_counts"], held_counts, manifest
        )
        public = {key: value for key, value in selected.items() if key != "program"}
        public["held_out"] = aggregate(rows)
        public["rows"] = {"selection": selected["selection_rows"], "held_out": rows}
        public["held_out_call_counts"] = held_counts
        completed.append(public)

    by_seed = [
        {"seed": seed, "arms": [row for row in completed if row["seed"] == seed]}
        for seed in manifest["seeds"]
    ]
    result = {
        "schema_version": 3,
        "runtime": "upstream",
        "status": "complete",
        "manifest_sha256": manifest["manifest_sha256"],
        "source_commits": commits,
        "bootstrap_digest": _bootstrap_digest,
        "selection_receipt": str(SELECTION_OUTPUT),
        "seeds": by_seed,
        "calls": capture.calls,
        "call_budgets": capture.call_budgets,
        "catalog_snapshot": catalog_snapshot,
        "claim_boundary": (
            "one-seed engineering rehearsal of the source-faithful 16384-token "
            "config; claims nothing scientifically about v3/gepa014 equivalence"
        ),
    }
    atomic_write(OUTPUT, result)
    print(json.dumps(json_safe(result), indent=2, sort_keys=True))


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
    return {
        "call_budgets": budgets,
        "ledger": {
            "reserved": reserved,
            "transmitted": transmitted,
            "completed": completed,
            "failed": failed,
            "in_flight": transmitted - completed - failed,
            "reserved_not_transmitted": reserved - transmitted,
            "transmission_observation": "forward_finally_transport_bound",
        },
    }


def shadow_preflight(args: argparse.Namespace) -> None:
    """Run the authenticated production peer through two local TLS transports."""

    if os.environ.get("OPENROUTER_API_KEY", "").strip() != "":
        raise RuntimeError("upstream shadow preflight received provider authority")
    api_base_url = os.environ["MATCHED_IFBENCH_R16K_API_BASE_URL"]
    catalog_base_url = os.environ["MATCHED_IFBENCH_R16K_CATALOG_BASE_URL"]
    health_url = os.environ["MATCHED_IFBENCH_R16K_HEALTH_URL"]
    ca_cert = Path(os.environ["MATCHED_IFBENCH_R16K_TLS_CA_CERT"]).resolve()
    if os.environ.get("SSL_CERT_FILE") != str(ca_cert):
        raise RuntimeError("upstream shadow TLS trust does not match the owned CA")

    tls_context = __import__("ssl").create_default_context(cafile=str(ca_cert))
    with urllib.request.urlopen(health_url, context=tls_context, timeout=5) as response:
        readiness = json.load(response)
    if readiness != {"status": "ready"}:
        raise RuntimeError("upstream shadow TLS readiness response drift")

    manifest = load_manifest(args)
    # Shadow mode makes zero provider calls; the uncommitted rehearsal surface
    # is the unit under test, so the strict clean-tree gate applies only to
    # the live path (run/1 via verify_clean_imp_tree).
    dspy, RecordingLM = install_runtime(args)
    verify_runtime_dependencies(manifest)
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))
    catalog_roles = []
    for role in ("task", "optimizer"):
        expected = manifest["models"][role]
        with urllib.request.urlopen(
            catalog_base_url + f"/models/{expected['logical']}/endpoints",
            context=tls_context,
            timeout=5,
        ) as response:
            endpoints = json.load(response).get("data", {}).get("endpoints", [])
        eligible = eligible_endpoints(
            endpoints,
            expected,
            role,
            manifest["execution"]["openrouter"][f"{role}_order"],
        )
        if not eligible:
            raise RuntimeError(f"upstream shadow {role} catalog guard failed")
        catalog_roles.append(role)
    capture = Capture(manifest)
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
        api_base=api_base_url,
        api_key="local-shadow-only",
        cache=False,
        num_retries=3,  # dspy 3.2.1 default: transient transport retries (lm.py:41)
        capture=capture,
        role="task",
        seed=17,
        max_tokens=request["task"]["max_tokens"],
        extra_body=openrouter_body(manifest, "task"),
    )
    task.forward(messages=[{"role": "user", "content": "shadow task"}], seed=17)
    capture.set_phase(0, "shadow", "optimizer")
    optimizer = RecordingLM(
        manifest["models"]["optimizer"]["upstream"],
        api_base=api_base_url,
        api_key="local-shadow-only",
        cache=False,
        num_retries=3,  # dspy 3.2.1 default: transient transport retries (lm.py:41)
        capture=capture,
        role="optimizer",
        temperature=request["optimizer"]["temperature"],
        max_tokens=request["optimizer"]["max_tokens"],
        extra_body=openrouter_body(manifest, "optimizer"),
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
                "bootstrap_digest": _bootstrap_digest,
            },
            sort_keys=True,
        ),
        flush=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--gepa-artifact-root", type=Path, required=True)
    parser.add_argument("--ifbench-site-packages", type=Path, required=True)
    args = parser.parse_args()

    if os.environ.get("OPENROUTER_API_KEY", "").strip() == "":
        shadow_preflight(args)
        return

    def coordinated_stop(signum: int, _frame: Any) -> None:
        raise CoordinatedStop(f"coordinator signal {signum}")

    signal.signal(signal.SIGTERM, coordinated_stop)
    try:
        run(args)
    except BaseException as exc:
        try:
            manifest = json.loads(MANIFEST_PATH.read_text())
            commits = source_commits(manifest)
        except Exception:
            commits = {"imp": "unavailable", "dspy": "unavailable", "gepa": "unavailable"}
        stopped = {
            "schema_version": 3,
            "runtime": "upstream",
            "status": "stopped",
            "manifest_sha256": sha256_file(MANIFEST_PATH),
            "launch_commit": os.environ.get(
                "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT", "unavailable"
            ),
            "bootstrap_digest": _bootstrap_digest or "unavailable",
            "source_commits": commits,
            "call_budgets": ACTIVE_CAPTURE.call_budgets if ACTIVE_CAPTURE else {},
            "calls": ACTIVE_CAPTURE.calls if ACTIVE_CAPTURE else [],
            "actual_cost": ACTIVE_CAPTURE.actual_cost if ACTIVE_CAPTURE else 0.0,
            "usd_reserved": ACTIVE_CAPTURE.usd_reserved if ACTIVE_CAPTURE else 0.0,
            "error": repr(exc),
        }
        stopped["rescue_accounting"] = rescue_accounting(stopped)
        stopped["response_ledger"] = [
            call
            for call in stopped["calls"]
            if call.get("raw_response", {}).get("response") is not None
        ]
        atomic_write(OUTPUT, stopped)
        raise


if __name__ == "__main__":
    main()
