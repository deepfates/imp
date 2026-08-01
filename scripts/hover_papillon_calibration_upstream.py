#!/usr/bin/env python3
"""Provider-disabled stock-DSPy half of the fixed HoVer/PAPILLON pilot."""

from __future__ import annotations

import argparse
import csv
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import threading
import subprocess
import sys
import time
import types
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONDITION = "imp-88sn-hover-papillon-openrouter-calibration-v1"
MODEL = "deepseek/deepseek-v4-flash"
ENDPOINT_TAG = "novita/fp8"
ENDPOINT_NAME = "Novita | deepseek/deepseek-v4-flash-20260423"
ENDPOINT_PROVIDER = "Novita"
BASE_URL = "https://openrouter.ai/api/v1"
CATALOG_URL = f"{BASE_URL}/models/{MODEL}/endpoints"
ZDR_URL = f"{BASE_URL}/endpoints/zdr"
GENERATION_URL = f"{BASE_URL}/generation"
INPUT_PRICE = 0.14
OUTPUT_PRICE = 0.28
MAX_OUTPUT_TOKENS = 16384
HARD_COST_USD = 5.00
GENERATION_ATTEMPTS = 12
GENERATION_INTERVAL_SECONDS = 1.0
DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
GEPA_ARTIFACT_COMMIT = "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
HOVER_COMMIT = "c0e43052759879b3461642ca6c0dd26658f47691"
PUPA_COMMIT = "9981b49b6ced0033988a224b6712895ebf119294"
PUPA_SHA256 = "72d7659c717706bc987f0d296d9714f63db5e75c6645376ec75380e6638b8f91"
PUPA_CONVERSATION_HASH = "cc11b53c391f5b2c080838cc1b9edfb9"
PUPA_URL = f"https://huggingface.co/datasets/Columbia-NLP/PUPA/resolve/{PUPA_COMMIT}/PUPA_New.csv"
AUTHORITIES = {
    "gepa_artifact": GEPA_ARTIFACT_COMMIT,
    "hover": HOVER_COMMIT,
    "hover_train_sha256": "1f1cd57abd616fa00c70bdc575ce77c16fc6cf1a6cffd5ff87c208030a336bb6",
    "pupa": PUPA_COMMIT,
    "pupa_new_sha256": PUPA_SHA256,
}


def provider_preferences():
    return {
        "only": [ENDPOINT_TAG],
        "order": [ENDPOINT_TAG],
        "allow_fallbacks": False,
        "require_parameters": True,
        "data_collection": "deny",
        "zdr": True,
        "max_price": {"prompt": INPUT_PRICE, "completion": OUTPUT_PRICE},
    }


def live_lm_kwargs(api_key, api_base=BASE_URL):
    return {
        "model": f"openrouter/{MODEL}",
        "api_key": api_key,
        "api_base": api_base,
        "temperature": 1.0,
        "max_tokens": MAX_OUTPUT_TOKENS,
        "cache": False,
        "num_retries": 0,
        "timeout": 120,
        "reasoning_effort": "none",
        "headers": {
            "X-OpenRouter-Metadata": "enabled",
            "X-OpenRouter-Cache": "false",
        },
        "extra_body": {
            "provider": provider_preferences(),
            "usage": {"include": True},
        },
    }


def validate_catalog(payload):
    data = payload.get("data", {})
    if data.get("id") != MODEL:
        raise RuntimeError("OpenRouter catalog model drift")
    endpoint = next((item for item in data.get("endpoints", []) if item.get("tag") == ENDPOINT_TAG), None)
    if endpoint is None:
        raise RuntimeError("exact OpenRouter endpoint is absent")
    validate_endpoint(endpoint, "catalog")
    return {
        "checked_url": CATALOG_URL,
        "model": MODEL,
        "endpoint_tag": ENDPOINT_TAG,
        "endpoint_name": ENDPOINT_NAME,
        "provider": ENDPOINT_PROVIDER,
        "pricing": {"input_per_million": INPUT_PRICE, "output_per_million": OUTPUT_PRICE},
        "supported_parameters": endpoint.get("supported_parameters", []),
    }


def validate_endpoint(endpoint, label):
    expected = {
        "name": ENDPOINT_NAME,
        "provider_name": ENDPOINT_PROVIDER,
        "model_id": MODEL,
        "quantization": "fp8",
        "status": 0,
        "supports_implicit_caching": False,
    }
    for key, value in expected.items():
        if endpoint.get(key) != value:
            raise RuntimeError(f"OpenRouter {label} {key} drift")
    if endpoint.get("pricing", {}).get("prompt") != "0.00000014":
        raise RuntimeError(f"OpenRouter {label} input price drift")
    if endpoint.get("pricing", {}).get("completion") != "0.00000028":
        raise RuntimeError(f"OpenRouter {label} output price drift")
    supported = endpoint.get("supported_parameters", [])
    if not all(name in supported for name in ("reasoning_effort", "max_tokens", "temperature")):
        raise RuntimeError(f"OpenRouter {label} parameter support drift")
    return endpoint


