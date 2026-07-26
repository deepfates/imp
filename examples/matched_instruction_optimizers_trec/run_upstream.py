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
    manifest["dataset"]["splits"] = json.loads(Path(dataset["contract_path"]).read_text())["splits"]
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


def verify_models(manifest: dict[str, Any]) -> None:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5) as response:
        catalog = json.load(response)["models"]
    for role in ("task", "optimizer"):
        expected = manifest["models"][role]
        name = expected["upstream"].removeprefix("ollama/")
        if not any(row.get("name") == name and row.get("digest") == expected["digest"] for row in catalog):
            raise RuntimeError(f"pinned local {role} model is absent or changed")


class Capture:
    def __init__(self) -> None:
        self.phase: dict[str, Any] | None = None
        self.calls: list[dict[str, Any]] = []

    def set_phase(self, seed: int, arm: str, phase: str) -> None:
        self.phase = {"seed": seed, "arm": arm, "phase": phase}


def install_runtime(args: argparse.Namespace):
    sys.path.insert(0, str(args.gepa_root / "src"))
    sys.path.insert(0, str(args.dspy_root))
    import dspy

    class RecordingLM(dspy.LM):
        def __init__(self, *lm_args, capture: Capture, role: str, **lm_kwargs):
            super().__init__(*lm_args, **lm_kwargs)
            self.capture = capture
            self.role = role

        def forward(self, prompt=None, messages=None, **kwargs):
            started = time.monotonic()
            response = super().forward(prompt=prompt, messages=messages, **kwargs)
            usage = field(response, "usage")
            choices = field(response, "choices") or []
            choice = choices[0] if choices else None
            message = field(choice, "message")
            hidden = getattr(response, "_hidden_params", {}) or {}
            self.capture.calls.append(
                {
                    "phase": copy.deepcopy(self.capture.phase),
                    "role": self.role,
                    "prompt": prompt,
                    "messages": copy.deepcopy(messages),
                    "raw_response": {
                        "response": json_safe(response),
                        "provider_metadata": json_safe(hidden),
                    },
                    "response_metadata": {
                        "model": field(response, "model"),
                        "provider": field(hidden, "custom_llm_provider"),
                        "input_tokens": field(usage, "prompt_tokens"),
                        "output_tokens": field(usage, "completion_tokens"),
                        "finish_reason": field(choice, "finish_reason"),
                        "content": field(message, "content"),
                        "provider_cost": field(hidden, "response_cost"),
                    },
                    # This is an observed dispatch through this exact adapter boundary.
                    "adapter_transport_dispatch": 1,
                    "wall_seconds": time.monotonic() - started,
                }
            )
            return response

    return dspy, RecordingLM


def transport_evidence(call: dict[str, Any], expected: dict[str, Any]) -> dict[str, Any]:
    response = call["response_metadata"]
    evidence = {
        "actual_model": response["model"],
        "actual_route": response["provider"],
        "transport_attempts": call["adapter_transport_dispatch"],
        "input_tokens": response["input_tokens"],
        "output_tokens": response["output_tokens"],
        "finish_reason": response["finish_reason"],
        "content": response["content"],
        "provider_cost": response["provider_cost"],
    }
    configured = expected["upstream"]
    local = configured.removeprefix("ollama/")
    model_ok = evidence["actual_model"] in (configured, local)
    route_ok = evidence["actual_route"] == "ollama"
    tokens_ok = isinstance(evidence["input_tokens"], (int, float)) and isinstance(
        evidence["output_tokens"], (int, float)
    )
    if not (
        model_ok
        and route_ok
        and evidence["transport_attempts"] == 1
        and tokens_ok
        and isinstance(evidence["finish_reason"], str)
        and isinstance(evidence["content"], str)
        and (evidence["provider_cost"] is None or evidence["provider_cost"] == 0)
    ):
        raise RuntimeError(f"missing or drifted upstream transport evidence: {evidence!r}")
    provider_cost = evidence.pop("provider_cost")
    evidence["cost"] = (
        {"value": provider_cost, "authority": "provider_reported"}
        if provider_cost is not None
        else {"value": None, "authority": "local_ollama_no_billing", "external_api_spend": 0}
    )
    return evidence


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
            num_candidates=mipro["instruction_candidates"],
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
            raise RuntimeError(f"{row['id']} failed strict route parsing: {actual!r}; error={error!r}")
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


