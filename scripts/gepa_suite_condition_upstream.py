#!/usr/bin/env python3
"""One matched current-model DSPy condition over the official GEPA suite.

This is deliberately a single-condition entrance, not a campaign runner.  It
authenticates the pinned source trees, opens train/selection first, runs one
declared arm, then opens held-out rows, persists the selected DSPy state, and
proves four calls from a fresh Python process.  Provider execution is disabled
unless ``--run`` is explicit.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dspy_gepa_version_bridge import (
    DSPY_COMMIT,
    GEPA_COMMIT,
    authenticate_loaded_runtime,
    install_source_bridge,
)


ARTIFACT_COMMIT = "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
FAMILIES = {
    "AIMEBench": "gepa_artifact.benchmarks.AIME",
    "HotpotQABench": "gepa_artifact.benchmarks.hotpotQA",
    "hoverBench": "gepa_artifact.benchmarks.hover",
    "IFBench": "gepa_artifact.benchmarks.IFBench",
    "LiveBenchMathBench": "gepa_artifact.benchmarks.livebench_math",
    "Papillon": "gepa_artifact.benchmarks.papillon",
}
ARMS = ("baseline", "mipro_v2_heavy", "gepa_v0_1_4_merge")
STUDY_SEEDS = (2026080101, 2026080102, 2026080103)
LIVEBENCH_MATH_BRIDGE = Path(__file__).resolve().with_name("livebench_math_score.py")
FAMILY_SHAPES = {
    "AIMEBench": {"task": 1, "judge": 0},
    "HotpotQABench": {"task": 4, "judge": 0},
    "hoverBench": {"task": 4, "judge": 0},
    "IFBench": {"task": 2, "judge": 0},
    "LiveBenchMathBench": {"task": 1, "judge": 0},
    "Papillon": {"task": 3, "judge": 3},
}
RUNTIME_EVENTS: list[dict[str, Any]] = []
RUNTIME_LOCK = threading.Lock()
PROGRESS_PATH: Path | None = None
ACTIVE_ARGS: argparse.Namespace | None = None
ACTIVE_STAGE = "preflight"
ACTIVE_PREFLIGHT: dict[str, Any] | None = None
RUN_STARTED_NS: int | None = None
SPEND_GUARD = None


class OperationalSafetyAbort(BaseException):
    """Fatal pretransport budget/input/route safety refusal; never a task score."""


class ProspectiveSpendGuard:
    """One shared hard cap over concurrent requests using actual cost when known."""

    def __init__(self, initial_cost_usd: float, owner_cap_usd: float):
        if not isinstance(initial_cost_usd, (int, float)) or initial_cost_usd < 0:
            raise OperationalSafetyAbort("live execution requires nonnegative --initial-cost-usd")
        if not isinstance(owner_cap_usd, (int, float)) or owner_cap_usd <= 0:
            raise OperationalSafetyAbort("live execution requires positive --max-cost-usd")
        if initial_cost_usd > owner_cap_usd + 1e-9:
            raise OperationalSafetyAbort("initial actual spend already exceeds the owner cap")
        self.initial_actual = float(initial_cost_usd)
        self.accounted = 0.0
        self.retained = 0.0
        self.active: dict[int, float] = {}
        self.owner_cap = float(owner_cap_usd)
        self.next_id = 1
        self.lock = threading.Lock()

    def reserve(self, role: str, reservation: float) -> int:
        with self.lock:
            projected = self.initial_actual + self.accounted + self.retained + sum(self.active.values()) + reservation
            if projected > self.owner_cap + 1e-9:
                raise OperationalSafetyAbort(
                    f"next {role} transport would exceed the owner cap: "
                    f"${projected} > ${self.owner_cap}"
                )
            identity = self.next_id
            self.next_id += 1
            self.active[identity] = reservation
            return identity

    def settle(self, identity: int, actual_cost: float) -> None:
        if not isinstance(actual_cost, (int, float)) or actual_cost < 0:
            self.retain(identity)
            raise OperationalSafetyAbort("provider response did not retain an authenticated nonnegative cost")
        with self.lock:
            if self.active.pop(identity, None) is not None:
                self.accounted += float(actual_cost)

    def retain(self, identity: int) -> None:
        with self.lock:
            reservation = self.active.pop(identity, None)
            if reservation is not None:
                self.retained += reservation

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            active = sum(self.active.values())
            return {
                "initial_actual_cost_usd": self.initial_actual,
                "reconciled_accounted_cost_usd": self.accounted,
                "retained_reservation_usd": self.retained,
                "active_reservation_usd": active,
                "active_requests": len(self.active),
                "owner_cap_usd": self.owner_cap,
                "accounted_total_usd": self.initial_actual + self.accounted + self.retained + active,
            }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--retrieval-root", type=Path)
    parser.add_argument("--retrieval-receipt", type=Path)
    parser.add_argument("--family", choices=tuple(FAMILIES), required=True)
    parser.add_argument("--arm", choices=ARMS, default="baseline")
    parser.add_argument("--seed", type=int, default=2026080101)
    parser.add_argument("--task-model")
    parser.add_argument("--reflection-model")
    parser.add_argument("--judge-model")
    parser.add_argument("--task-provider")
    parser.add_argument("--reflection-provider")
    parser.add_argument("--judge-provider")
    parser.add_argument("--task-max-input-bytes", type=int)
    parser.add_argument("--reflection-max-input-bytes", type=int)
    parser.add_argument("--judge-max-input-bytes", type=int)
    parser.add_argument("--task-max-output-tokens", type=int)
    parser.add_argument("--reflection-max-output-tokens", type=int)
    parser.add_argument("--judge-max-output-tokens", type=int)
    parser.add_argument("--input-price-per-million", type=float)
    parser.add_argument("--output-price-per-million", type=float)
    for role in ("task", "reflection", "judge"):
        parser.add_argument(f"--{role}-input-price-per-million", type=float)
        parser.add_argument(f"--{role}-output-price-per-million", type=float)
    parser.add_argument("--max-concurrency", type=int, default=1)
    parser.add_argument("--initial-cost-usd", type=float)
    parser.add_argument("--max-cost-usd", type=float)
    parser.add_argument("--api-base", default="https://openrouter.ai/api/v1")
    parser.add_argument("--api-key-env", default="OPENROUTER_API_KEY")
    parser.add_argument("--livebench-math-python", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--fresh", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args()


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def authenticate_clean_tree(root: Path, commit: str, label: str) -> None:
    if git(root, "rev-parse", "HEAD") != commit:
        raise RuntimeError(f"{label} source commit drift")
    if subprocess.run(["git", "-C", str(root), "diff", "--quiet"]).returncode != 0:
        raise RuntimeError(f"{label} tracked source is dirty")
    if subprocess.run(["git", "-C", str(root), "diff", "--cached", "--quiet"]).returncode != 0:
        raise RuntimeError(f"{label} staged source is dirty")


def tree_identity(root: Path) -> dict[str, Any]:
    return {
        "commit": git(root, "rev-parse", "HEAD"),
        "tracked_clean":
            subprocess.run(["git", "-C", str(root), "diff", "--quiet"]).returncode == 0
            and subprocess.run(["git", "-C", str(root), "diff", "--cached", "--quiet"]).returncode == 0,
    }


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def configure_livebench_metric(args: argparse.Namespace) -> dict[str, Any] | None:
    if args.family != "LiveBenchMathBench" or (not args.run and not args.fresh):
        return None
    if args.livebench_math_python is None:
        raise RuntimeError(
            "LiveBenchMathBench live execution requires --livebench-math-python"
        )
    # Preserve the virtual-environment entry path. Resolving its symlink would
    # invoke the base interpreter and silently drop the scorer dependencies.
    python = Path(os.path.abspath(args.livebench_math_python))
    payload = {
        "task": "amps_hard",
        "ground_truth": "x^2",
        "answer": "\\boxed{x^2}",
    }
    completed = subprocess.run(
        [str(python), str(LIVEBENCH_MATH_BRIDGE)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "LiveBenchMath symbolic scorer preflight failed: "
            + (completed.stdout or completed.stderr).strip()
        )
    result = json.loads(completed.stdout)
    if result.get("score") not in (1, 1.0):
        raise RuntimeError("LiveBenchMath symbolic scorer preflight returned an invalid result")
    args.livebench_math_python = python
    return {
        "preflight": "exact_symbolic_identity_score_passed_before_transport",
        "symbolic_bridge_python": str(python),
        "symbolic_bridge_python_sha256": sha256(python),
        "symbolic_bridge_path": str(LIVEBENCH_MATH_BRIDGE),
        "symbolic_bridge_sha256": sha256(LIVEBENCH_MATH_BRIDGE),
    }


def specs(dataset_root: Path) -> dict[str, dict[str, Any]]:
    payload = json.loads((dataset_root / "families.json").read_text())
    return {item["family"]: item for item in payload["families"]}


def split_path(dataset_root: Path, family: str, split: str) -> Path:
    return dataset_root / family / f"{split}.jsonl"


def verify_split(dataset_root: Path, spec: dict[str, Any], split: str) -> Path:
    path = split_path(dataset_root, spec["family"], split)
    expected = (spec.get("checksums") or spec["split_checksums"])[split].removeprefix("sha256:")
    if sha256(path) != expected:
        raise RuntimeError(f"{spec['family']} {split} digest drift")
    count = sum(1 for line in path.open() if line.strip())
    if count != spec["split_counts"][split]:
        raise RuntimeError(f"{spec['family']} {split} count drift")
    return path


def load_rows(dspy: Any, path: Path, input_keys: list[str]) -> list[Any]:
    rows = []
    with path.open() as handle:
        for line in handle:
            if line.strip():
                rows.append(dspy.Example(**json.loads(line)).with_inputs(*input_keys))
    return rows


def load_verified_rows(
    dspy: Any, path: Path, spec: dict[str, Any], split: str
) -> list[Any]:
    content = path.read_bytes()
    expected_sha = (spec.get("checksums") or spec["split_checksums"])[split].removeprefix("sha256:")
    actual_sha = hashlib.sha256(content).hexdigest()
    if actual_sha != expected_sha:
        raise RuntimeError(f"{spec['family']} {split} digest drift at decode barrier")
    records = [json.loads(line) for line in content.decode("utf-8").splitlines() if line.strip()]
    if len(records) != spec["split_counts"][split]:
        raise RuntimeError(f"{spec['family']} {split} count drift at decode barrier")
    return [dspy.Example(**record).with_inputs(*spec["input_keys"]) for record in records]


def install_retrieval(retrieval_root: Path | None, receipt_path: Path | None, spec: dict[str, Any]) -> dict[str, Any] | None:
    if "retrieval" not in spec:
        return None
    if retrieval_root is None or receipt_path is None:
        raise RuntimeError(f"{spec['family']} requires --retrieval-root and --retrieval-receipt")

    retrieval = spec["retrieval"]
    receipt = json.loads(receipt_path.read_text())
    authenticated = receipt["retrieval"]
    corpus_path = retrieval_root / retrieval["corpus_path"]
    index_path = retrieval_root / retrieval["index_path"]
    corpus_sha = authenticated["extraction"]["corpus_sha256"]
    index_expected = authenticated["build"]["actual_tree_sha256"]
    if sha256(corpus_path) != corpus_sha:
        raise RuntimeError("retrieval corpus digest drift")
    # Directory identity is the canonical sorted path/content digest used by Imp.
    digest = hashlib.sha256()
    for path in sorted(p for p in index_path.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(index_path)).replace("\\", "/").encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    index_sha = digest.hexdigest()
    if index_sha != index_expected:
        raise RuntimeError("retrieval index digest drift")

    hover = importlib.import_module("gepa_artifact.benchmarks.hover.hover_program")
    import bm25s
    import Stemmer

    hover.retriever = bm25s.BM25.load(str(index_path))
    hover.stemmer = Stemmer.Stemmer("english")
    hover.corpus = [
        f"{item['title']} | {' '.join(item['text'])}"
        for item in (json.loads(line) for line in corpus_path.open())
    ]
    hover.initialized = True
    return {
        "corpus_sha256": corpus_sha,
        "index_tree_sha256": index_sha,
        "historical_unretained_index_sha256": retrieval["index_checksum"].removeprefix("sha256:"),
        "classification": "authenticated_current_build_of_official_retrieval_not_historical_byte_reproduction",
    }


def livebench_symbolic_score(
    args: argparse.Namespace, meta: Any, gold: Any, pred: Any
) -> tuple[float, str | None]:
    question = gold["question_d"]
    if question.get("task") != "AMPS_Hard":
        score = meta.metric(gold, pred, None)
        if hasattr(score, "score"):
            score = score.score
        return float(score), None

    payload = {
        "task": "amps_hard",
        "ground_truth": str(question.get("ground_truth", "")),
        "answer": str(pred.answer),
    }
    completed = subprocess.run(
        [str(args.livebench_math_python), str(LIVEBENCH_MATH_BRIDGE)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "LiveBenchMath symbolic scorer failed: "
            + (completed.stdout or completed.stderr).strip()
        )
    result = json.loads(completed.stdout)
    return float(result["score"]), result.get("parsed_answer")


def source_metric(meta: Any, args: argparse.Namespace):
    if args.family != "LiveBenchMathBench":
        return meta.metric

    def metric(gold, pred, trace=None):
        score, _parsed = livebench_symbolic_score(args, meta, gold, pred)
        return score

    return metric


def gepa_metric(dspy: Any, meta: Any, args: argparse.Namespace):
    feedback_map = (meta.feedback_fn_maps or [{}])[0]

    def lookup(name: str):
        return feedback_map.get(name) or feedback_map.get(f"{name}.predict")

    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        overall = source_metric(meta, args)(gold, pred, trace)
        if hasattr(overall, "score"):
            overall = overall.score
        if pred_name is not None and pred_trace and lookup(pred_name):
            _predictor, inputs, outputs = pred_trace[0]
            detail = lookup(pred_name)(
                predictor_output=outputs,
                predictor_inputs=inputs,
                module_inputs=gold,
                module_outputs=pred,
                captured_trace=trace,
            )
            return dspy.Prediction(score=overall, feedback=detail["feedback_text"])
        if args.family == "LiveBenchMathBench" and gold["question_d"].get("task") == "AMPS_Hard":
            _score, parsed = livebench_symbolic_score(args, meta, gold, pred)
            result = dspy.Prediction(
                score=overall,
                feedback=(
                    f"The symbolic scorer parsed {parsed!r}; the answer scored {overall}."
                ),
            )
        else:
            result = meta.metric_with_feedback(gold, pred, trace)
        if hasattr(result, "feedback"):
            return dspy.Prediction(score=overall, feedback=result.feedback)
        return dspy.Prediction(score=overall, feedback=f"This trajectory scored {overall}.")

    return metric


def rendered_message_bytes(value: Any) -> int:
    """Match ReqLLM's nested payload-string envelope; role labels are structural."""
    if isinstance(value, str):
        return len(value.encode("utf-8"))
    if isinstance(value, dict):
        return sum(
            rendered_message_bytes(item)
            for key, item in value.items()
            if key != "role"
        )
    if isinstance(value, (list, tuple)):
        return sum(rendered_message_bytes(item) for item in value)
    return 0


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def value_field(value: Any, name: str, default=None):
    if isinstance(value, dict):
        return value.get(name, default)
    return getattr(value, name, default)