def validate_zdr(payload):
    endpoints = payload.get("data", [])
    endpoint = next(
        (item for item in endpoints if item.get("tag") == ENDPOINT_TAG and item.get("model_id") == MODEL),
        None,
    )
    if endpoint is None:
        raise RuntimeError("exact endpoint is absent from ZDR catalog")
    validate_endpoint(endpoint, "ZDR catalog")
    return {
        "checked_url": ZDR_URL,
        "model": MODEL,
        "endpoint_tag": ENDPOINT_TAG,
        "endpoint_name": ENDPOINT_NAME,
        "provider": ENDPOINT_PROVIDER,
        "pricing": {"input_per_million": INPUT_PRICE, "output_per_million": OUTPUT_PRICE},
    }


def fetch_json(url, api_key=None):
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(f"read-only OpenRouter endpoint returned HTTP {response.status}")
        return json.loads(response.read())


def generation_metadata(generation_url, generation_id, api_key, attempts=GENERATION_ATTEMPTS,
                        sleep=time.sleep):
    if not isinstance(attempts, int) or attempts <= 0:
        raise RuntimeError("generation metadata attempts must be positive")
    for attempt in range(attempts):
        try:
            return validate_generation(
                fetch_json(f"{generation_url}?id={generation_id}", api_key), generation_id
            )
        except urllib.error.HTTPError as exc:
            if exc.code == 404 and attempt + 1 < attempts:
                sleep(GENERATION_INTERVAL_SECONDS)
                continue
            raise RuntimeError(f"OpenRouter generation metadata HTTP {exc.code}") from exc
    raise AssertionError("unreachable generation polling state")


def current_catalog():
    catalog = validate_catalog(fetch_json(CATALOG_URL))
    catalog["zdr"] = validate_zdr(fetch_json(ZDR_URL))
    return catalog


def field(value, name):
    if isinstance(value, dict):
        return value.get(name)
    return getattr(value, name, None)


def synthetic_router_metadata():
    return {
        "requested": MODEL,
        "strategy": "direct",
        "region": "provider-disabled",
        "summary": "available=1, selected=Novita",
        "attempt": 1,
        "is_byok": False,
        "endpoints": {"total": 1, "available": [{"model": MODEL, "provider": ENDPOINT_PROVIDER, "selected": True}]},
    }


def validate_router_metadata(metadata):
    if (
        not isinstance(metadata, dict)
        or metadata.get("requested") != MODEL
        or metadata.get("strategy") != "direct"
        or metadata.get("attempt") != 1
    ):
        raise RuntimeError("OpenRouter routing metadata missing or drifted")
    endpoints = metadata.get("endpoints", {})
    available = endpoints.get("available", [])
    if endpoints.get("total") != 1 or len(available) != 1:
        raise RuntimeError("OpenRouter routing metadata contains multiple endpoints")
    selected = [endpoint for endpoint in available if endpoint.get("selected") is True]
    if len(selected) != 1 or selected[0].get("model") != MODEL or selected[0].get("provider") != ENDPOINT_PROVIDER:
        raise RuntimeError("OpenRouter selected endpoint drift")
    return metadata


def admit_run(actual_cost_usd):
    if not isinstance(actual_cost_usd, (int, float)) or actual_cost_usd < 0:
        raise RuntimeError("initial attributable cost must be nonnegative")
    remaining = reservation()["unbuffered_usd"]
    if actual_cost_usd + remaining > HARD_COST_USD:
        raise RuntimeError(
            f"complete calibration would exceed $5.00: actual={actual_cost_usd} "
            f"remaining_reservation={remaining}"
        )


