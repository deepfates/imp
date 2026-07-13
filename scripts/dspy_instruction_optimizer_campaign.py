#!/usr/bin/env python3
"""Run a pinned, held-out AIMEBench DSPy instruction-optimizer campaign.

The JSON checkpoint is the campaign journal. Completed evaluation rows resume;
ambiguous in-flight provider work requires explicit operator resolution.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import inspect
import json
import math
import os
import re
import sys
import tempfile
import threading
import time
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from upstream_authority_registry import load_registry_authority  # noqa: E402


CONTRACT_ID = "t1_instruction_optimizer_differential_contract"
_, AUTHORITY = load_registry_authority(CONTRACT_ID)
EXPECTED_VERSION = AUTHORITY["version"]
EXPECTED_COMMIT = AUTHORITY["commit"]
EXPECTED_OPTUNA_VERSION = "4.9.0"
SUPPORTED_ARMS = ("baseline", "BootstrapFewShot", "MIPROv2", "SIMBA")
CHECKPOINT_SCHEMA = 1
REPORT_SCHEMA = 1


class CampaignError(RuntimeError):
    """Base class for fail-closed campaign errors."""


class IdentityError(CampaignError):
    """Raised when source, data, config, or artifact identity drifts."""


class BudgetExceeded(CampaignError):
    """Raised before dispatch when a conservative reservation cannot fit."""


class AmbiguousEvaluation(CampaignError):
    """Raised when provider work may have happened without a committed row."""


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return sha256_bytes(encoded.encode("ascii"))


def checkpoint_digest(state: Mapping[str, Any]) -> str:
    content = {key: value for key, value in state.items() if key != "checkpoint_sha256"}
    return canonical_digest(content)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def atomic_json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _nonnegative_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise CampaignError(f"{label} must be a non-negative number")
    return float(value)


def _nonnegative_integer(value: Any, label: str) -> int:
    number = _nonnegative_number(value, label)
    if int(number) != number:
        raise CampaignError(f"{label} must be a non-negative integer")
    return int(number)


class UsageLedger:
    """Atomic admission reservations plus distinct reconciled actual usage."""

    def __init__(
        self,
        ceilings: Mapping[str, Any],
        pricing: Mapping[str, Any] | None = None,
        reservation: Mapping[str, Any] | None = None,
    ) -> None:
        required = {"requests", "input_tokens", "output_tokens", "usd"}
        if set(ceilings) != required:
            raise CampaignError(
                "ceilings must contain exactly requests, input_tokens, output_tokens, and usd"
            )
        self.ceilings = {
            "requests": _nonnegative_integer(ceilings["requests"], "ceilings.requests"),
            "input_tokens": _nonnegative_integer(
                ceilings["input_tokens"], "ceilings.input_tokens"
            ),
            "output_tokens": _nonnegative_integer(
                ceilings["output_tokens"], "ceilings.output_tokens"
            ),
            "usd": _nonnegative_number(ceilings["usd"], "ceilings.usd"),
        }
        self.pricing = dict(pricing or {})
        self.reservation = dict(reservation or {})
        required_reservation = {
            "max_output_tokens",
            "input_tokens_per_byte",
            "input_usd_per_million",
            "output_usd_per_million",
        }
        if set(self.reservation) != required_reservation:
            raise CampaignError(
                "provider.reservation must contain exactly max_output_tokens, input_tokens_per_byte, "
                "input_usd_per_million, and output_usd_per_million"
            )
        self.reservation["max_output_tokens"] = _nonnegative_integer(
            self.reservation["max_output_tokens"], "provider.reservation.max_output_tokens"
        )
        self.reservation["input_tokens_per_byte"] = _nonnegative_number(
            self.reservation["input_tokens_per_byte"], "provider.reservation.input_tokens_per_byte"
        )
        if self.reservation["max_output_tokens"] <= 0:
            raise CampaignError("provider.reservation.max_output_tokens must be positive")
        if self.reservation["input_tokens_per_byte"] < 1:
            raise CampaignError("provider.reservation.input_tokens_per_byte must be at least 1")
        for key in ("input_usd_per_million", "output_usd_per_million"):
            self.reservation[key] = _nonnegative_number(
                self.reservation[key], f"provider.reservation.{key}"
            )
            if key in self.pricing:
                actual_rate = _nonnegative_number(self.pricing[key], f"provider.pricing.{key}")
                if self.reservation[key] < actual_rate:
                    raise CampaignError(f"provider.reservation.{key} must cover provider.pricing.{key}")
        self.totals: dict[str, Any] = {
            "requests": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "tokens": 0,
            "usd": 0.0,
            "cost_sources": {},
        }
        self._lock = threading.Lock()
        self._reservations: dict[int, dict[str, Any]] = {}
        self._next_reservation_id = 1

    def restore(self, totals: Mapping[str, Any]) -> None:
        with self._lock:
            expected = {"requests", "input_tokens", "output_tokens", "tokens", "usd", "cost_sources"}
            if set(totals) != expected:
                raise IdentityError("checkpoint usage shape is invalid")
            restored = deepcopy(dict(totals))
            for key in ("requests", "input_tokens", "output_tokens", "tokens"):
                restored[key] = int(_nonnegative_number(restored[key], f"usage.{key}"))
            restored["usd"] = _nonnegative_number(restored["usd"], "usage.usd")
            if restored["tokens"] != restored["input_tokens"] + restored["output_tokens"]:
                raise IdentityError("checkpoint token totals are inconsistent")
            self.totals = restored

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return deepcopy(self.totals)

    def reserve(self, prompt: Any = None, messages: Any = None) -> int:
        input_tokens = self.input_token_upper_bound(prompt, messages)
        output_tokens = self.reservation["max_output_tokens"]
        token_reservation = input_tokens + output_tokens
        usd_reservation = self._reservation_cost(input_tokens, output_tokens)
        with self._lock:
            reserved_input = sum(item["input_tokens"] for item in self._reservations.values())
            reserved_output = sum(item["output_tokens"] for item in self._reservations.values())
            reserved_usd = sum(item["usd"] for item in self._reservations.values())
            projected = {
                "requests": self.totals["requests"] + 1,
                "input_tokens": self.totals["input_tokens"] + reserved_input + input_tokens,
                "output_tokens": self.totals["output_tokens"] + reserved_output + output_tokens,
                "usd": self.totals["usd"] + reserved_usd + usd_reservation,
            }
            for key, value in projected.items():
                if value > self.ceilings[key]:
                    raise BudgetExceeded(
                        f"{key} ceiling reservation rejected ({value} > {self.ceilings[key]}); call not dispatched"
                    )
            reservation_id = self._next_reservation_id
            self._next_reservation_id += 1
            self._reservations[reservation_id] = {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "tokens": token_reservation,
                "usd": usd_reservation,
            }
            # A successful reservation is the dispatch boundary. Failed
            # provider attempts remain actual request attempts.
            self.totals["requests"] += 1
            return reservation_id

    def reconcile(self, reservation_id: int, usage: Mapping[str, Any], cost: float | None = None) -> None:
        input_tokens = _usage_integer(usage, "prompt_tokens", "input_tokens")
        output_tokens = _usage_integer(usage, "completion_tokens", "output_tokens")
        total_tokens = _usage_integer(usage, "total_tokens")
        if input_tokens is None or output_tokens is None:
            raise CampaignError("provider response omitted actual input/output token usage")
        total_tokens = total_tokens if total_tokens is not None else input_tokens + output_tokens
        if min(input_tokens, output_tokens, total_tokens) < 0 or input_tokens + output_tokens != total_tokens:
            raise CampaignError("provider returned inconsistent token usage")

        cost_source = "provider"
        if cost is None:
            cost = self._priced_cost(input_tokens, output_tokens)
            cost_source = "configured_token_pricing"
        cost = _nonnegative_number(cost, "response cost")
        violation = None
        with self._lock:
            reserved = self._reservations.pop(reservation_id, None)
            if reserved is None:
                raise CampaignError("unknown or already reconciled call reservation")
            if input_tokens > reserved["input_tokens"] or output_tokens > reserved["output_tokens"]:
                violation = "provider usage exceeded the conservative token reservation"
            if cost > reserved["usd"] + 1e-12:
                violation = "actual provider cost exceeded the configured USD reservation"
            self.totals["input_tokens"] += input_tokens
            self.totals["output_tokens"] += output_tokens
            self.totals["tokens"] += total_tokens
            self.totals["usd"] = round(self.totals["usd"] + cost, 12)
            sources = self.totals["cost_sources"]
            sources[cost_source] = sources.get(cost_source, 0) + 1
        if violation:
            raise CampaignError(violation)

    def abandon(self, reservation_id: int) -> None:
        """Release token/USD reservation after a dispatched request failed."""
        with self._lock:
            self._reservations.pop(reservation_id, None)

    def input_token_upper_bound(self, prompt: Any, messages: Any) -> int:
        payload = messages if messages else (prompt if prompt is not None else "")
        serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        byte_count = len(serialized.encode("utf-8"))
        return max(1, math.ceil(byte_count * self.reservation["input_tokens_per_byte"]))

    def admission_snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "reservation_config": deepcopy(self.reservation),
                "active_reservations": len(self._reservations),
                "reserved_tokens": sum(item["tokens"] for item in self._reservations.values()),
                "reserved_usd": round(sum(item["usd"] for item in self._reservations.values()), 12),
            }

    def _reservation_cost(self, input_tokens: int, output_tokens: int) -> float:
        return (
            input_tokens * self.reservation["input_usd_per_million"]
            + output_tokens * self.reservation["output_usd_per_million"]
        ) / 1_000_000

    def _priced_cost(self, input_tokens: int, output_tokens: int) -> float:
        required = ("input_usd_per_million", "output_usd_per_million")
        if any(key not in self.pricing for key in required):
            raise CampaignError("provider omitted cost and config has no complete token pricing")
        input_rate = _nonnegative_number(self.pricing[required[0]], f"pricing.{required[0]}")
        output_rate = _nonnegative_number(self.pricing[required[1]], f"pricing.{required[1]}")
        return (input_tokens * input_rate + output_tokens * output_rate) / 1_000_000


def _usage_integer(usage: Mapping[str, Any], *keys: str) -> int | None:
    for key in keys:
        value = usage.get(key)
        if value is not None:
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0 or int(value) != value:
                raise CampaignError(f"provider usage {key} must be a non-negative integer")
            return int(value)
    return None


def usage_delta(start: Mapping[str, Any], finish: Mapping[str, Any]) -> dict[str, Any]:
    result = {key: finish[key] - start[key] for key in ("requests", "input_tokens", "output_tokens", "tokens", "usd")}
    result["usd"] = round(result["usd"], 12)
    return result


def response_usage(response: Any) -> tuple[Mapping[str, Any], float | None]:
    usage = getattr(response, "usage", None)
    if usage is None and isinstance(response, Mapping):
        usage = response.get("usage")
    if hasattr(usage, "model_dump"):
        usage = usage.model_dump()
    if not isinstance(usage, Mapping):
        raise CampaignError("provider response omitted actual usage")
    hidden = getattr(response, "_hidden_params", None)
    if hidden is None and isinstance(response, Mapping):
        hidden = response.get("_hidden_params", {})
    cost = hidden.get("response_cost") if isinstance(hidden, Mapping) else None
    return usage, cost


def make_budgeted_lm(dspy: Any, delegate: Any, ledger: UsageLedger) -> Any:
    """Wrap a real DSPy LM while preserving BaseLM copy semantics."""

    class BudgetedLM(dspy.BaseLM):
        forward_contract = "legacy"

        def __init__(self, inner: Any) -> None:
            self._inner = inner
            super().__init__(
                model=inner.model,
                model_type=inner.model_type,
                cache=False,
                temperature=None,
                max_tokens=None,
                num_retries=0,
            )
            self.kwargs = dict(getattr(inner, "kwargs", {}) or {})

        @property
        def supports_function_calling(self) -> bool:
            return self._inner.supports_function_calling

        @property
        def supports_reasoning(self) -> bool:
            return self._inner.supports_reasoning

        @property
        def supports_response_schema(self) -> bool:
            return self._inner.supports_response_schema

        @property
        def supported_params(self) -> set[str]:
            return self._inner.supported_params

        def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
            _validate_output_limit(kwargs, ledger.reservation["max_output_tokens"])
            reservation_id = ledger.reserve(prompt, messages)
            try:
                response = self._inner.forward(prompt=prompt, messages=messages, **kwargs)
                usage, cost = response_usage(response)
                ledger.reconcile(reservation_id, usage, cost)
                return response
            except Exception:
                ledger.abandon(reservation_id)
                raise

        async def aforward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
            _validate_output_limit(kwargs, ledger.reservation["max_output_tokens"])
            reservation_id = ledger.reserve(prompt, messages)
            try:
                response = await self._inner.aforward(prompt=prompt, messages=messages, **kwargs)
                usage, cost = response_usage(response)
                ledger.reconcile(reservation_id, usage, cost)
                return response
            except Exception:
                ledger.abandon(reservation_id)
                raise

        def copy(self, **kwargs):  # noqa: ANN003
            _validate_output_limit(kwargs, ledger.reservation["max_output_tokens"])
            return BudgetedLM(self._inner.copy(**kwargs))

    return BudgetedLM(delegate)


def _validate_output_limit(kwargs: Mapping[str, Any], maximum: int) -> None:
    for key in ("max_tokens", "max_completion_tokens"):
        value = kwargs.get(key)
        if value is not None and _nonnegative_integer(value, key) > maximum:
            raise BudgetExceeded(f"{key}={value} exceeds reserved max_output_tokens={maximum}")


class DSPyRuntime:
    """Pinned DSPy implementation. Tests substitute a provider-free runtime."""

    def __init__(self, config: Mapping[str, Any]) -> None:
        try:
            import dspy
            from dspy.propose import grounded_proposer
            from dspy.teleprompt import mipro_optimizer_v2, simba, simba_utils, utils

            bootstrap = importlib.import_module("dspy.teleprompt.bootstrap")
        except ImportError as exc:
            raise CampaignError("pinned DSPy 3.3.0b1 is required on PYTHONPATH") from exc
        self.dspy = dspy
        modules = {
            "dspy/propose/grounded_proposer.py": grounded_proposer,
            "dspy/teleprompt/bootstrap.py": bootstrap,
            "dspy/teleprompt/mipro_optimizer_v2.py": mipro_optimizer_v2,
            "dspy/teleprompt/simba.py": simba,
            "dspy/teleprompt/simba_utils.py": simba_utils,
            "dspy/teleprompt/utils.py": utils,
        }
        self.source_identity = validate_dspy_sources(dspy, modules)
        optuna_version = importlib.metadata.version("optuna")
        if optuna_version != EXPECTED_OPTUNA_VERSION:
            raise IdentityError(
                f"pinned Optuna validation failed: expected {EXPECTED_OPTUNA_VERSION}, got {optuna_version}"
            )
        self.dependency_identity = {"optuna": optuna_version}
        self.provider = deepcopy(config["provider"])
        self.provider_kwargs = deepcopy(self.provider.get("kwargs", {}))
        api_key_env = self.provider.get("api_key_env")
        if api_key_env:
            api_key = os.environ.get(api_key_env)
            if not api_key:
                raise CampaignError(f"provider credential environment variable {api_key_env} is required")
            self.provider_kwargs["api_key"] = api_key
        self.provider_kwargs["cache"] = False
        # Provider retries are opaque additional requests. The campaign owns
        # retries at durable boundaries instead, so accounting remains exact.
        self.provider_kwargs["num_retries"] = 0
        if "max_tokens" not in self.provider_kwargs and "max_completion_tokens" not in self.provider_kwargs:
            self.provider_kwargs["max_tokens"] = self.provider["reservation"]["max_output_tokens"]
        self._lm_by_arm: dict[str, Any] = {}
        self.lm = None

        class AIME(dspy.Signature):
            """Solve the math problem carefully. Return the final answer as one integer."""

            problem = dspy.InputField(desc="AIME competition problem")
            answer = dspy.OutputField(desc="final integer answer only")

        self.signature = AIME

    def activate_arm(self, arm: str, ledger: UsageLedger) -> None:
        if arm not in self._lm_by_arm:
            delegate = self.dspy.LM(self.provider["model"], **deepcopy(self.provider_kwargs))
            self._lm_by_arm[arm] = make_budgeted_lm(self.dspy, delegate, ledger)
        self.lm = self._lm_by_arm[arm]
        self.dspy.configure(lm=self.lm)

    def examples(self, records: Sequence[Mapping[str, Any]]) -> list[Any]:
        return [
            self.dspy.Example(problem=row["problem"], answer=row["answer"]).with_inputs("problem")
            for row in records
        ]

    def new_program(self) -> Any:
        return self.dspy.ChainOfThought(self.signature)

    def compile(self, arm: str, options: Mapping[str, Any], train: Sequence[Any], dev: Sequence[Any], seed: int) -> Any:
        student = self.new_program()
        if arm == "baseline":
            return student
        if arm == "BootstrapFewShot":
            optimizer = self.dspy.BootstrapFewShot(metric=aime_metric, **dict(options))
            return optimizer.compile(student, trainset=list(train))
        if arm == "MIPROv2":
            constructor = dict(options.get("constructor", {}))
            compile_options = dict(options.get("compile", {}))
            constructor["metric"] = aime_metric
            constructor["prompt_model"] = self.lm
            constructor["task_model"] = self.lm
            constructor["seed"] = seed
            constructor.setdefault("num_threads", 1)
            optimizer = self.dspy.MIPROv2(**constructor)
            compile_options.setdefault("requires_permission_to_run", False)
            compile_options["seed"] = seed
            return optimizer.compile(student, trainset=list(train), valset=list(dev), **compile_options)
        if arm == "SIMBA":
            constructor = dict(options)
            constructor["metric"] = aime_metric
            constructor["prompt_model"] = self.lm
            constructor.setdefault("num_threads", 1)
            optimizer = self.dspy.SIMBA(**constructor)
            return optimizer.compile(student, trainset=list(train), seed=seed)
        raise CampaignError(f"unsupported arm: {arm}")

    def evaluate_one(
        self,
        program: Any,
        record: Mapping[str, Any],
        split: str,
        arm: str,
        index: int,
    ) -> dict[str, Any]:
        prediction = program(problem=record["problem"])
        answer = str(getattr(prediction, "answer", ""))
        return {
            "index": index,
            "prediction": answer,
            "correct": bool(aime_metric(record, prediction)),
        }

    def save_program(self, program: Any, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        program.save(str(path))

    def load_program(self, path: Path) -> Any:
        program = self.new_program()
        program.load(str(path))
        return program

    def selected_material(self, program: Any) -> dict[str, Any]:
        predictors = []
        for predictor in program.predictors():
            signature = getattr(predictor, "signature", None)
            instructions = getattr(signature, "instructions", None)
            demos = [_json_safe_demo(demo) for demo in getattr(predictor, "demos", [])]
            predictors.append({"instructions": instructions, "demos": demos})
        return {"predictors": predictors}


def validate_dspy_sources(dspy: Any, modules: Mapping[str, Any]) -> dict[str, Any]:
    failures = []
    version = getattr(dspy, "__version__", "unknown")
    if version != EXPECTED_VERSION:
        failures.append(f"version expected {EXPECTED_VERSION}, got {version}")
    if set(modules) != set(AUTHORITY["source_hashes"]):
        failures.append("source set differs from authority registry")
    sources = {}
    for relative, expected in AUTHORITY["source_hashes"].items():
        module = modules.get(relative)
        path = Path(inspect.getsourcefile(module) or "") if module is not None else Path("")
        actual = sha256_file(path) if path.is_file() else "missing"
        sources[relative] = {"sha256": actual, "path": str(path.resolve()) if path.is_file() else None}
        if actual != expected:
            failures.append(f"{relative} expected {expected}, got {actual}")
    if failures:
        raise IdentityError("pinned DSPy validation failed:\n- " + "\n- ".join(failures))
    return {
        "project": AUTHORITY["project"],
        "repository": AUTHORITY["repository"],
        "version": EXPECTED_VERSION,
        "commit": EXPECTED_COMMIT,
        "source_hashes": {key: value["sha256"] for key, value in sources.items()},
    }


def _json_safe_demo(demo: Any) -> Any:
    if hasattr(demo, "toDict"):
        return demo.toDict()
    if isinstance(demo, Mapping):
        return dict(demo)
    return repr(demo)


def parse_integer(value: Any) -> int | None:
    text = str(value).strip()
    match = re.fullmatch(r"[+-]?\d+", text)
    return int(text) if match else None


def aime_metric(example: Any, prediction: Any, trace=None) -> float:  # noqa: ANN001
    expected = example["answer"] if isinstance(example, Mapping) else getattr(example, "answer", None)
    actual = prediction["answer"] if isinstance(prediction, Mapping) else getattr(prediction, "answer", None)
    parsed_expected = parse_integer(expected)
    parsed_actual = parse_integer(actual)
    return float(parsed_expected is not None and parsed_actual == parsed_expected)


def load_config(path: Path) -> dict[str, Any]:
    try:
        config = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise CampaignError(f"invalid campaign config {path}: {exc}") from exc
    validate_config(config)
    return config


def validate_config(config: Any) -> None:
    if not isinstance(config, dict) or config.get("schema_version") != 1:
        raise CampaignError("config schema_version must be 1")
    required = {
        "campaign_id",
        "dataset",
        "provider",
        "budget_scope",
        "per_arm_ceilings",
        "dependency_identity",
        "arms",
        "split_limits",
    }
    missing = sorted(required - set(config))
    if missing:
        raise CampaignError(f"config is missing required fields: {', '.join(missing)}")
    if not isinstance(config["campaign_id"], str) or not config["campaign_id"]:
        raise CampaignError("campaign_id must be a non-empty string")
    if config["budget_scope"] != "per_arm":
        raise CampaignError("budget_scope must be per_arm for matched evidence")
    if config["dependency_identity"] != {"optuna": EXPECTED_OPTUNA_VERSION}:
        raise IdentityError(
            f"dependency_identity must pin optuna {EXPECTED_OPTUNA_VERSION}"
        )
    dataset = config["dataset"]
    if not isinstance(dataset, dict) or set(dataset) != {"train", "dev", "test"}:
        raise CampaignError("dataset must contain exactly train, dev, and test")
    for split, spec in dataset.items():
        if not isinstance(spec, dict) or set(spec) != {"path", "sha256"}:
            raise CampaignError(f"dataset.{split} must contain exactly path and sha256")
        if not re.fullmatch(r"[0-9a-f]{64}", str(spec["sha256"])):
            raise CampaignError(f"dataset.{split}.sha256 is invalid")
    split_limits = config["split_limits"]
    if not isinstance(split_limits, dict) or set(split_limits) != {"train", "dev", "test"}:
        raise CampaignError("split_limits must contain exactly train, dev, and test")
    for split, limit in split_limits.items():
        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            raise CampaignError(f"split_limits.{split} must be a positive integer")
    provider = config["provider"]
    if not isinstance(provider, dict) or not isinstance(provider.get("model"), str) or not provider["model"]:
        raise CampaignError("provider.model must be a non-empty DSPy model identifier")
    if not isinstance(provider.get("kwargs", {}), dict):
        raise CampaignError("provider.kwargs must be an object")
    if not isinstance(provider.get("pricing", {}), dict):
        raise CampaignError("provider.pricing must be an object")
    if not isinstance(provider.get("reservation"), dict):
        raise CampaignError("provider.reservation must be an object")
    ledger = UsageLedger(config["per_arm_ceilings"], provider.get("pricing"), provider["reservation"])
    for key in ("max_tokens", "max_completion_tokens"):
        value = provider.get("kwargs", {}).get(key)
        if value is not None:
            _validate_output_limit({key: value}, ledger.reservation["max_output_tokens"])
    arms = config["arms"]
    if not isinstance(arms, list) or not arms:
        raise CampaignError("arms must be a non-empty list")
    names = []
    for arm in arms:
        if not isinstance(arm, dict) or set(arm) - {"name", "config"} or "name" not in arm:
            raise CampaignError("each arm must contain name and optional config only")
        if arm["name"] not in SUPPORTED_ARMS:
            raise CampaignError(f"unsupported arm: {arm['name']}")
        if not isinstance(arm.get("config", {}), dict):
            raise CampaignError(f"arm {arm['name']} config must be an object")
        options = arm.get("config", {})
        if arm["name"] == "baseline" and options:
            raise CampaignError("baseline arm config must be empty")
        if arm["name"] == "BootstrapFewShot" and "metric" in options:
            raise CampaignError("BootstrapFewShot metric is fixed by the campaign")
        constructor = options.get("constructor", {}) if arm["name"] == "MIPROv2" else options
        if arm["name"] in ("MIPROv2", "SIMBA"):
            if not isinstance(constructor, dict):
                raise CampaignError(f"{arm['name']} constructor config must be an object")
            if arm["name"] == "MIPROv2" and not isinstance(options.get("compile", {}), dict):
                raise CampaignError("MIPROv2 compile config must be an object")
            forbidden = {"metric", "prompt_model", "task_model"} & set(constructor)
            if forbidden:
                raise CampaignError(f"{arm['name']} config cannot override {', '.join(sorted(forbidden))}")
            if constructor.get("num_threads", 1) != 1:
                raise CampaignError(f"{arm['name']} num_threads must be 1 for exact budget enforcement")
        names.append(arm["name"])
    if len(names) != len(set(names)):
        raise CampaignError("arm names must be unique")
    source = config.get("source_identity")
    if source is not None and source != {"version": EXPECTED_VERSION, "commit": EXPECTED_COMMIT}:
        raise IdentityError("config source_identity does not match the pinned DSPy authority")


def load_dataset(config: Mapping[str, Any], config_dir: Path) -> tuple[dict[str, list[dict[str, str]]], dict[str, Any]]:
    datasets = {}
    identity = {}
    full_problem_sets = {}
    seen_paths = set()
    for split in ("train", "dev", "test"):
        spec = config["dataset"][split]
        path = Path(spec["path"])
        if not path.is_absolute():
            path = config_dir / path
        path = path.resolve()
        if path in seen_paths:
            raise IdentityError("train, dev, and test must use distinct files")
        seen_paths.add(path)
        try:
            actual = sha256_file(path)
        except OSError as exc:
            raise IdentityError(f"cannot read dataset split {split}: {exc}") from exc
        if actual != spec["sha256"]:
            raise IdentityError(f"dataset {split} hash mismatch: expected {spec['sha256']}, got {actual}")
        rows = []
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                source = json.loads(line)
            except json.JSONDecodeError as exc:
                raise CampaignError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(source, dict):
                raise CampaignError(f"{path}:{line_number}: each JSONL row must be an object")
            problem = source.get("problem", source.get("input", source.get("question")))
            answer = source.get("answer")
            if not isinstance(problem, str) or parse_integer(answer) is None:
                raise CampaignError(f"{path}:{line_number}: expected string problem and integer answer")
            rows.append({"problem": problem, "answer": str(parse_integer(answer))})
        if not rows:
            raise CampaignError(f"dataset split {split} is empty")
        full_problem_sets[split] = {row["problem"] for row in rows}
        limit = config["split_limits"][split]
        if limit > len(rows):
            raise CampaignError(
                f"split_limits.{split}={limit} exceeds pinned split count {len(rows)}"
            )
        datasets[split] = rows[:limit]
        identity[split] = {
            "path": str(path),
            "sha256": actual,
            "count": limit,
            "full_count": len(rows),
            "selection": {"method": "prefix", "indices": list(range(limit))},
        }
    for left, right in (("train", "dev"), ("train", "test"), ("dev", "test")):
        overlap = full_problem_sets[left] & full_problem_sets[right]
        if overlap:
            raise IdentityError(f"dataset leakage: {left} and {right} share {len(overlap)} problem(s)")
    return datasets, identity


def aggregate_usage(snapshots: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
    aggregate: dict[str, Any] = {
        "requests": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "tokens": 0,
        "usd": 0.0,
        "cost_sources": {},
    }
    for usage in snapshots.values():
        for key in ("requests", "input_tokens", "output_tokens", "tokens"):
            aggregate[key] += usage[key]
        aggregate["usd"] += usage["usd"]
        for source, count in usage["cost_sources"].items():
            aggregate["cost_sources"][source] = aggregate["cost_sources"].get(source, 0) + count
    aggregate["usd"] = round(aggregate["usd"], 12)
    return aggregate


class Campaign:
    def __init__(
        self,
        config: Mapping[str, Any],
        config_path: Path,
        checkpoint_path: Path,
        output_path: Path,
        runtime_factory: Callable[[Mapping[str, Any]], Any] = DSPyRuntime,
    ) -> None:
        self.config = deepcopy(dict(config))
        validate_config(self.config)
        self.config_path = config_path.resolve()
        self.checkpoint_path = checkpoint_path.resolve()
        self.output_path = output_path.resolve()
        self.config_digest = canonical_digest(self.config)
        self.datasets, self.dataset_identity = load_dataset(self.config, self.config_path.parent)
        self.ledgers = {
            arm["name"]: UsageLedger(
                self.config["per_arm_ceilings"],
                self.config["provider"].get("pricing"),
                self.config["provider"]["reservation"],
            )
            for arm in self.config["arms"]
        }
        self.runtime = runtime_factory(self.config)
        self.state = self._load_or_initialize()

    def _new_state(self) -> dict[str, Any]:
        return {
            "schema_version": CHECKPOINT_SCHEMA,
            "campaign_id": self.config["campaign_id"],
            "config_sha256": self.config_digest,
            "dataset": self.dataset_identity,
            "source_identity": self.runtime.source_identity,
            "dependency_identity": self.runtime.dependency_identity,
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "usage_by_arm": self._usage_by_arm(),
            "aggregate_usage": aggregate_usage(self._usage_by_arm()),
            "arms": {},
            "selected_arm": None,
            "status": "running",
            "failures": [],
        }

    def _load_or_initialize(self) -> dict[str, Any]:
        if not self.checkpoint_path.exists():
            state = self._new_state()
            self._checkpoint(state)
            return state
        try:
            state = json.loads(self.checkpoint_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise IdentityError(f"invalid checkpoint: {exc}") from exc
        if not isinstance(state, dict):
            raise IdentityError("checkpoint must be a JSON object")
        if state.get("schema_version") != CHECKPOINT_SCHEMA:
            raise IdentityError("checkpoint schema mismatch")
        if state.get("checkpoint_sha256") != checkpoint_digest(state):
            raise IdentityError("checkpoint integrity digest mismatch")
        checks = (
            (state.get("campaign_id"), self.config["campaign_id"], "campaign id"),
            (state.get("config_sha256"), self.config_digest, "config"),
            (state.get("dataset"), self.dataset_identity, "dataset identity"),
            (state.get("source_identity"), self.runtime.source_identity, "source identity"),
            (
                state.get("dependency_identity"),
                self.runtime.dependency_identity,
                "dependency identity",
            ),
        )
        for actual, expected, label in checks:
            if actual != expected:
                raise IdentityError(f"checkpoint {label} mismatch")
        usage_by_arm = state.get("usage_by_arm")
        if not isinstance(usage_by_arm, dict) or set(usage_by_arm) != set(self.ledgers):
            raise IdentityError("checkpoint per-arm usage set mismatch")
        for name, ledger in self.ledgers.items():
            ledger.restore(usage_by_arm[name])
        if state.get("aggregate_usage") != aggregate_usage(self._usage_by_arm()):
            raise IdentityError("checkpoint aggregate usage is inconsistent with per-arm usage")
        for name, arm in state.get("arms", {}).items():
            artifact = arm.get("artifact")
            if artifact:
                path = Path(artifact["path"])
                if not path.is_file() or sha256_file(path) != artifact["sha256"]:
                    raise IdentityError(f"compiled artifact mismatch for {name}")
        return state

    def _checkpoint(self, state: dict[str, Any] | None = None) -> None:
        target = state if state is not None else self.state
        target["updated_at"] = utc_now()
        target["usage_by_arm"] = self._usage_by_arm()
        target["aggregate_usage"] = aggregate_usage(target["usage_by_arm"])
        target["checkpoint_sha256"] = checkpoint_digest(target)
        atomic_json_write(self.checkpoint_path, target)

    def _usage_by_arm(self) -> dict[str, Any]:
        return {name: ledger.snapshot() for name, ledger in self.ledgers.items()}

    def _activate_arm(self, name: str) -> UsageLedger:
        ledger = self.ledgers[name]
        self.runtime.activate_arm(name, ledger)
        return ledger

    def _artifact_path(self, name: str) -> Path:
        safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", name)
        return self.checkpoint_path.parent / f"{self.checkpoint_path.stem}.{safe}.program.json"

    def _program(self, name: str) -> Any:
        return self.runtime.load_program(Path(self.state["arms"][name]["artifact"]["path"]))

    def run(self) -> dict[str, Any]:
        started = time.perf_counter()
        try:
            for arm_spec in self.config["arms"]:
                self._compile_and_dev(arm_spec)
            if self.state["selected_arm"] is None:
                self.state["selected_arm"] = max(
                    (arm["name"] for arm in self.config["arms"]),
                    key=lambda name: (self.state["arms"][name]["dev"]["score"], -self._arm_index(name)),
                )
                self._checkpoint()
            for arm_spec in self.config["arms"]:
                self._evaluate_split(arm_spec["name"], "test")
            self.state["status"] = "complete"
            self._checkpoint()
        except Exception as exc:
            self.state["status"] = "failed"
            self.state["failures"].append({"at": utc_now(), "type": type(exc).__name__, "message": str(exc)})
            self._checkpoint()
            atomic_json_write(self.output_path, self._report(time.perf_counter() - started))
            raise
        report = self._report(time.perf_counter() - started)
        atomic_json_write(self.output_path, report)
        return report

    def _arm_index(self, name: str) -> int:
        return [arm["name"] for arm in self.config["arms"]].index(name)

    def _compile_and_dev(self, spec: Mapping[str, Any]) -> None:
        name = spec["name"]
        ledger = self._activate_arm(name)
        arm = self.state["arms"].get(name)
        if arm is None:
            self.state["arms"][name] = {
                "name": name,
                "config": deepcopy(spec.get("config", {})),
                "compile_started": utc_now(),
                "artifact": None,
                "compile": None,
                "dev": None,
                "test": None,
            }
            self._checkpoint()
            usage_start = ledger.snapshot()
            phase_start = time.perf_counter()
            program = self.runtime.compile(
                name,
                spec.get("config", {}),
                self.runtime.examples(self.datasets["train"]),
                self.runtime.examples(self.datasets["dev"]),
                int(self.config.get("seed", 0)),
            )
            artifact_path = self._artifact_path(name)
            self.runtime.save_program(program, artifact_path)
            self.state["arms"][name]["artifact"] = {
                "path": str(artifact_path),
                "sha256": sha256_file(artifact_path),
            }
            self.state["arms"][name]["compile"] = {
                "wall_seconds": round(time.perf_counter() - phase_start, 6),
                "usage": usage_delta(usage_start, ledger.snapshot()),
                "selected_material": self.runtime.selected_material(program),
            }
            self._checkpoint()
        elif arm.get("compile") is None:
            raise IdentityError(f"incomplete compile phase for {name} cannot be replayed safely")
        self._evaluate_split(name, "dev")

    def _evaluate_split(self, name: str, split: str) -> None:
        ledger = self._activate_arm(name)
        arm = self.state["arms"][name]
        phase = arm.get(split)
        if phase is None:
            phase = {
                "split": split,
                "rows": [],
                "in_flight": None,
                "complete": False,
                "usage_start": ledger.snapshot(),
                "usage": None,
                "wall_seconds": 0.0,
            }
            arm[split] = phase
            self._checkpoint()
        if phase.get("complete"):
            return
        if phase.get("in_flight") is not None:
            raise AmbiguousEvaluation(self._ambiguity_message(name, split, phase["in_flight"]))
        rows = phase.get("rows")
        if not isinstance(rows, list) or [row.get("index") for row in rows] != list(range(len(rows))):
            raise IdentityError(f"{name} {split} committed rows are not a contiguous prefix")

        program = self._program(name)
        records = self.datasets[split]
        for index in range(len(rows), len(records)):
            before = ledger.snapshot()
            phase["in_flight"] = {
                "index": index,
                "intent_at": utc_now(),
                "requests_before": before["requests"],
                "status": "dispatch_intent",
                "resolution_required": (
                    "Audit provider-side request state. Supply a verified row through a new campaign, "
                    "or restart only after proving no provider request was dispatched."
                ),
            }
            self._checkpoint()
            row_started = time.perf_counter()
            try:
                row = self.runtime.evaluate_one(program, records[index], split, name, index)
            except Exception as exc:
                after = ledger.snapshot()
                if after["requests"] == before["requests"]:
                    phase["in_flight"] = None
                    self._checkpoint()
                    raise
                phase["in_flight"]["status"] = "ambiguous_after_dispatch"
                phase["in_flight"]["requests_after"] = after["requests"]
                self._checkpoint()
                raise AmbiguousEvaluation(
                    self._ambiguity_message(name, split, phase["in_flight"])
                ) from exc
            if not isinstance(row, dict) or row.get("index") != index:
                phase["in_flight"]["status"] = "ambiguous_invalid_result"
                self._checkpoint()
                raise AmbiguousEvaluation(self._ambiguity_message(name, split, phase["in_flight"]))
            after = ledger.snapshot()
            row["wall_seconds"] = round(time.perf_counter() - row_started, 6)
            row["usage"] = usage_delta(before, after)
            rows.append(row)
            phase["wall_seconds"] = round(phase["wall_seconds"] + row["wall_seconds"], 6)
            phase["in_flight"] = None
            self._checkpoint()

        phase["correct"] = sum(int(row["correct"]) for row in rows)
        phase["count"] = len(rows)
        phase["score"] = phase["correct"] / phase["count"]
        phase["predictions"] = deepcopy(rows)
        phase["usage"] = usage_delta(phase["usage_start"], ledger.snapshot())
        phase["complete"] = True
        self._checkpoint()

    @staticmethod
    def _ambiguity_message(name: str, split: str, in_flight: Mapping[str, Any]) -> str:
        return (
            f"ambiguous in-flight evaluation for arm={name} split={split} index={in_flight.get('index')}; "
            f"explicit resolution required: {in_flight.get('resolution_required')}"
        )

    def _report(self, invocation_wall_seconds: float) -> dict[str, Any]:
        completed_arms = [
            deepcopy(self.state["arms"][arm["name"]])
            for arm in self.config["arms"]
            if arm["name"] in self.state["arms"]
        ]
        measured_wall_seconds = 0.0
        for arm in completed_arms:
            for phase in ("compile", "dev", "test"):
                if arm.get(phase):
                    measured_wall_seconds += float(arm[phase].get("wall_seconds", 0.0))
        return {
            "schema_version": REPORT_SCHEMA,
            "runner": "python-dspy-instruction-optimizer-campaign",
            "generated_at": utc_now(),
            "campaign_id": self.config["campaign_id"],
            "status": self.state["status"],
            "scope": {
                "research_preflight": True,
                "evidence_tier": "research_preflight",
                "not_t3": True,
                "claim": "Held-out operational preflight only; not T3 effectiveness evidence or paper reproduction.",
                "selection_policy": "arm selected by frozen dev score only; test never participates in selection",
                "delivery_semantics": (
                    "Committed rows are not replayed. In-flight provider work without a committed row is "
                    "ambiguous and requires explicit resolution. No guarantee is made for unresolved provider writes."
                ),
            },
            "source_identity": self.state["source_identity"],
            "dependency_identity": self.state["dependency_identity"],
            "dataset": self.state["dataset"],
            "config": _sanitized_config(self.config),
            "config_sha256": self.config_digest,
            "budget_scope": "per_arm",
            "per_arm_ceilings": deepcopy(self.config["per_arm_ceilings"]),
            "actual_usage_cost_by_arm": self._usage_by_arm(),
            "aggregate_actual_usage_cost": aggregate_usage(self._usage_by_arm()),
            "admission_control_by_arm": {
                name: ledger.admission_snapshot() for name, ledger in self.ledgers.items()
            },
            "invocation_wall_seconds": round(invocation_wall_seconds, 6),
            "measured_campaign_wall_seconds": round(measured_wall_seconds, 6),
            "selected_arm": self.state["selected_arm"],
            "arms": completed_arms,
            "failures": deepcopy(self.state["failures"]),
            "checkpoint": {"path": str(self.checkpoint_path), "sha256": sha256_file(self.checkpoint_path)},
        }


def _sanitized_config(config: Mapping[str, Any]) -> dict[str, Any]:
    result = deepcopy(dict(config))
    provider = result.get("provider", {})
    kwargs = provider.get("kwargs", {})
    for key in list(kwargs):
        if any(fragment in key.lower() for fragment in ("key", "token", "secret", "password")):
            kwargs[key] = "[REDACTED]"
    return result


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        report = Campaign(config, args.config, args.checkpoint, args.out).run()
    except CampaignError as exc:
        print(f"campaign failed: {exc}", file=sys.stderr)
        return 2
    print(f"DSPY_INSTRUCTION_OPTIMIZER_REPORT={args.out.resolve()}")
    print(f"selected arm: {report['selected_arm']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