def response_usage(response: Any) -> dict[str, Any]:
    usage = value_field(response, "usage")
    input_tokens = value_field(usage, "prompt_tokens")
    output_tokens = value_field(usage, "completion_tokens")
    cost = value_field(usage, "cost")
    if cost is None:
        cost = value_field(value_field(response, "_hidden_params", {}), "response_cost")
    if not isinstance(input_tokens, int) or input_tokens < 0:
        raise RuntimeError("provider response is missing prompt-token usage")
    if not isinstance(output_tokens, int) or output_tokens < 0:
        raise RuntimeError("provider response is missing completion-token usage")
    if not isinstance(cost, (int, float)) or cost < 0:
        raise RuntimeError("provider response is missing nonnegative cost usage")
    return {"input_tokens": input_tokens, "output_tokens": output_tokens, "cost_usd": cost}


def record_runtime_response(role: str, messages: Any, started_ns: int, response: Any) -> None:
    choice = (value_field(response, "choices", []) or [None])[0]
    append_runtime_event(
        {
            "role": role,
            "status": "ok",
            "message_bytes": rendered_message_bytes(messages),
            "latency_us": (time.monotonic_ns() - started_ns) // 1_000,
            "response_id": value_field(response, "id"),
            "response_model": value_field(response, "model"),
            "finish_reason": value_field(choice, "finish_reason"),
            "usage": response_usage(response),
        }
    )