def validate_generation(payload, generation_id):
    data = payload.get("data", {})
    exact = {
        "id": generation_id,
        "model": MODEL,
        "provider_name": ENDPOINT_PROVIDER,
        "cancelled": False,
        "session_id": None,
        "native_tokens_cached": 0,
    }
    for key, value in exact.items():
        if data.get(key) != value:
            raise RuntimeError(f"OpenRouter generation {key} drift")
    if not data.get("request_id"):
        raise RuntimeError("OpenRouter request ID is missing")
    for key in ("native_tokens_prompt", "native_tokens_completion"):
        if not isinstance(data.get(key), int) or data[key] < 0:
            raise RuntimeError(f"OpenRouter generation {key} missing")
    if not isinstance(data.get("total_cost"), (int, float)) or data["total_cost"] < 0:
        raise RuntimeError("OpenRouter generation cost missing")
    return data


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def secure_json(path: pathlib.Path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, separators=(",", ":"), ensure_ascii=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def secure_evidence(root: pathlib.Path, state, opportunity_id, value):
    directory = root / "live-evidence" / state
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(root / "live-evidence", 0o700)
    os.chmod(directory, 0o700)
    secure_json(directory / (opportunity_id.replace("/", "__") + ".json"), value)


def materialize_pupa(root: pathlib.Path, rows_payload, source_path=None):
    if rows_payload.get("authorities") != AUTHORITIES:
        raise RuntimeError("calibration source authority mismatch")
    metadata = next(row for row in rows_payload["rows"] if row["id"] == "P0")
    if source_path:
        source = pathlib.Path(source_path).read_bytes()
    else:
        with urllib.request.urlopen(PUPA_URL, timeout=30) as response:
            source = response.read()
    if sha256(source) != PUPA_SHA256:
        raise RuntimeError("pinned PUPA train source checksum mismatch")
    row = next(csv.DictReader(io.StringIO(source.decode("utf-8-sig"))))
    if row["conversation_hash"] != PUPA_CONVERSATION_HASH:
        raise RuntimeError("pinned PUPA train row coordinate mismatch")
    payload = {
        "inputs": {"user_query": row["user_query"]},
        "labels": {"target_response": row["target_response"], "pii_str": row["pii_units"]},
    }
    if sha256(canonical_bytes(payload)) != metadata["private_payload_sha256"]:
        raise RuntimeError("pinned PUPA private row checksum mismatch")
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(root, 0o700)
    path = root / "pupa_train_row_0.json"
    secure_json(path, payload)
    return payload, path


def git_candidate_identity(expected_commit):
    if not expected_commit:
        raise RuntimeError("missing IMP_CALIBRATION_EXPECTED_COMMIT")
    actual = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    if actual != expected_commit:
        raise RuntimeError("Imp candidate commit mismatch")
    tracked = subprocess.run(["git", "-C", str(ROOT), "diff", "--quiet", "HEAD", "--"])
    if tracked.returncode != 0:
        raise RuntimeError("Imp candidate tracked tree is dirty")
    return {"commit": actual, "tracked_clean": True}


def load_source_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def load_programs(artifact_root: pathlib.Path):
    # Load the exact released source files without importing their dataset
    # package __init__ modules (which would load non-training splits).
    packages = [
        "gepa_artifact",
        "gepa_artifact.benchmarks",
        "gepa_artifact.benchmarks.hover",
        "gepa_artifact.benchmarks.papillon",
    ]
    for name in packages:
        module = types.ModuleType(name)
        module.__path__ = []
        sys.modules[name] = module

    load_source_module(
        "gepa_artifact.benchmarks.dspy_program",
        artifact_root / "gepa_artifact/benchmarks/dspy_program.py",
    )

    # The provider-disabled calibration replaces retrieval with a deterministic
    # in-memory function; these import shims prevent corpus initialization only.
    bm25s = types.ModuleType("bm25s")
    bm25s.BM25 = object
    bm25s.tokenize = lambda *args, **kwargs: []
    sys.modules["bm25s"] = bm25s
    stemmer = types.ModuleType("Stemmer")
    stemmer.Stemmer = lambda *_args, **_kwargs: None
    sys.modules["Stemmer"] = stemmer

    hover = load_source_module(
        "gepa_artifact.benchmarks.hover.hover_program",
        artifact_root / "gepa_artifact/benchmarks/hover/hover_program.py",
    )
    papillon = load_source_module(
        "gepa_artifact.benchmarks.papillon.papillon_program",
        artifact_root / "gepa_artifact/benchmarks/papillon/papillon_program.py",
    )
    utils = load_source_module(
        "gepa_artifact.benchmarks.papillon.papillon_utils",
        artifact_root / "gepa_artifact/benchmarks/papillon/papillon_utils.py",
    )
    return hover, papillon, utils


def schedule(runtime="dspy"):
    hover = [("summarize1", 65536), ("query2", 8192), ("summarize2", 65536), ("query3", 16384)]
    pap = [("rewrite", 16384), ("untrusted", 8192), ("response", 32768), ("quality_ab", 32768), ("quality_ba", 32768), ("leakage", 16384)]
    groups = [("hover", row, range(1, 4), hover) for row in ("H0", "H1")]
    groups.append(("papillon", "P0", range(1, 5), pap))
    return [opportunity(runtime, task, row, rep, stage, cap)
            for task, row, reps, stages in groups for rep in reps for stage, cap in stages]


def opportunity(runtime, task, row, repetition, stage, cap):
    return {
        "id": f"{runtime}/{task}/{row}/r{repetition}/{stage}",
        "runtime": runtime,
        "task": task,
        "row": row,
        "repetition": repetition,
        "stage": stage,
        "max_input_bytes": cap,
    }


def reservation():
    opportunities = schedule("imp") + schedule("dspy")
    input_tokens = sum(item["max_input_bytes"] for item in opportunities)
    output_tokens = len(opportunities) * MAX_OUTPUT_TOKENS
    unbuffered = input_tokens / 1_000_000 * INPUT_PRICE + output_tokens / 1_000_000 * OUTPUT_PRICE
    return {
        "opportunities": len(opportunities),
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "unbuffered_usd": unbuffered,
    }


class CalibrationOperationalAbort(RuntimeError):
    """Fatal transport, route, cost, identity, or evidence failure."""


class Recorder:
    def __init__(self, mode="provider_disabled", api_key=None, initial_actual_cost_usd=0.0,
                 generation_url=GENERATION_URL, evidence_root=None,
                 generation_attempts=GENERATION_ATTEMPTS, generation_sleep=time.sleep):
        self.mode = mode
        self.api_key = api_key
        self.generation_url = generation_url
        self.evidence_root = evidence_root
        self.generation_attempts = generation_attempts
        self.generation_sleep = generation_sleep
        self.active = None
        self.events = []
        self.actual_cost_usd = initial_actual_cost_usd

    @contextlib.contextmanager
    def repetition(self, task, row, repetition):
        if self.active is not None:
            raise CalibrationOperationalAbort("DSPy calibration repetition already active")
        self.active = [
            item
            for item in schedule()
            if item["task"] == task and item["row"] == row and item["repetition"] == repetition
        ]
        try:
            yield
        finally:
            for item in self.active:
                self.events.append({**event_identity(item), "status": "skipped",
                                    "skip_reason": "prior_stage_failed", "usage": {},
                                    "transport_count": 0})
            self.active = None

    def mark_ordinary_failure(self, task, row, repetition, failure):
        event = next(
            (
                item
                for item in reversed(self.events)
                if item.get("task") == task
                and item.get("row") == row
                and item.get("repetition") == repetition
                and item.get("transport_count") == 1
            ),
            None,
        )
        if event is None or event.get("status") != "ok":
            raise CalibrationOperationalAbort("ordinary failure cannot be bound to an exact stage")
        diagnostic = {
            "type": type(failure).__name__ if isinstance(failure, BaseException) else str(failure),
            "reason": "redacted ordinary DSPy program/adapter failure",
        }
        event["parse_status"] = "error"
        event["error"] = diagnostic
        return diagnostic

    def record(self, messages, invoke, history=None):
        if not self.active:
            raise CalibrationOperationalAbort("DSPy execution exceeded active repetition schedule")
        item = self.active.pop(0)
        encoded = canonical_bytes(messages)
        if len(encoded) > item["max_input_bytes"]:
            raise CalibrationOperationalAbort(f"message byte cap exceeded for {item['id']}")
        reservation = item["max_input_bytes"] / 1_000_000 * INPUT_PRICE + MAX_OUTPUT_TOKENS / 1_000_000 * OUTPUT_PRICE
        if self.actual_cost_usd + reservation > HARD_COST_USD:
            raise CalibrationOperationalAbort("next transport would exceed $5.00")
        started = time.monotonic_ns()
        try:
            value = invoke()
        except Exception as exc:
            raise CalibrationOperationalAbort("DSPy LM transport/runtime failed") from exc
        try:
            live = self._live_metadata(history, item, encoded, started) if self.mode == "live" else self._synthetic_metadata(item)
        except CalibrationOperationalAbort:
            raise
        except Exception as exc:
            raise CalibrationOperationalAbort("DSPy live evidence reconciliation failed") from exc
        event = {
            **event_identity(item),
            "model_requested": MODEL,
            "model_effective": live["model_effective"],
            "provider": "openrouter",
            "upstream_provider": live["upstream_provider"],
            "endpoint_tag": ENDPOINT_TAG,
            "request_id": live["request_id"],
            "generation_id": live["generation_id"],
            "timestamp_ns": time.time_ns(),
            "latency_us": (time.monotonic_ns() - started) // 1000,
            "status": "ok",
            "finish_reason": live["finish_reason"],
            "message_sha256": hashlib.sha256(encoded).hexdigest(),
            "message_bytes": len(encoded),
            "message_serialization": "canonical_json_utf8_v1",
            "max_input_bytes": item["max_input_bytes"],
            "usage": live["usage"],
            "router_metadata": live["router_metadata"],
            "parse_status": "ok",
            "error": None,
            "transport_count": 1,
        }
        if self.mode == "live" and self.evidence_root is not None:
            secure_evidence(self.evidence_root, "reconciled", item["id"], event)
        self.events.append(event)
        self.actual_cost_usd += live["usage"]["input_tokens"] / 1_000_000 * INPUT_PRICE + live["usage"]["output_tokens"] / 1_000_000 * OUTPUT_PRICE
        return value

    def _synthetic_metadata(self, item):
        generation_id = "gen-" + item["id"].replace("/", "-")
        router = synthetic_router_metadata()
        return {
            "model_effective": MODEL,
            "upstream_provider": ENDPOINT_PROVIDER,
            "request_id": "req-" + item["id"].replace("/", "-"),
            "generation_id": generation_id,
            "finish_reason": "stop",
            "usage": {"input_tokens": 11, "output_tokens": 7, "cached_tokens": 0, "total_tokens": 18,
                      "provider_cost_usd": 11 / 1_000_000 * INPUT_PRICE + 7 / 1_000_000 * OUTPUT_PRICE},
            "router_metadata": router,
        }

    def _live_metadata(self, history, item, encoded, started):
        if not history:
            raise RuntimeError("DSPy live response history is missing")
        entry = history[-1]
        response = entry.get("response")
        generation_id = field(response, "id")
        model_effective = field(response, "model")
        usage = field(response, "usage") or {}
        details = field(usage, "prompt_tokens_details") or {}
        cached = field(details, "cached_tokens")
        input_tokens = field(usage, "prompt_tokens")
        output_tokens = field(usage, "completion_tokens")
        total_tokens = field(usage, "total_tokens")
        router = field(response, "openrouter_metadata")
        choices = field(response, "choices") or []
        finish_reason = field(choices[0], "finish_reason") if choices else None
        validate_router_metadata(router)
        if not generation_id or not model_effective:
            raise RuntimeError("OpenRouter response identity is missing")
        if not all(isinstance(value, int) and value >= 0 for value in (input_tokens, output_tokens, total_tokens, cached)):
            raise RuntimeError("OpenRouter response usage is missing")
        if total_tokens != input_tokens + output_tokens or cached != 0:
            raise RuntimeError("OpenRouter response usage/cache drift")
        if self.evidence_root is not None:
            secure_evidence(
                self.evidence_root,
                "provisional",
                item["id"],
                {
                    "condition": CONDITION,
                    "state": "response_received_reconciliation_pending",
                    **event_identity(item),
                    "generation_id": generation_id,
                    "model_effective": model_effective,
                    "usage_reported": {
                        "input_tokens": input_tokens,
                        "output_tokens": output_tokens,
                        "cached_tokens": cached,
                        "total_tokens": total_tokens,
                    },
                    "router_metadata": router,
                    "finish_reason": finish_reason,
                    "message_sha256": hashlib.sha256(encoded).hexdigest(),
                    "message_bytes": len(encoded),
                    "message_serialization": "canonical_json_utf8_v1",
                    "latency_us": (time.monotonic_ns() - started) // 1000,
                    "timestamp_ns": time.time_ns(),
                    "transport_count": 1,
                },
            )
        generation = generation_metadata(
            self.generation_url,
            generation_id,
            self.api_key,
            attempts=self.generation_attempts,
            sleep=self.generation_sleep,
        )
        if generation["native_tokens_prompt"] != input_tokens or generation["native_tokens_completion"] != output_tokens:
            raise RuntimeError("OpenRouter generation usage disagrees with response usage")
        expected_cost = input_tokens / 1_000_000 * INPUT_PRICE + output_tokens / 1_000_000 * OUTPUT_PRICE
        if abs(generation["total_cost"] - expected_cost) > 1e-9:
            raise RuntimeError("OpenRouter billed cost disagrees with frozen prices")
        return {
            "model_effective": model_effective,
            "upstream_provider": generation["provider_name"],
            "request_id": generation["request_id"],
            "generation_id": generation_id,
            "finish_reason": finish_reason,
            "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens,
                      "cached_tokens": cached, "total_tokens": total_tokens,
                      "provider_cost_usd": generation["total_cost"]},
            "router_metadata": router,
        }


