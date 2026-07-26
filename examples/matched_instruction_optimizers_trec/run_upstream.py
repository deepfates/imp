#!/usr/bin/env python3
"""Pinned DSPy/GEPA side of the matched local TREC consumer example.

This runner deliberately has two data phases. It does not decode an untouched
row until every seed/arm has been selected and its parameter artifact fsynced.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any, Literal


HERE = Path(__file__).resolve().parent
IMP_ROOT = HERE.parents[1]
MANIFEST_PATH = HERE / "contract.json"
OUTPUT = Path(
    os.environ.get(
        "UPSTREAM_MATCHED_TREC_OUTPUT",
        IMP_ROOT / "tmp" / "matched_instruction_optimizers_trec" / "upstream-result.json",
    )
)
SELECTION_OUTPUT = Path(str(OUTPUT) + ".selection-sealed.json")
ID_RE = re.compile(rb'"id"\s*:\s*"([^"]+)"')
ACTIVE_CAPTURE: "Capture | None" = None


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


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
    peer = Path(os.environ.get(
        "IMP_MATCHED_TREC_IMP_SELECTION",
        str(IMP_ROOT / "tmp/matched_instruction_optimizers_trec/imp-result.json.selection-sealed.json"),
    ))
    deadline = time.monotonic() + 1800
    while True:
        if peer.is_file():
            receipt = json.loads(peer.read_text())
            if not (
                receipt.get("runtime") == "imp"
                and receipt.get("status") == "selection_sealed"
                and receipt.get("held_out_loaded") is False
                and receipt.get("manifest_sha256") == manifest["manifest_sha256"]
                and len(receipt.get("selections", [])) == 9
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
    return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()


def source_commits(manifest: dict[str, Any]) -> dict[str, str]:
    return {
        "imp": owned_git_head(IMP_ROOT),
        "dspy": manifest["authorities"]["dspy"]["commit"],
        "gepa": manifest["authorities"]["gepa"]["commit"],
    }


def verify_clean_imp_tree() -> None:
    changed = subprocess.check_output(
        ["git", "-C", str(IMP_ROOT), "status", "--porcelain", "--untracked-files=all"],
        text=True,
    ).strip()
    if changed:
        raise RuntimeError(f"Imp launch tree is not clean:\n{changed}")


def resolve(relative: str) -> Path:
    return (HERE / relative).resolve()


def load_manifest(args: argparse.Namespace) -> dict[str, Any]:
    manifest = json.loads(MANIFEST_PATH.read_text())
    manifest["manifest_sha256"] = sha256_file(MANIFEST_PATH)
    if manifest.get("schema_version") != 3 or manifest.get("intent") != "sealed_strong_model_matched_system_comparison":
        raise RuntimeError("strong matched manifest schema/intent drift")
    if manifest.get("seeds") != [2026072602, 2026072603, 2026072604] or manifest.get("arms") != ["baseline", "gepa", "mipro_v2"]:
        raise RuntimeError("strong matched seed/arm contract drift")
    expected_ceilings = {
        "baseline": {"task_logical": 120, "optimizer_logical": 0, "transports": 120, "total_logical": 120},
        "gepa": {"task_logical": 400, "optimizer_logical": 4, "transports": 404, "total_logical": 404},
        "mipro_v2": {"task_logical": 620, "optimizer_logical": 9, "transports": 629, "total_logical": 629},
    }
    if manifest.get("execution", {}).get("call_ceilings") != expected_ceilings:
        raise RuntimeError("diagnostic call-ceiling contract drift")
    if manifest.get("optimizer", {}).get("mipro_v2", {}).get("num_candidates") != 6:
        raise RuntimeError("MIPRO public num_candidates contract drift")
    splits = manifest.get("dataset", {}).get("splits", {})
    if [len(splits.get(name, [])) for name in ("train_ids", "selection_ids", "held_out_ids")] != [20, 40, 80]:
        raise RuntimeError("strong matched split-size contract drift")
    all_ids = splits["train_ids"] + splits["selection_ids"] + splits["held_out_ids"]
    if len(set(all_ids)) != 140:
        raise RuntimeError("strong matched splits overlap")
    manifest["dataset"]["data_path"] = str(resolve(manifest["dataset"]["data_path"]))
    manifest["dataset"]["contract_path"] = str(resolve(manifest["dataset"]["contract_path"]))
    manifest["dataset"]["train_path"] = str(resolve(manifest["dataset"]["train_path"]))
    manifest["dataset"]["selection_path"] = str(resolve(manifest["dataset"]["selection_path"]))
    manifest["dataset"]["held_out_path"] = str(resolve(manifest["dataset"]["held_out_path"]))

    expected = {name: manifest["authorities"][name]["commit"] for name in ("dspy", "gepa")}
    # The DSPy tree is a receipt-authenticated export rather than a Git checkout;
    # never let Git walk upward and accidentally authenticate it as the Imp repo.
    if (args.dspy_root / ".git").exists():
        if owned_git_head(args.dspy_root) != expected["dspy"]:
            raise RuntimeError("pinned DSPy checkout commit drift")
    if owned_git_head(args.gepa_root) != expected["gepa"]:
        raise RuntimeError("pinned GEPA checkout commit drift")

    for authority, root in (("dspy", args.dspy_root), ("gepa", args.gepa_root)):
        receipt = json.loads(resolve(manifest["authorities"][authority]["source_manifest"]).read_text())
        if receipt["commit"] != expected[authority]:
            raise RuntimeError(f"{authority} source receipt commit drift")
        for entry in receipt["files"]:
            if sha256_file(root / entry["path"]) != entry["sha256"]:
                raise RuntimeError(f"{authority} pinned source drift: {entry['path']}")

    dataset = manifest["dataset"]
    if sha256_file(Path(dataset["contract_path"])) != dataset["contract_sha256"]:
        raise RuntimeError("TREC split contract drift")
    for split in ("train", "selection"):
        if sha256_file(Path(dataset[f"{split}_path"])) != dataset[f"{split}_sha256"]:
            raise RuntimeError(f"TREC {split} split drift")
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
                row = json.loads(line)
                prefix = row["label"].split(":", 1)[0]
                found[row_id] = {
                    "id": row_id,
                    "text": row["text"],
                    "route": {"DESC": "K11", "ENTY": "K47"}[prefix],
                }
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
        required = {"max_tokens", "seed", "response_format"} if role == "task" else {"max_tokens", "temperature"}
        exact = next((endpoint for endpoint in endpoints if
            endpoint.get("provider_name") == expected["endpoint_provider"]
            and endpoint.get("tag") in (None, "default", "standard")
            and float(endpoint.get("pricing", {}).get("prompt", "inf")) <= float(expected["catalog_prompt_per_token"])
            and float(endpoint.get("pricing", {}).get("completion", "inf")) <= float(expected["catalog_completion_per_token"])
            and required.issubset(set(endpoint.get("supported_parameters", [])))), None)
        if exact is None:
            raise RuntimeError(f"no exact first-party {role} endpoint satisfies pricing/parameter/default-tier guard")
        encoded = json.dumps(exact, sort_keys=True, separators=(",", ":")).encode()
        snapshots[role] = {
            "endpoint_url": url,
            "model": expected["logical"],
            "endpoint": exact,
            "sha256": hashlib.sha256(encoded).hexdigest(),
        }
    return snapshots


class Capture:
    def __init__(self, manifest: dict[str, Any] | None = None) -> None:
        self.phase: dict[str, Any] | None = None
        self.calls: list[dict[str, Any]] = []
        self.call_budgets: dict[str, dict[str, Any]] = {}
        self.usd_reserved = 0.0
        self.actual_cost = 0.0
        self.role_usd: dict[str, float] = {}
        self.usd_limit: float | None = None
        self.max_input_tokens: dict[str, int] = {}
        if manifest is not None:
            request = manifest["execution"]["request"]
            models = manifest["models"]
            self.role_usd = {
                "task": request["task"]["reservation_input_tokens"] * float(models["task"]["catalog_prompt_per_token"])
                + request["task"]["max_tokens"] * float(models["task"]["catalog_completion_per_token"]),
                "optimizer": request["optimizer"]["reservation_input_tokens"] * float(models["optimizer"]["catalog_cache_write_per_token"])
                + request["optimizer"]["max_tokens"] * float(models["optimizer"]["catalog_completion_per_token"]),
            }
            self.usd_limit = len(manifest["seeds"]) * sum(
                ceiling["task_logical"] * self.role_usd["task"]
                + ceiling["optimizer_logical"] * self.role_usd["optimizer"]
                for ceiling in manifest["execution"]["call_ceilings"].values()
            )
            self.max_input_tokens = {
                role: request[role]["max_input_tokens"] for role in ("task", "optimizer")
            }

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

    def reserve(self, role: str) -> None:
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
        self.actual_cost = projected


def install_runtime(args: argparse.Namespace):
    sys.path.insert(0, str(args.gepa_root / "src"))
    sys.path.insert(0, str(args.dspy_root))
    import dspy

    class RecordingLM(dspy.LM):
        def __init__(self, *lm_args, capture: Capture, role: str, **lm_kwargs):
            self.expected_model = lm_kwargs.pop("expected_model", None)
            super().__init__(*lm_args, **lm_kwargs)
            self.capture = capture
            self.role = role

        def __deepcopy__(self, memo):
            # DSPy copies both task programs and rollout LMs. The LM configuration
            # may be copied, but accounting ownership must remain the one shared
            # process ledger or optimizer calls would escape the pre-dispatch cap.
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
            rendered = json.dumps(
                messages if messages is not None else {"prompt": prompt},
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            framed_bound = len(rendered) + 16 * ((len(messages) if messages is not None else 1) + 1)
            cap = self.capture.max_input_tokens.get(self.role)
            if cap is not None and framed_bound > cap:
                raise RuntimeError(
                    f"{self.role} rendered request conservative token bound {framed_bound} exceeds {cap}"
                )
            self.capture.reserve(self.role)
            started = time.monotonic()
            response = None
            error = None
            try:
                response = super().forward(prompt=prompt, messages=messages, **kwargs)
                return response
            except Exception as exc:
                error = {"type": type(exc).__name__, "message": str(exc)}
                raise
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
                        "request_seed": kwargs.get("seed", getattr(self, "kwargs", {}).get("seed")),
                        "prompt": prompt,
                        "messages": copy.deepcopy(messages),
                        "raw_response": {
                            "response": json_safe(response),
                            "provider_metadata": json_safe(hidden),
                        },
                        "response_metadata": {
                            "model": field(response, "model"),
                            "provider": field(response, "provider") or field(hidden, "provider"),
                            "gateway": field(hidden, "custom_llm_provider"),
                            "service_tier": field(response, "service_tier") or field(hidden, "service_tier"),
                            "input_tokens": field(usage, "prompt_tokens"),
                            "output_tokens": field(usage, "completion_tokens"),
                            "finish_reason": field(choice, "finish_reason"),
                            "content": field(message, "content"),
                            "gateway_reported_cost": field(usage, "cost"),
                            "computed_cost": field(hidden, "response_cost"),
                        },
                        "error": error,
                        # One forward with num_retries=0 is one adapter transport dispatch.
                        "adapter_transport_dispatch": 1,
                        "wall_seconds": time.monotonic() - started,
                    }
                )
                if response is not None and error is None and self.expected_model is not None:
                    evidence = transport_evidence(self.capture.calls[-1], self.expected_model)
                    self.capture.reconcile_cost(evidence["gateway_reported_cost"])

    return dspy, RecordingLM


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
    tokens_ok = isinstance(evidence["input_tokens"], (int, float)) and isinstance(
        evidence["output_tokens"], (int, float)
    ) and evidence["input_tokens"] <= expected["max_input_tokens"]
    if not (
        model_ok
        and route_ok
        and evidence["transport_attempts"] == 1
        and tokens_ok
        and isinstance(evidence["finish_reason"], str)
        and isinstance(evidence["content"], str)
        and evidence["gateway"] == "openrouter"
        and evidence["service_tier"] in (None, "default", "standard")
        and isinstance(evidence["gateway_reported_cost"], (int, float)) and evidence["gateway_reported_cost"] >= 0
        and isinstance(evidence["computed_cost"], (int, float)) and evidence["computed_cost"] >= 0
        and abs(evidence["gateway_reported_cost"] - evidence["computed_cost"]) <= 1e-6
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


def validate_call_slice(calls: list[dict[str, Any]], arm: str, manifest: dict[str, Any],
                        reserved_held_out_task: int) -> dict[str, int]:
    ceiling = dict(manifest["execution"]["call_ceilings"][arm])
    for key in ("task_logical", "total_logical", "transports"):
        ceiling[key] -= reserved_held_out_task
    counts = call_counts(calls)
    if any(counts[key] > limit for key, limit in ceiling.items()) or counts["total_logical"] != counts["transports"]:
        raise RuntimeError(f"{arm} exceeded or mismatched call ceiling: counts={counts!r} ceiling={ceiling!r}")
    for call in calls:
        transport_evidence(call, model_contract(manifest, call["role"]))
    return counts


def validate_combined_ceiling(arm: str, first: dict[str, int], second: dict[str, int],
                              manifest: dict[str, Any]) -> dict[str, int]:
    combined = {key: first[key] + second[key] for key in first}
    ceiling = manifest["execution"]["call_ceilings"][arm]
    if any(combined[key] > limit for key, limit in ceiling.items()) or combined["total_logical"] != combined["transports"]:
        raise RuntimeError(f"{arm} exceeded complete call ceiling: counts={combined!r} ceiling={ceiling!r}")
    return combined


def route_meanings(manifest: dict[str, Any]) -> dict[str, str]:
    task = json.loads(Path(manifest["dataset"]["contract_path"]).read_text())
    return {value["route"]: value["meaning"] for value in task["route_mapping"].values()}


def build_program(dspy: Any, task_lm: Any):
    class RouteSignature(dspy.Signature):
        """Route the question to exactly one opaque code. Return only the required structured route."""

        text: str = dspy.InputField()
        route: Literal["K11", "K47"] = dspy.OutputField()

    program = dspy.Predict(RouteSignature)
    program.set_lm(task_lm)
    return program


def examples(dspy: Any, rows: list[dict[str, str]], feedback_allowed: bool) -> list[Any]:
    return [
        dspy.Example(
            text=row["text"],
            route=row["route"],
            feedback_allowed=feedback_allowed,
            source_id=row["id"],
        ).with_inputs("text")
        for row in rows
    ]


def semantic_metric(meanings: dict[str, str]):
    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        actual = getattr(pred, "route", None)
        expected = gold.route
        score = 1.0 if actual == expected else 0.0
        if not getattr(gold, "feedback_allowed", False):
            return score
        expected_meaning = meanings[expected]
        actual_meaning = meanings.get(actual, "unknown service")
        feedback = (
            f"Correct: {expected} handles {expected_meaning}."
            if score == 1.0
            else f"Expected {expected} for {expected_meaning}; {actual} represents {actual_meaning}."
        )
        import dspy

        return dspy.Prediction(score=score, feedback=feedback)

    return metric


def scalar_metric(gold, pred, trace=None) -> float:
    return 1.0 if getattr(pred, "route", None) == gold.route else 0.0


def compile_arm(dspy: Any, arm: str, program: Any, train: list[Any], selection: list[Any], seed: int,
                task_lm: Any, optimizer_lm: Any, metric: Any, config: dict[str, Any]) -> Any:
    if arm == "baseline":
        return program
    if arm == "gepa":
        gepa = config["optimizer"]["gepa"]
        return dspy.GEPA(
            metric=metric,
            max_metric_calls=len(selection) + gepa["iterations"] * (2 * gepa["minibatch_size"] + len(selection)),
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
            num_candidates=mipro["num_candidates"],
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            num_threads=1,
            max_errors=0,
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


def evaluate(program: Any, rows: list[dict[str, str]], task_lm: Any, capture: Capture,
             expected_model: dict[str, Any]) -> list[dict[str, Any]]:
    output = []
    for row in rows:
        before = len(capture.calls)
        started = time.monotonic()
        error = None
        prediction = None
        try:
            prediction = program(text=row["text"])
            actual = getattr(prediction, "route", None)
        except Exception as exc:
            actual = None
            error = {"type": type(exc).__name__, "message": str(exc)}
        calls = [call for call in capture.calls[before:] if call["role"] == "task"]
        if len(calls) != 1:
            raise RuntimeError(f"{row['id']} used {len(calls)} task adapter transports, expected one")
        evidence = transport_evidence(calls[0], expected_model)
        if actual not in ("K11", "K47"):
            error = error or {
                "type": "typed_parse_failure",
                "message": f"strict ChatAdapter route was not K11 or K47: {actual!r}",
            }
            actual = None
        output.append(
            {
                "source_id": row["id"],
                "expected": row["route"],
                "raw_response": calls[0]["raw_response"],
                "parsed_route": actual,
                "correct": actual == row["route"],
                "error": error,
                "rendered_messages": calls[0]["messages"],
                **evidence,
                "wall_seconds": time.monotonic() - started,
            }
        )
    return output


def aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    f1s = []
    for route in ("K11", "K47"):
        tp = sum(row["expected"] == route and row["parsed_route"] == route for row in rows)
        fp = sum(row["expected"] != route and row["parsed_route"] == route for row in rows)
        fn = sum(row["expected"] == route and row["parsed_route"] != route for row in rows)
        f1s.append(0.0 if 2 * tp + fp + fn == 0 else 2 * tp / (2 * tp + fp + fn))
    return {
        "accuracy": sum(row["correct"] for row in rows) / len(rows),
        "macro_f1": sum(f1s) / 2,
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


def seal(seed: int, arm: str, program: Any, selection_rows: list[dict[str, Any]], manifest: dict[str, Any],
         preheld_call_counts: dict[str, int]) -> dict[str, Any]:
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
        "preheld_call_counts": preheld_call_counts,
    }
    payload["payload_sha256"] = sha256_bytes(
        json.dumps(json_safe(payload), sort_keys=True, separators=(",", ":")).encode()
    )
    path = OUTPUT.parent / "sealed" / f"upstream-{seed}-{arm}.json"
    atomic_write(path, payload)
    return {"program": program, "artifact_path": str(path), "artifact_sha256": sha256_file(path), **payload}


def run(args: argparse.Namespace) -> None:
    global ACTIVE_CAPTURE
    manifest = load_manifest(args)
    if manifest.get("launch_status") != "sealed":
        raise RuntimeError(f"provider launch refused: {manifest.get('launch_status')}")
    commits = source_commits(manifest)
    verify_clean_imp_tree()
    catalog_snapshot = verify_models(manifest)
    dspy, RecordingLM = install_runtime(args)
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))
    capture = Capture(manifest)
    ACTIVE_CAPTURE = capture
    request = manifest["execution"]["request"]
    splits = manifest["dataset"]["splits"]
    train_rows = stream_rows(Path(manifest["dataset"]["train_path"]), splits["train_ids"])
    selection_source = stream_rows(
        Path(manifest["dataset"]["selection_path"]), splits["selection_ids"]
    )
    meanings = route_meanings(manifest)
    metric = semantic_metric(meanings)
    sealed = []

    for seed in manifest["seeds"]:
        for arm in manifest["arms"]:
            capture.register_budget(seed, arm, manifest["execution"]["call_ceilings"][arm])
            before_arm = len(capture.calls)
            task_lm = RecordingLM(
                manifest["models"]["task"]["upstream"], api_base="https://openrouter.ai/api/v1",
                api_key=os.environ["OPENROUTER_API_KEY"], cache=False, num_retries=0,
                capture=capture, role="task", seed=seed,
                expected_model=model_contract(manifest, "task"),
                max_tokens=request["task"]["max_tokens"],
                extra_body=openrouter_body(manifest, "task")
            )
            optimizer_lm = RecordingLM(
                manifest["models"]["optimizer"]["upstream"], api_base="https://openrouter.ai/api/v1",
                api_key=os.environ["OPENROUTER_API_KEY"], cache=False, num_retries=0,
                capture=capture, role="optimizer", temperature=request["optimizer"]["temperature"],
                expected_model=model_contract(manifest, "optimizer"),
                max_tokens=request["optimizer"]["max_tokens"],
                extra_body=openrouter_body(manifest, "optimizer")
            )
            program = build_program(dspy, task_lm)
            capture.set_phase(seed, arm, "compile")
            selected = compile_arm(
                dspy, arm, program, examples(dspy, train_rows, True),
                examples(dspy, selection_source, False), seed, task_lm, optimizer_lm, metric, manifest
            )
            capture.set_phase(seed, arm, "selection")
            selected_rows = evaluate(
                selected, selection_source, task_lm, capture, model_contract(manifest, "task")
            )
            preheld_call_counts = validate_call_slice(
                capture.calls[before_arm:], arm, manifest, reserved_held_out_task=80
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
            "selections": [{key: value for key, value in item.items() if key != "program"} for item in sealed],
        },
    )
    wait_for_peer_selection(manifest)
    held_out_path = Path(manifest["dataset"]["held_out_path"])
    if sha256_file(held_out_path) != manifest["dataset"]["held_out_sha256"]:
        raise RuntimeError("TREC held-out split drift")
    held_out = stream_rows(held_out_path, splits["held_out_ids"])
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
            "task_logical": 80,
            "optimizer_logical": 0,
            "total_logical": 80,
            "transports": 80,
        }
        if held_counts != expected_held:
            raise RuntimeError(
                f"{selected['arm']} held-out call accounting drift: "
                f"counts={held_counts!r} expected={expected_held!r}"
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

    by_seed = []
    for seed in manifest["seeds"]:
        by_seed.append({"seed": seed, "arms": [row for row in completed if row["seed"] == seed]})
    result = {
        "schema_version": 3,
        "runtime": "upstream",
        "status": "complete",
        "manifest_sha256": manifest["manifest_sha256"],
        "source_commits": commits,
        "selection_receipt": str(SELECTION_OUTPUT),
        "seeds": by_seed,
        "calls": capture.calls,
        "call_budgets": capture.call_budgets,
        "catalog_snapshot": catalog_snapshot,
        "claim_boundary": "sealed matched system comparison; task messages are matched exactly, optimizer trajectories use pinned fidelity modes",
    }
    atomic_write(OUTPUT, result)
    print(json.dumps(json_safe(result), indent=2, sort_keys=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args)
    except Exception as exc:
        try:
            manifest = json.loads(MANIFEST_PATH.read_text())
            commits = source_commits(manifest)
        except Exception:
            commits = {"imp": "unavailable", "dspy": "unavailable", "gepa": "unavailable"}
        atomic_write(
            OUTPUT,
            {"schema_version": 3, "runtime": "upstream", "status": "stopped",
             "source_commits": commits,
             "call_budgets": ACTIVE_CAPTURE.call_budgets if ACTIVE_CAPTURE else {},
             "error": repr(exc)},
        )
        raise


if __name__ == "__main__":
    main()