def record_runtime_error(role: str, messages: Any, started_ns: int, error: BaseException) -> None:
    append_runtime_event(
        {
            "role": role,
            "status": "error",
            "message_bytes": rendered_message_bytes(messages),
            "latency_us": (time.monotonic_ns() - started_ns) // 1_000,
            "error_type": type(error).__name__,
        }
    )


def append_runtime_event(event: dict[str, Any]) -> None:
    with RUNTIME_LOCK:
        event = {**event, "sequence": len(RUNTIME_EVENTS) + 1}
        RUNTIME_EVENTS.append(event)
        if PROGRESS_PATH is not None:
            with PROGRESS_PATH.open("a") as handle:
                handle.write(json.dumps(event, sort_keys=True, default=str) + "\n")


def init_progress(args: argparse.Namespace) -> Path:
    global PROGRESS_PATH
    if args.output is None:
        raise RuntimeError("live progress requires --output")
    PROGRESS_PATH = args.output.with_suffix(args.output.suffix + ".progress.jsonl")
    PROGRESS_PATH.parent.mkdir(parents=True, exist_ok=True)
    PROGRESS_PATH.parent.chmod(0o700)
    header = {
        "event": "start",
        "family": args.family,
        "arm": args.arm,
        "seed": args.seed,
        "max_concurrency": args.max_concurrency,
    }
    with PROGRESS_PATH.open("x") as handle:
        handle.write(json.dumps(header, sort_keys=True) + "\n")
    PROGRESS_PATH.chmod(0o600)
    return PROGRESS_PATH