def event_identity(item):
    return {"opportunity_id": item["id"], "runtime": item["runtime"],
            **{key: item[key] for key in ("task", "row", "repetition", "stage", "max_input_bytes")}}


def tracking_live_class(dspy, recorder):
    class TrackingLive(dspy.LM):
        def __call__(self, prompt=None, messages=None, **kwargs):
            messages = messages or [{"role": "user", "content": prompt}]
            return recorder.record(
                messages,
                lambda: super(TrackingLive, self).__call__(prompt=prompt, messages=messages, **kwargs),
                self.history,
            )

    return TrackingLive


def verify_live_transport_offline(dspy_root, output_root):
    requests = []
    generation_gets = {"normal": 0, "terminal": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            body = json.loads(self.rfile.read(length))
            requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
            payload = {
                "id": "gen-offline-live",
                "object": "chat.completion",
                "model": MODEL,
                "provider": ENDPOINT_PROVIDER,
                "openrouter_metadata": synthetic_router_metadata(),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "offline"},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18,
                          "prompt_tokens_details": {"cached_tokens": 0}},
            }
            encoded = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            if self.path.startswith("/api/v1/terminal-generation"):
                generation_gets["terminal"] += 1
                self.send_error(404)
                return
            if not self.path.startswith("/api/v1/generation?id=gen-offline-live"):
                self.send_error(404)
                return
            generation_gets["normal"] += 1
            if generation_gets["normal"] == 1:
                self.send_error(404)
                return
            payload = {"data": {"id": "gen-offline-live", "model": MODEL,
                       "provider_name": ENDPOINT_PROVIDER, "cancelled": False, "session_id": None,
                       "request_id": "req-offline-live", "native_tokens_prompt": 11,
                       "native_tokens_completion": 7, "native_tokens_cached": 0,
                       "total_cost": 11 / 1_000_000 * INPUT_PRICE + 7 / 1_000_000 * OUTPUT_PRICE}}
            encoded = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        output_root.mkdir(mode=0o700, parents=True, exist_ok=False)
        os.chmod(output_root, 0o700)
        sys.path.insert(0, str(dspy_root))
        import dspy

        if not pathlib.Path(dspy.__file__).resolve().is_relative_to(dspy_root.resolve()):
            raise RuntimeError("offline transport did not import pinned DSPy")
        base_url = f"http://127.0.0.1:{server.server_port}/api/v1"
        item = opportunity("dspy", "hover", "H0", 1, "query2", 8192)
        recorder = Recorder(
            "live",
            "offline-key",
            generation_url=f"{base_url}/generation",
            evidence_root=output_root,
            generation_attempts=3,
            generation_sleep=lambda _seconds: None,
        )
        recorder.active = [item]
        config = live_lm_kwargs("offline-key", base_url)
        model = config.pop("model")
        TrackingLive = tracking_live_class(dspy, recorder)
        lm = TrackingLive(model, **config)
        if lm.cache is not False or lm.num_retries != 0:
            raise RuntimeError("DSPy cache/retry configuration drift")
        result = lm(messages=[{"role": "user", "content": "offline transport assertion"}])
        if result != ["offline"] or len(requests) != 1 or len(recorder.events) != 1:
            raise RuntimeError("offline TrackingLive execution drift")
        request = requests[0]
        body = request["body"]
        headers = {key.lower(): value for key, value in request["headers"].items()}
        expected = {
            "model": MODEL,
            "temperature": 1.0,
            "max_tokens": MAX_OUTPUT_TOKENS,
            "reasoning_effort": "none",
            "provider": provider_preferences(),
            "usage": {"include": True},
        }
        for key, value in expected.items():
            if body.get(key) != value:
                raise RuntimeError(f"LiteLLM serialized {key} drift")
        if body.get("session_id") is not None or body.get("store") is not None:
            raise RuntimeError("LiteLLM serialized state/storage drift")
        if headers.get("x-openrouter-metadata") != "enabled":
            raise RuntimeError("LiteLLM router metadata header drift")
        if headers.get("x-openrouter-cache") != "false":
            raise RuntimeError("LiteLLM response-cache header drift")
        if request["path"] != "/api/v1/chat/completions":
            raise RuntimeError("LiteLLM OpenRouter path drift")
        provisional = list((output_root / "live-evidence" / "provisional").glob("*.json"))
        reconciled = list((output_root / "live-evidence" / "reconciled").glob("*.json"))
        if len(provisional) != 1 or len(reconciled) != 1 or generation_gets["normal"] != 2:
            raise RuntimeError("delayed generation reconciliation evidence drift")

        terminal = Recorder(
            "live",
            "offline-key",
            generation_url=f"{base_url}/terminal-generation",
            evidence_root=output_root,
            generation_attempts=3,
            generation_sleep=lambda _seconds: None,
        )
        first = opportunity("dspy", "hover", "H0", 1, "query3", 16384)
        second = opportunity("dspy", "hover", "H0", 2, "summarize1", 65536)
        terminal.active = [first, second]
        terminal_response = {
            "id": "gen-terminal-live",
            "model": MODEL,
            "openrouter_metadata": synthetic_router_metadata(),
            "choices": [{"finish_reason": "stop"}],
            "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18,
                      "prompt_tokens_details": {"cached_tokens": 0}},
        }
        invocations = {"count": 0}

        def terminal_invoke():
            invocations["count"] += 1
            return ["terminal"]

        try:
            terminal.record(
                [{"role": "user", "content": "terminal reconciliation assertion"}],
                terminal_invoke,
                [{"response": terminal_response}],
            )
            raise RuntimeError("terminal generation 404 unexpectedly reconciled")
        except CalibrationOperationalAbort as exc:
            if "live evidence reconciliation failed" not in str(exc):
                raise
        terminal_files = list((output_root / "live-evidence" / "provisional").glob("*.json"))
        if (
            invocations["count"] != 1
            or generation_gets["terminal"] != 3
            or len(terminal.active) != 1
            or terminal.events
            or len(terminal_files) != 2
        ):
            raise RuntimeError("terminal generation 404 advanced the fixed schedule")

        return {
            "status": "offline_live_transport_verified",
            "transports": 1,
            "generation_404_then_200_attempts": generation_gets["normal"],
            "terminal_404_attempts": generation_gets["terminal"],
            "terminal_next_stage_transports": 0,
        }
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        shutil.rmtree(output_root, ignore_errors=True)