def seal(seed: int, arm: str, program: Any, selection_rows: list[dict[str, Any]], manifest: dict[str, Any]) -> dict[str, Any]:
    payload = {
        "schema_version": 1,
        "runtime": "upstream",
        "seed": seed,
        "arm": arm,
        "manifest_sha256": manifest["manifest_sha256"],
        "source_commits": source_commits(manifest),
        "selection": aggregate(selection_rows),
        "selection_rows": selection_rows,
        "selected_parameters": parameter_snapshot(program),
    }
    payload["payload_sha256"] = sha256_bytes(
        json.dumps(json_safe(payload), sort_keys=True, separators=(",", ":")).encode()
    )
    path = OUTPUT.parent / "sealed" / f"upstream-{seed}-{arm}.json"
    atomic_write(path, payload)
    return {"program": program, "artifact_path": str(path), "artifact_sha256": sha256_file(path), **payload}


def run(args: argparse.Namespace) -> None:
    manifest = load_manifest(args)
    commits = source_commits(manifest)
    verify_clean_imp_tree()
    verify_models(manifest)
    dspy, RecordingLM = install_runtime(args)
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))
    capture = Capture()
    request = manifest["execution"]["request"]
    splits = manifest["dataset"]["splits"]
    train_rows = stream_rows(Path(manifest["dataset"]["train_path"]), splits["train_ids"])
    selection_source = stream_rows(
        Path(manifest["dataset"]["selection_path"]), splits["validation_ids"]
    )
    meanings = route_meanings(manifest)
    metric = semantic_metric(meanings)
    sealed = []

    for seed in manifest["seeds"]:
        for arm in manifest["arms"]:
            task_lm = RecordingLM(
                manifest["models"]["task"]["upstream"], api_base="http://127.0.0.1:11434",
                api_key="", cache=False, num_retries=0, capture=capture, role="task",
                temperature=request["task"]["temperature"], max_tokens=request["task"]["max_tokens"]
            )
            optimizer_lm = RecordingLM(
                manifest["models"]["optimizer"]["upstream"], api_base="http://127.0.0.1:11434",
                api_key="", cache=False, num_retries=0, capture=capture, role="optimizer",
                temperature=request["optimizer"]["temperature"], max_tokens=request["optimizer"]["max_tokens"]
            )
            program = build_program(dspy, task_lm)
            capture.set_phase(seed, arm, "compile")
            selected = compile_arm(
                dspy, arm, program, examples(dspy, train_rows, True),
                examples(dspy, selection_source, False), seed, task_lm, optimizer_lm, metric, manifest
            )
            capture.set_phase(seed, arm, "selection")
            selected_rows = evaluate(selected, selection_source, task_lm, capture, manifest["models"]["task"])
            sealed.append(seal(seed, arm, selected, selected_rows, manifest))

    # Durably record every selected artifact before the held-out loader exists.
    atomic_write(
        SELECTION_OUTPUT,
        {
            "schema_version": 1,
            "runtime": "upstream",
            "status": "selection_sealed",
            "held_out_loaded": False,
            "manifest_sha256": manifest["manifest_sha256"],
            "source_commits": commits,
            "selections": [{key: value for key, value in item.items() if key != "program"} for item in sealed],
        },
    )
    held_out_path = Path(manifest["dataset"]["held_out_path"])
    if sha256_file(held_out_path) != manifest["dataset"]["held_out_sha256"]:
        raise RuntimeError("TREC held-out split drift")
    held_out = stream_rows(held_out_path, splits["held_out_ids"])
    completed = []
    for selected in sealed:
        capture.set_phase(selected["seed"], selected["arm"], "held_out")
        rows = evaluate(selected["program"], held_out, None, capture, manifest["models"]["task"])
        public = {key: value for key, value in selected.items() if key != "program"}
        public["held_out"] = aggregate(rows)
        public["rows"] = {"selection": selected["selection_rows"], "held_out": rows}
        completed.append(public)

    by_seed = []
    for seed in manifest["seeds"]:
        by_seed.append({"seed": seed, "arms": [row for row in completed if row["seed"] == seed]})
    result = {
        "schema_version": 1,
        "runtime": "upstream",
        "status": "complete",
        "manifest_sha256": manifest["manifest_sha256"],
        "source_commits": commits,
        "selection_receipt": str(SELECTION_OUTPUT),
        "seeds": by_seed,
        "calls": capture.calls,
        "claim_boundary": "task/model-specific matched local evidence; not general parity or effectiveness",
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
            {"schema_version": 1, "runtime": "upstream", "status": "stopped",
             "source_commits": commits, "error": repr(exc)},
        )
        raise


if __name__ == "__main__":
    main()