def save_state_exclusive(program: Any, state_path: Path) -> None:
    temporary_state = state_path.with_name(
        state_path.name + f".tmp-{os.getpid()}-{time.monotonic_ns()}"
    )
    try:
        program.save(temporary_state, save_program=False)
        temporary_state.chmod(0o600)
        os.link(temporary_state, state_path)
    finally:
        temporary_state.unlink(missing_ok=True)


def runtime_usage() -> dict[str, Any]:
    with RUNTIME_LOCK:
        runtime_events = [dict(event) for event in RUNTIME_EVENTS]
    by_role = {}
    for role in ("task", "reflection", "judge"):
        events = [event for event in runtime_events if event["role"] == role]
        successful = [event for event in events if event["status"] == "ok"]
        by_role[role] = {
            "request_attempts": len(events),
            "usage_events": len(successful),
            "error_count": len(events) - len(successful),
            "request_duration_us": sum(event["latency_us"] for event in events),
            "input_tokens": sum(event["usage"]["input_tokens"] for event in successful),
            "output_tokens": sum(event["usage"]["output_tokens"] for event in successful),
            "cost_usd": sum(event["usage"]["cost_usd"] for event in successful),
        }
    return {"summary": by_role, "events": runtime_events}


def merge_runtime_usage(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    summary = {
        role: {
            key: left.get("summary", {}).get(role, {}).get(key, 0)
            + right.get("summary", {}).get(role, {}).get(key, 0)
            for key in (
                "request_attempts",
                "usage_events",
                "error_count",
                "request_duration_us",
                "input_tokens",
                "output_tokens",
                "cost_usd",
            )
        }
        for role in ("task", "reflection", "judge")
    }
    events = [*left.get("events", []), *right.get("events", [])]
    return {
        "summary": summary,
        "events": [{**event, "sequence": index} for index, event in enumerate(events, 1)],
    }


def make_lm(dspy: Any, role: str, args: argparse.Namespace):
    model = getattr(args, f"{role}_model")
    provider = getattr(args, f"{role}_provider")
    max_input_bytes = getattr(args, f"{role}_max_input_bytes")
    max_output_tokens = getattr(args, f"{role}_max_output_tokens")
    if not model:
        raise RuntimeError("live execution requires every declared model role")
    if not provider:
        raise RuntimeError("live execution requires every declared provider endpoint")
    if not isinstance(max_input_bytes, int) or max_input_bytes <= 0:
        raise RuntimeError("live execution requires every positive input byte envelope")
    if not isinstance(max_output_tokens, int) or max_output_tokens <= 0:
        raise RuntimeError("live execution requires every positive output token envelope")
    input_price = role_price(args, role, "input")
    output_price = role_price(args, role, "output")
    if not isinstance(input_price, (int, float)) or input_price < 0:
        raise RuntimeError("live execution requires a nonnegative input price")
    if not isinstance(output_price, (int, float)) or output_price < 0:
        raise RuntimeError("live execution requires a nonnegative output price")
    import os

    reservation = (
        max_input_bytes * input_price
        + max_output_tokens * output_price
    ) / 1_000_000

    class InputBoundLM(dspy.LM):
        def _admit(self, prompt, messages):
            rendered = messages or [{"role": "user", "content": prompt}]
            actual = rendered_message_bytes(rendered)
            if actual > max_input_bytes:
                raise OperationalSafetyAbort(
                    f"{role} input envelope exceeded before transport: "
                    f"{actual} > {max_input_bytes} UTF-8 content bytes"
                )

        def forward(self, prompt=None, messages=None, **kwargs):
            self._admit(prompt, messages)
            rendered = messages or [{"role": "user", "content": prompt}]
            reservation_id = SPEND_GUARD.reserve(role, reservation)
            started = time.monotonic_ns()
            try:
                response = super().forward(prompt=prompt, messages=messages, **kwargs)
                usage = response_usage(response)
                conservative = (
                    usage["input_tokens"] * input_price
                    + usage["output_tokens"] * output_price
                ) / 1_000_000
                SPEND_GUARD.settle(reservation_id, max(usage["cost_usd"], conservative))
                record_runtime_response(role, rendered, started, response)
                return response
            except BaseException as error:
                SPEND_GUARD.retain(reservation_id)
                record_runtime_error(role, rendered, started, error)
                raise

        async def aforward(self, prompt=None, messages=None, **kwargs):
            self._admit(prompt, messages)
            rendered = messages or [{"role": "user", "content": prompt}]
            reservation_id = SPEND_GUARD.reserve(role, reservation)
            started = time.monotonic_ns()
            try:
                response = await super().aforward(prompt=prompt, messages=messages, **kwargs)
                usage = response_usage(response)
                conservative = (
                    usage["input_tokens"] * input_price
                    + usage["output_tokens"] * output_price
                ) / 1_000_000
                SPEND_GUARD.settle(reservation_id, max(usage["cost_usd"], conservative))
                record_runtime_response(role, rendered, started, response)
                return response
            except BaseException as error:
                SPEND_GUARD.retain(reservation_id)
                record_runtime_error(role, rendered, started, error)
                raise

    return InputBoundLM(
        model="openrouter/" + model,
        api_base=args.api_base,
        api_key=os.environ[args.api_key_env],
        temperature=1.0,
        cache=False,
        num_retries=0,
        timeout=120,
        max_tokens=max_output_tokens,
        extra_body={
            "provider": {
                "only": [provider],
                "order": [provider],
                "allow_fallbacks": False,
                "require_parameters": True,
                "data_collection": "deny",
                "zdr": True,
                "max_price": {
                    "prompt": input_price,
                    "completion": output_price,
                },
            },
            "usage": {"include": True},
        },
        extra_headers={
            "X-OpenRouter-Metadata": "enabled",
            "X-OpenRouter-Cache": "false",
        },
    )


def role_price(args: argparse.Namespace, role: str, direction: str) -> float | None:
    value = getattr(args, f"{role}_{direction}_price_per_million", None)
    if value is not None:
        return value
    return getattr(args, f"{direction}_price_per_million", None)


def spend_admission(args: argparse.Namespace) -> dict[str, Any]:
    if not isinstance(args.initial_cost_usd, (int, float)) or args.initial_cost_usd < 0:
        raise RuntimeError("live baseline requires nonnegative --initial-cost-usd")
    if not isinstance(args.max_cost_usd, (int, float)) or args.max_cost_usd <= 0:
        raise RuntimeError("live baseline requires positive --max-cost-usd")
    return {
        "initial_cost_usd": args.initial_cost_usd,
        "owner_cap_usd": args.max_cost_usd,
        "accounting": (
            "before each transport: initial actual spend plus the greater of provider-reported "
            "or conservative full-price token cost for completed calls, active/unreconciled "
            "reservations, and this request's full envelope reservation must remain within "
            "the owner cap; no cache discount"
        ),
    }


def configure_program(program: Any, task_lm: Any, judge_lm: Any, family: str) -> None:
    program.set_lm(task_lm)
    if family == "Papillon":
        program.untrusted_model = task_lm
        utils = importlib.import_module("gepa_artifact.benchmarks.papillon.papillon_utils")
        utils.llm_judge.set_lm(judge_lm)


def evaluate(
    dspy: Any,
    program: Any,
    rows: list[Any],
    metric: Any,
    max_concurrency: int,
) -> dict[str, Any]:
    failures: dict[str, list[str]] = {}

    class ObservedProgram:
        def __call__(self, **kwargs):
            identity = hashlib.sha256(canonical_bytes(kwargs)).hexdigest()
            try:
                return program(**kwargs)
            except BaseException as error:
                failures.setdefault(identity, []).append(type(error).__name__)
                raise

    result = dspy.Evaluate(
        devset=rows,
        metric=metric,
        num_threads=max_concurrency,
        return_all_scores=True,
        failure_score=0.0,
        max_errors=10_000,
    )(ObservedProgram())
    output_rows = []
    for index, (example, _prediction, score) in enumerate(result.results):
        inputs = example.inputs().toDict()
        identity = hashlib.sha256(canonical_bytes(inputs)).hexdigest()
        errors = failures.get(identity, [])
        output_rows.append(
            {
                "index": index,
                "input_sha256": identity,
                "score": float(score),
                "error": errors.pop(0) if errors else None,
            }
        )
    scores = [row["score"] for row in output_rows]
    return {
        "mean": sum(scores) / len(scores),
        "count": len(scores),
        "error_count": sum(row["error"] is not None for row in output_rows),
        "rows": output_rows,
    }


def optimize(dspy: Any, program: Any, meta: Any, train: list[Any], dev: list[Any], args: argparse.Namespace, task_lm: Any, reflection_lm: Any, metric_calls: int):
    if args.arm == "baseline":
        return program
    if args.arm == "mipro_v2_heavy":
        optimizer = dspy.MIPROv2(
            metric=source_metric(meta, args),
            prompt_model=reflection_lm,
            task_model=task_lm,
            auto="heavy",
            num_threads=args.max_concurrency,
            max_errors=10_000,
            seed=args.seed,
            track_stats=True,
        )
        return optimizer.compile(program, trainset=train, valset=dev, requires_permission_to_run=False)
    optimizer = dspy.GEPA(
        metric=gepa_metric(dspy, meta, args),
        max_metric_calls=metric_calls,
        reflection_minibatch_size=3,
        reflection_lm=reflection_lm,
        component_selector="round_robin",
        use_merge=True,
        num_threads=args.max_concurrency,
        failure_score=0.0,
        track_stats=True,
        seed=args.seed,
        gepa_kwargs={"acceptance_criterion": "strict_improvement"},
    )
    return optimizer.compile(program, trainset=train, valset=dev)


def predictor_state(program: Any) -> dict[str, str]:
    return {name: predictor.signature.instructions for name, predictor in program.named_predictors()}


def arm_program(arm: str, baseline: Any, selected: Any) -> Any:
    return baseline if arm == "baseline" else selected


def arm_requires_fresh_state(arm: str) -> bool:
    return arm != "baseline"


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}-{time.monotonic_ns()}")
    try:
        with temporary.open("x") as handle:
            temporary.chmod(0o600)
            handle.write(json.dumps(payload, sort_keys=True, default=str) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as error:
            raise RuntimeError(f"refusing to overwrite existing evidence: {path}") from error
    finally:
        temporary.unlink(missing_ok=True)


def ensure_new_targets(args: argparse.Namespace) -> None:
    if args.output is None:
        raise RuntimeError("live execution requires --output")
    targets = [args.output, args.output.with_suffix(args.output.suffix + ".progress.jsonl")]
    if not args.fresh and args.arm != "baseline":
        targets += [args.output.with_suffix(".state.json"), args.output.with_suffix(".fresh.json")]
        targets += [args.output.with_suffix(".fresh.json.progress.jsonl")]
    for path in targets:
        if path.exists():
            raise RuntimeError(f"refusing to overwrite existing evidence: {path}")


def condition_receipt(args: argparse.Namespace, imp_identity: dict[str, Any]) -> dict[str, Any]:
    return {
        "study": "matched-current-model-gepa-suite-v1",
        "protocol": "adapted_current_model_reference_differential",
        "source_commit": imp_identity["commit"],
        "source_tracked_clean": imp_identity["tracked_clean"],
        "family": args.family,
        "arm": args.arm,
        "seed": args.seed,
        "temperature": 1.0,
        "max_concurrency": args.max_concurrency,
        "request_timeout_ms": 120_000,
        "cache": False,
        "retries": 0,
        "fallback": False,
        "route": {
            "api_base": args.api_base,
            "require_parameters": True,
            "data_collection": "deny",
            "zdr": True,
            "response_cache": False,
            "usage_required": True,
        },
        "papillon_judge_treatment":
            (
                "source_scoring_procedure_with_matched_current_model_judge_not_historical_judge_reproduction"
                if args.family == "Papillon"
                else "not_applicable"
            ),
        "roles": {
            role: {
                "model": getattr(args, f"{role}_model"),
                "provider": getattr(args, f"{role}_provider"),
                "max_input_content_bytes": getattr(args, f"{role}_max_input_bytes"),
                "max_output_tokens": getattr(args, f"{role}_max_output_tokens"),
                "prices_per_million": {
                    "input": role_price(args, role, "input"),
                    "output": role_price(args, role, "output"),
                },
            }
            for role in ("task", "reflection", "judge")
        },
        "legacy_shared_prices_per_million": (
            {"input": args.input_price_per_million, "output": args.output_price_per_million}
            if args.input_price_per_million is not None and args.output_price_per_million is not None
            else None
        ),
    }


def data_receipt(spec: dict[str, Any]) -> dict[str, Any]:
    return {
        "source": spec.get("source") or spec.get("dataset_source") or spec.get("source_commit"),
        "split_counts": spec["split_counts"],
        "split_checksums": spec.get("split_checksums") or spec.get("checksums"),
    }


def main() -> None:
    global ACTIVE_ARGS, ACTIVE_STAGE, ACTIVE_PREFLIGHT, RUN_STARTED_NS, SPEND_GUARD
    args = parse_args()
    imp_identity = tree_identity(Path(__file__).resolve().parent.parent)
    if args.max_concurrency <= 0:
        raise RuntimeError("--max-concurrency must be a positive integer")
    if args.seed not in STUDY_SEEDS:
        raise RuntimeError(f"seed must be one of the frozen study seeds: {STUDY_SEEDS}")
    ACTIVE_ARGS = args
    RUN_STARTED_NS = time.monotonic_ns()
    for name in ("dspy_root", "gepa_root", "artifact_root", "dataset_root", "retrieval_root", "retrieval_receipt", "output", "state"):
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, value.resolve())
    # NLTK intentionally rejects imports from beneath the process CWD.  The
    # authenticated source roots are absolute, so keep the research checkout
    # out of that ambient import boundary.
    os.chdir(tempfile.gettempdir())
    authenticate_clean_tree(args.dspy_root, DSPY_COMMIT, "DSPy")
    authenticate_clean_tree(args.gepa_root, GEPA_COMMIT, "GEPA")
    authenticate_clean_tree(args.artifact_root, ARTIFACT_COMMIT, "GEPA artifact")
    bridge = install_source_bridge(args.dspy_root, args.gepa_root)
    import dspy
    import gepa

    runtime = authenticate_loaded_runtime(bridge, dspy, gepa)
    sys.path.insert(0, str(args.artifact_root))
    spec = specs(args.dataset_root)[args.family]
    train_path = verify_split(args.dataset_root, spec, "train")
    dev_path = verify_split(args.dataset_root, spec, "dev")
    test_path = verify_split(args.dataset_root, spec, "test")  # digest/count only; no JSON decode
    if args.family == "IFBench" and importlib.util.find_spec("en_core_web_sm") is None:
        raise RuntimeError("IFBench requires a preinstalled en_core_web_sm model; preflight will not download dependencies")
    if args.family == "IFBench":
        import spacy.cli

        # The pinned artifact calls spacy.cli.download unconditionally at
        # import time.  Require the dependency above and turn that installer
        # side effect into a no-op; task/scorer code remains byte-authenticated.
        spacy.cli.download = lambda _name: None
    module = importlib.import_module(FAMILIES[args.family])
    meta = module.benchmark[0]
    retrieval = install_retrieval(args.retrieval_root, args.retrieval_receipt, spec)
    metric_runtime = configure_livebench_metric(args)

    preflight = {
        "status": "provider_disabled_ready" if not args.run and not args.fresh else "running",
        "family": args.family,
        "arm": args.arm,
        "seed": args.seed,
        "outer_max_concurrency": args.max_concurrency,
        "splits": spec["split_counts"],
        "metric_calls": spec["metric_calls"],
        "runtime": {"bridge": bridge.as_dict(), "gepa": runtime},
        "heldout_decoded": False,
        "retrieval": retrieval,
        "input_envelope_semantics": "nested_utf8_string_content_bytes_not_full_wire_bytes",
        "metric_runtime": metric_runtime,
        "treatments": {
            "mipro_v2_heavy": {"max_concurrency": args.max_concurrency},
            "gepa_v0_1_4_merge": {"max_concurrency": args.max_concurrency},
        },
        "condition": condition_receipt(args, imp_identity),
        "data": data_receipt(spec),
    }
    ACTIVE_PREFLIGHT = preflight
    if not args.run and not args.fresh:
        print(json.dumps(preflight, sort_keys=True))
        return

    ensure_new_targets(args)
    admission = spend_admission(args)
    SPEND_GUARD = ProspectiveSpendGuard(args.initial_cost_usd, args.max_cost_usd)
    progress_path = init_progress(args)

    task_lm = make_lm(dspy, "task", args)
    reflection_lm = make_lm(dspy, "reflection", args)
    judge_lm = make_lm(dspy, "judge", args)
    program = copy.deepcopy(meta.program[0])
    configure_program(program, task_lm, judge_lm, args.family)

    if args.fresh:
        if args.state is None:
            raise RuntimeError("fresh mode requires --state")
        ACTIVE_STAGE = "fresh_load_and_service"
        loaded_state_sha256 = sha256(args.state)
        program.load(args.state)
        test = load_verified_rows(dspy, test_path, spec, "test")
        calls = []
        started = time.monotonic_ns()
        with dspy.context(lm=task_lm):
            for row in test[:4]:
                prediction = program(**row.inputs())
                calls.append(dict(prediction))
        payload = {
            **preflight,
            "status": "fresh_ok",
            "calls": calls,
            "heldout_decoded": True,
            "usage": runtime_usage(),
            "spend_admission": {**admission, "final": SPEND_GUARD.snapshot()},
            "progress_sha256": sha256(progress_path),
            "wall_time_us": (time.monotonic_ns() - started) // 1_000,
            "loaded_state_sha256": loaded_state_sha256,
        }
        if args.output:
            write_private_json(args.output, payload)
        else:
            print(json.dumps(payload, sort_keys=True, default=str))
        return

    if args.output is None:
        raise RuntimeError("live run requires --output")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.parent.chmod(0o700)
    state_path = args.output.with_suffix(".state.json")
    fresh_path = args.output.with_suffix(".fresh.json")
    train = load_rows(dspy, train_path, spec["input_keys"])
    dev = load_rows(dspy, dev_path, spec["input_keys"])
    started = time.monotonic_ns()
    ACTIVE_STAGE = "optimize"
    with dspy.context(lm=task_lm):
        selected = optimize(dspy, program, meta, train, dev, args, task_lm, reflection_lm, spec["metric_calls"])
        ACTIVE_STAGE = "heldout"
        test = load_verified_rows(dspy, test_path, spec, "test")
        heldout_result = evaluate(
            dspy,
            arm_program(args.arm, program, selected),
            test,
            source_metric(meta, args),
            args.max_concurrency,
        )

    state_sha = None
    fresh_sha = None
    fresh_usage = {}
    fresh_spend = None
    if arm_requires_fresh_state(args.arm):
        ACTIVE_STAGE = "persist_and_fresh_service"
        save_state_exclusive(selected, state_path)

        child_args = [
            sys.executable, "-P", str(Path(__file__).resolve()), "--fresh", "--run",
            "--dspy-root", str(args.dspy_root), "--gepa-root", str(args.gepa_root),
            "--artifact-root", str(args.artifact_root), "--dataset-root", str(args.dataset_root),
            "--family", args.family, "--arm", args.arm, "--seed", str(args.seed),
            "--task-model", args.task_model, "--reflection-model", args.reflection_model,
            "--judge-model", args.judge_model, "--task-provider", args.task_provider,
            "--reflection-provider", args.reflection_provider, "--judge-provider", args.judge_provider,
            "--task-max-input-bytes", str(args.task_max_input_bytes),
            "--reflection-max-input-bytes", str(args.reflection_max_input_bytes),
            "--judge-max-input-bytes", str(args.judge_max_input_bytes),
            "--task-max-output-tokens", str(args.task_max_output_tokens),
            "--reflection-max-output-tokens", str(args.reflection_max_output_tokens),
            "--judge-max-output-tokens", str(args.judge_max_output_tokens),
            "--max-concurrency", str(args.max_concurrency),
            "--api-key-env", args.api_key_env,
            "--state", str(state_path), "--output", str(fresh_path),
        ]
        if args.input_price_per_million is not None:
            child_args += ["--input-price-per-million", str(args.input_price_per_million)]
        if args.output_price_per_million is not None:
            child_args += ["--output-price-per-million", str(args.output_price_per_million)]
        for role in ("task", "reflection", "judge"):
            for direction in ("input", "output"):
                value = getattr(args, f"{role}_{direction}_price_per_million", None)
                if value is not None:
                    child_args += [f"--{role}-{direction}-price-per-million", str(value)]
        if args.api_base:
            child_args += ["--api-base", args.api_base]
        if args.livebench_math_python:
            child_args += ["--livebench-math-python", str(args.livebench_math_python)]
        if args.retrieval_root:
            child_args += ["--retrieval-root", str(args.retrieval_root)]
        if args.retrieval_receipt:
            child_args += ["--retrieval-receipt", str(args.retrieval_receipt)]
        parent_accounted_total = SPEND_GUARD.snapshot()["accounted_total_usd"]
        child_args += [
            "--initial-cost-usd", str(parent_accounted_total),
            "--max-cost-usd", str(args.max_cost_usd),
        ]
        subprocess.run(child_args, check=True)
        state_sha = sha256(state_path)
        fresh_sha = sha256(fresh_path)
        fresh_receipt = json.loads(fresh_path.read_text())
        if not (
            fresh_receipt.get("status") == "fresh_ok"
            and fresh_receipt.get("loaded_state_sha256") == state_sha
            and fresh_receipt.get("condition") == preflight["condition"]
            and fresh_receipt.get("data") == preflight["data"]
        ):
            raise RuntimeError("fresh DSPy receipt does not bind the selected state and condition")
        fresh_usage = fresh_receipt["usage"]
        fresh_spend = fresh_receipt["spend_admission"]

    payload = {
        **preflight,
        "status": "complete",
        "heldout_decoded": True,
        "heldout": heldout_result,
        "predictors": predictor_state(selected),
        "state_sha256": state_sha,
        "fresh_sha256": fresh_sha,
        "usage": merge_runtime_usage(runtime_usage(), fresh_usage),
        "fresh_spend_admission": fresh_spend,
        "progress_sha256": sha256(progress_path),
        "wall_time_us": (time.monotonic_ns() - started) // 1_000,
        "spend_admission": {**admission, "final": SPEND_GUARD.snapshot()},
    }
    write_private_json(args.output, payload)