def run_calibration(root: pathlib.Path, rows_path: pathlib.Path, artifact_root: pathlib.Path,
                    mode="provider_disabled", catalog=None):
    if mode == "provider_disabled" and (os.environ.get("OPENAI_API_KEY") or os.environ.get("OPENROUTER_API_KEY")):
        raise RuntimeError("provider-disabled mode refuses ambient provider API keys")
    if mode == "live":
        live_preflight()
        if (
            not isinstance(catalog, dict)
            or catalog.get("model") != MODEL
            or catalog.get("endpoint_tag") != ENDPOINT_TAG
            or catalog.get("endpoint_name") != ENDPOINT_NAME
            or catalog.get("provider") != ENDPOINT_PROVIDER
            or catalog.get("pricing") != {"input_per_million": INPUT_PRICE, "output_per_million": OUTPUT_PRICE}
            or catalog.get("zdr", {}).get("model") != MODEL
            or catalog.get("zdr", {}).get("endpoint_tag") != ENDPOINT_TAG
            or catalog.get("zdr", {}).get("endpoint_name") != ENDPOINT_NAME
            or catalog.get("zdr", {}).get("provider") != ENDPOINT_PROVIDER
        ):
            raise RuntimeError("catalog binding drift")
    initial_actual_cost_usd = float(os.environ.get("IMP_CALIBRATION_INITIAL_COST_USD", "0"))
    admit_run(initial_actual_cost_usd)
    rows_payload = json.loads(rows_path.read_text())
    assert rows_payload["derivation"]["heldout_loaded"] is False
    if rows_payload.get("authorities") != AUTHORITIES:
        raise RuntimeError("calibration source authority mismatch")
    candidate = git_candidate_identity(os.environ.get("IMP_CALIBRATION_EXPECTED_COMMIT"))
    assert subprocess.check_output(["git", "-C", str(artifact_root), "rev-parse", "HEAD"], text=True).strip() == GEPA_ARTIFACT_COMMIT
    dspy_root = pathlib.Path(os.environ.get("IMP_CALIBRATION_DSPY_ROOT", ROOT / "tmp/dspy-3.2.1"))
    assert subprocess.check_output(["git", "-C", str(dspy_root), "rev-parse", "HEAD"], text=True).strip() == DSPY_COMMIT
    sys.path.insert(0, str(dspy_root))
    import dspy
    from dspy.utils.dummies import DummyLM

    assert pathlib.Path(dspy.__file__).resolve().is_relative_to(dspy_root.resolve())
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(root, 0o700)
    pupa, _private_path = materialize_pupa(
        root / "private",
        rows_payload,
        os.environ.get("IMP_CALIBRATION_PUPA_SOURCE"),
    )
    rows = {row["id"]: row for row in rows_payload["rows"]}
    rows["P0"] = {**rows["P0"], **pupa}

    hover_mod, pap_mod, pap_utils = load_programs(artifact_root)
    api_key = os.environ.get("OPENROUTER_API_KEY") if mode == "live" else None
    fail_on = set(filter(None, os.environ.get("IMP_CALIBRATION_DSPY_FAIL_ON", "").split(",")))
    if mode == "live" and fail_on:
        raise RuntimeError("live calibration refuses provider-disabled failure injection")
    recorder = Recorder(
        mode,
        api_key,
        initial_actual_cost_usd,
        evidence_root=root if mode == "live" else None,
    )

    class TrackingDummy(DummyLM):
        def __init__(self, answers_by_opportunity):
            super().__init__([])
            self.answers_by_opportunity = answers_by_opportunity

        def __call__(self, prompt=None, messages=None, **kwargs):
            messages = messages or [{"role": "user", "content": prompt}]
            if not recorder.active:
                raise CalibrationOperationalAbort("provider-disabled answer requested outside repetition")
            opportunity_id = recorder.active[0]["id"]
            if opportunity_id not in self.answers_by_opportunity:
                raise CalibrationOperationalAbort(f"missing provider-disabled answer for {opportunity_id}")
            dummy = DummyLM([self.answers_by_opportunity[opportunity_id]])
            return recorder.record(messages, lambda: dummy(prompt=prompt, messages=messages, **kwargs))

    if mode == "live":
        config = live_lm_kwargs(api_key)
        model = config.pop("model")
        TrackingLive = tracking_live_class(dspy, recorder)
        shared_lm = TrackingLive(model, **config)
        if shared_lm.cache is not False or shared_lm.num_retries != 0:
            raise RuntimeError("DSPy cache/retry configuration drift")
    else:
        shared_lm = None

    def answer(opportunity_id, value):
        return {"reasoning": "intentionally malformed"} if opportunity_id in fail_on else value

    hover_answers = {}
    hover_values = [
        ("summarize1", {"reasoning": "summarize", "summary": "Relevant evidence."}),
        ("query2", {"reasoning": "query", "query": "relevant evidence"}),
        ("summarize2", {"reasoning": "summarize", "summary": "Relevant evidence."}),
        ("query3", {"reasoning": "query", "query": "relevant evidence"}),
    ]
    for row_id in ("H0", "H1"):
        for repetition in range(1, 4):
            for stage, value in hover_values:
                opportunity_id = f"dspy/hover/{row_id}/r{repetition}/{stage}"
                hover_answers[opportunity_id] = answer(opportunity_id, value)
    hover_lm = shared_lm or TrackingDummy(hover_answers)
    dspy.configure(
        lm=hover_lm,
        adapter=dspy.ChatAdapter(use_json_adapter_fallback=False),
        track_usage=False,
    )
    docs = [f"{title} | provider-disabled training passage" for title in ["The Dinner Party", "Sojourner Truth", "Barbe de Verrue", "Akira Yoshizawa", "Hirohito", "Wet-folding"]]
    hover_mod.search = lambda _query, k: hover_mod.DotDict({"passages": docs[:k]})
    hover_program = hover_mod.HoverMultiHop()
    hover_outcomes = []
    for row_id in ("H0", "H1"):
        for repetition in range(1, 4):
            try:
                with recorder.repetition("hover", row_id, repetition):
                    prediction = hover_program(claim=rows[row_id]["inputs"]["claim"])
                    titles = [doc.split(" | ", 1)[0] for doc in prediction.retrieved_docs]
                    gold = [fact["key"] for fact in rows[row_id]["labels"]["supporting_facts"]]
                    hover_outcomes.append({"row": row_id, "repetition": repetition, "retrieved_titles": titles, "all_gold_titles": all(title in titles for title in gold)})
            except CalibrationOperationalAbort:
                raise
            except Exception as exc:
                diagnostic = recorder.mark_ordinary_failure("hover", row_id, repetition, exc)
                hover_outcomes.append({"row": row_id, "repetition": repetition, "error": diagnostic})

    trusted_answers = {}
    judge_answers = {}
    for repetition in range(1, 5):
        rewrite_id = f"dspy/papillon/P0/r{repetition}/rewrite"
        response_id = f"dspy/papillon/P0/r{repetition}/response"
        quality_ab_id = f"dspy/papillon/P0/r{repetition}/quality_ab"
        quality_ba_id = f"dspy/papillon/P0/r{repetition}/quality_ba"
        leakage_id = f"dspy/papillon/P0/r{repetition}/leakage"
        trusted_answers[rewrite_id] = answer(
            rewrite_id,
            {"reasoning": "redact", "llm_request": "Write a professional resume without personal identifiers."},
        )
        trusted_answers[response_id] = answer(response_id, {"response": "A professional resume."})
        judge_answers[quality_ab_id] = answer(
            quality_ab_id, {"reasoning": "compare", "judgment": True}
        )
        judge_answers[quality_ba_id] = answer(
            quality_ba_id, {"reasoning": "compare", "judgment": True}
        )
        judge_answers[leakage_id] = answer(
            leakage_id, {"reasoning": "count", "num_pii_leaked": 0}
        )
    trusted = shared_lm or TrackingDummy(trusted_answers)
    judge = shared_lm or TrackingDummy(judge_answers)

    class Untrusted:
        def __call__(self, prompt):
            messages = [{"role": "user", "content": prompt}]
            if mode == "live":
                return shared_lm(prompt=prompt, messages=messages)
            return recorder.record(messages, lambda: ["external response"])

    pap_program = pap_mod.PAPILLON(Untrusted())
    pap_program.set_lm(trusted)
    pap_judge = pap_utils.LLMJudge()
    pap_judge.set_lm(judge)
    p0 = rows["P0"]
    papillon_outcomes = []
    for repetition in range(1, 5):
        try:
            with recorder.repetition("papillon", "P0", repetition):
                prediction = pap_program(user_query=p0["inputs"]["user_query"])
                if not prediction.llm_request and not prediction.response:
                    diagnostic = recorder.mark_ordinary_failure(
                        "papillon", "P0", repetition, "program_failed"
                    )
                    papillon_outcomes.append(
                        {"row": "P0", "repetition": repetition, "error": diagnostic}
                    )
                    continue
                quality_ab = bool(
                    pap_judge.quality_judge(
                        user_query=p0["inputs"]["user_query"],
                        response_A=prediction.response,
                        response_B=p0["labels"]["target_response"],
                    ).judgment
                )
                quality_ba = bool(
                    pap_judge.quality_judge(
                        user_query=p0["inputs"]["user_query"],
                        response_A=p0["labels"]["target_response"],
                        response_B=prediction.response,
                    ).judgment
                )
                pii = list(set(p0["labels"]["pii_str"].split("||")))
                leakage_numerator = int(
                    pap_judge.fact_checker(pii=pii, prompt=prediction.llm_request).num_pii_leaked
                )
                leakage_denominator = len(pii)
                quality = quality_ab or quality_ab == quality_ba
                leakage = leakage_numerator / leakage_denominator if leakage_denominator else 0.0
                score = (float(quality) + (1.0 - leakage)) / 2.0
                papillon_outcomes.append(
                    {
                        "row": "P0",
                        "repetition": repetition,
                        "quality_ab": quality_ab,
                        "quality_ba": quality_ba,
                        "quality": quality,
                        "leakage_numerator": leakage_numerator,
                        "leakage_denominator": leakage_denominator,
                        "leakage": leakage,
                        "score": score,
                    }
                )
        except CalibrationOperationalAbort:
            raise
        except Exception as exc:
            diagnostic = recorder.mark_ordinary_failure("papillon", "P0", repetition, exc)
            papillon_outcomes.append({"row": "P0", "repetition": repetition, "error": diagnostic})

    if recorder.active is not None or len(recorder.events) != 48:
        raise RuntimeError(f"DSPy schedule incomplete: {len(recorder.events)} of 48")
    path = root / "dspy.json"
    secure_json(
        path,
        {
            "condition": CONDITION,
            "mode": mode,
            "runtime": "dspy",
            "imp_candidate": candidate,
            "authorities": AUTHORITIES,
            "dspy_commit": DSPY_COMMIT,
            "gepa_artifact_commit": GEPA_ARTIFACT_COMMIT,
            "catalog": catalog,
            "request_contract": {key: value for key, value in live_lm_kwargs("[REDACTED]").items() if key != "api_key"},
            "outcomes": {"hover": hover_outcomes, "papillon": papillon_outcomes},
            "events": recorder.events,
        },
    )
    print(json.dumps({
        "status": mode,
        "opportunities": len(recorder.events),
        "transports": sum(event["transport_count"] for event in recorder.events),
    }))


def live_preflight():
    if os.environ.get("IMP_CALIBRATION_MODE") != "live":
        raise RuntimeError("live mode environment drift")
    if not os.environ.get("OPENROUTER_API_KEY"):
        raise RuntimeError("missing OpenRouter API key")
    if os.environ.get("OPENAI_API_KEY"):
        raise RuntimeError("OpenRouter calibration refuses ambient OPENAI_API_KEY")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider-disabled", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--materialize-pupa", action="store_true")
    parser.add_argument("--verify-live-transport", action="store_true")
    parser.add_argument("--output-root", required=True, type=pathlib.Path)
    parser.add_argument("--rows", default=ROOT / "bench/imp/benchmark_truth/hover_papillon_calibration_rows.json", type=pathlib.Path)
    parser.add_argument("--artifact-root", default=ROOT / "tmp/gepa-artifact", type=pathlib.Path)
    args = parser.parse_args()
    if sum([args.provider_disabled, args.live, args.materialize_pupa, args.verify_live_transport]) != 1:
        raise SystemExit("choose exactly one mode")
    if args.verify_live_transport:
        dspy_root = pathlib.Path(os.environ.get("IMP_CALIBRATION_DSPY_ROOT", ROOT / "tmp/dspy-3.2.1"))
        print(json.dumps(verify_live_transport_offline(dspy_root, args.output_root)))
        return
    if args.materialize_pupa:
        rows_payload = json.loads(args.rows.read_text())
        materialize_pupa(
            args.output_root,
            rows_payload,
            os.environ.get("IMP_CALIBRATION_PUPA_SOURCE"),
        )
        print(json.dumps({"status": "materialized_private_pupa"}))
        return
    if args.live:
        catalog = current_catalog()
        run_calibration(args.output_root, args.rows, args.artifact_root, "live", catalog)
        return
    run_calibration(args.output_root, args.rows, args.artifact_root)


if __name__ == "__main__":
    main()