def retain_terminal_failure(error: BaseException) -> None:
    args = ACTIVE_ARGS
    if args is None or args.output is None or args.output.exists():
        return
    elapsed = 0 if RUN_STARTED_NS is None else (time.monotonic_ns() - RUN_STARTED_NS) // 1_000
    child = retained_fresh_failure(args)
    payload = {
        **(ACTIVE_PREFLIGHT or {}),
        "status": "failed",
        "family": args.family,
        "arm": args.arm,
        "seed": args.seed,
        "stage": ACTIVE_STAGE,
        "error_type": type(error).__name__,
        "error_sha256": hashlib.sha256(str(error).encode()).hexdigest(),
        "usage": merge_runtime_usage(runtime_usage(), child["usage"]),
        "fresh_failure_evidence": child["evidence"],
        "fresh_spend_admission": child["spend_admission"],
        "loaded_state_sha256": (
            sha256(args.state) if args.fresh and args.state is not None and args.state.is_file() else None
        ),
        "progress_sha256":
            sha256(PROGRESS_PATH) if PROGRESS_PATH is not None and PROGRESS_PATH.exists() else None,
        "wall_time_us": elapsed,
        "spend_admission": (
            {"final": SPEND_GUARD.snapshot()} if SPEND_GUARD is not None else None
        ),
    }
    write_private_json(args.output, payload)


def retained_fresh_failure(args: argparse.Namespace) -> dict[str, Any]:
    unresolved = {
        "usage": {"summary": {}, "events": []},
        "spend_admission": None,
        "evidence": {
            "status": "unresolved",
            "reason": "no_valid_atomic_child_failure_receipt",
            "passed_initial_cost_usd": (
                SPEND_GUARD.snapshot()["accounted_total_usd"] if SPEND_GUARD is not None else None
            ),
        },
    }
    if args.fresh or args.arm == "baseline" or args.output is None:
        return unresolved
    fresh_path = args.output.with_suffix(".fresh.json")
    state_path = args.output.with_suffix(".state.json")
    if not fresh_path.is_file() or not state_path.is_file():
        return unresolved
    try:
        receipt = json.loads(fresh_path.read_text())
        expected = ACTIVE_PREFLIGHT or {}
        if not (
            receipt.get("status") == "failed"
            and receipt.get("condition") == expected.get("condition")
            and receipt.get("data") == expected.get("data")
            and receipt.get("loaded_state_sha256") == sha256(state_path)
        ):
            return unresolved
        return {
            "usage": receipt.get("usage") or {"summary": {}, "events": []},
            "spend_admission": receipt.get("spend_admission"),
            "evidence": {
                "status": "retained",
                "sha256": sha256(fresh_path),
                "path": str(fresh_path),
            },
        }
    except (OSError, ValueError):
        return unresolved


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        retain_terminal_failure(error)
        raise
