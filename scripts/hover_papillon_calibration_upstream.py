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
import subprocess
import sys
import time
import types
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL = "gpt-4.1-mini-2025-04-14"
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


class Recorder:
    def __init__(self):
        self.active = None
        self.events = []
        self.actual_cost_usd = 0.0

    @contextlib.contextmanager
    def repetition(self, task, row, repetition):
        if self.active is not None:
            raise RuntimeError("DSPy calibration repetition already active")
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

    def record(self, messages, invoke):
        if not self.active:
            raise RuntimeError("DSPy execution exceeded active repetition schedule")
        item = self.active.pop(0)
        encoded = canonical_bytes(messages)
        if len(encoded) > item["max_input_bytes"]:
            raise RuntimeError(f"message byte cap exceeded for {item['id']}")
        reservation = item["max_input_bytes"] / 1_000_000 * 0.40 + 16384 / 1_000_000 * 1.60
        if self.actual_cost_usd + reservation > 5.00:
            raise RuntimeError("next transport would exceed $5.00")
        started = time.monotonic_ns()
        try:
            value = invoke()
            status, error = "ok", None
        except Exception as exc:
            status, error = "error", f"{type(exc).__name__}: {exc}"
            value = None
        event = {
            **event_identity(item),
            "model_requested": MODEL,
            "model_effective": MODEL,
            "provider": "openai",
            "request_id": "req-" + item["id"].replace("/", "-"),
            "timestamp_ns": time.time_ns(),
            "latency_us": (time.monotonic_ns() - started) // 1000,
            "status": status,
            "finish_reason": "stop" if status == "ok" else None,
            "message_sha256": hashlib.sha256(encoded).hexdigest(),
            "message_bytes": len(encoded),
            "message_serialization": "canonical_json_utf8_v1",
            "max_input_bytes": item["max_input_bytes"],
            "usage": {"input_tokens": 11, "output_tokens": 7, "cached_tokens": 0, "total_tokens": 18},
            "parse_status": status,
            "error": error,
            "transport_count": 1,
        }
        self.events.append(event)
        self.actual_cost_usd += 11 / 1_000_000 * 0.40 + 7 / 1_000_000 * 1.60
        if error:
            raise RuntimeError(error)
        return value


def event_identity(item):
    return {"opportunity_id": item["id"], "runtime": item["runtime"],
            **{key: item[key] for key in ("task", "row", "repetition", "stage", "max_input_bytes")}}


def run_provider_disabled(root: pathlib.Path, rows_path: pathlib.Path, artifact_root: pathlib.Path):
    if os.environ.get("OPENAI_API_KEY"):
        raise RuntimeError("provider-disabled mode refuses ambient OPENAI_API_KEY")
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
    recorder = Recorder()

    class TrackingDummy(DummyLM):
        def __call__(self, prompt=None, messages=None, **kwargs):
            messages = messages or [{"role": "user", "content": prompt}]
            return recorder.record(messages, lambda: super(TrackingDummy, self).__call__(prompt, messages, **kwargs))

    hover_answers = []
    for _ in range(6):
        hover_answers += [
            {"reasoning": "summarize", "summary": "Relevant evidence."},
            {"reasoning": "query", "query": "relevant evidence"},
            {"reasoning": "summarize", "summary": "Relevant evidence."},
            {"reasoning": "query", "query": "relevant evidence"},
        ]
    hover_lm = TrackingDummy(hover_answers)
    dspy.configure(lm=hover_lm, adapter=dspy.ChatAdapter(), track_usage=False)
    docs = [f"{title} | provider-disabled training passage" for title in ["The Dinner Party", "Sojourner Truth", "Barbe de Verrue", "Akira Yoshizawa", "Hirohito", "Wet-folding"]]
    hover_mod.search = lambda _query, k: hover_mod.DotDict({"passages": docs[:k]})
    hover_program = hover_mod.HoverMultiHop()
    hover_outcomes = []
    for row_id in ("H0", "H1"):
        for repetition in range(1, 4):
            with recorder.repetition("hover", row_id, repetition):
                prediction = hover_program(claim=rows[row_id]["inputs"]["claim"])
                titles = [doc.split(" | ", 1)[0] for doc in prediction.retrieved_docs]
                gold = [fact["key"] for fact in rows[row_id]["labels"]["supporting_facts"]]
                hover_outcomes.append({"row": row_id, "repetition": repetition, "retrieved_titles": titles, "all_gold_titles": all(title in titles for title in gold)})

    trusted_answers = []
    judge_answers = []
    for _ in range(4):
        trusted_answers += [
            {"reasoning": "redact", "llm_request": "Write a professional resume without personal identifiers."},
            {"response": "A professional resume."},
        ]
        judge_answers += [
            {"reasoning": "compare", "judgment": True},
            {"reasoning": "compare", "judgment": True},
            {"reasoning": "count", "num_pii_leaked": 0},
        ]
    trusted = TrackingDummy(trusted_answers)
    judge = TrackingDummy(judge_answers)

    class Untrusted:
        def __call__(self, prompt):
            return recorder.record([{"role": "user", "content": prompt}], lambda: ["external response"])

    pap_program = pap_mod.PAPILLON(Untrusted())
    pap_program.set_lm(trusted)
    pap_judge = pap_utils.LLMJudge()
    pap_judge.set_lm(judge)
    p0 = rows["P0"]
    papillon_outcomes = []
    for repetition in range(1, 5):
        with recorder.repetition("papillon", "P0", repetition):
            prediction = pap_program(user_query=p0["inputs"]["user_query"])
            if not prediction.llm_request and not prediction.response:
                papillon_outcomes.append({"row": "P0", "repetition": repetition, "error": "program_failed"})
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

    if recorder.active is not None or len(recorder.events) != 48:
        raise RuntimeError(f"DSPy schedule incomplete: {len(recorder.events)} of 48")
    path = root / "dspy.json"
    secure_json(
        path,
        {
            "mode": "provider_disabled",
            "runtime": "dspy",
            "imp_candidate": candidate,
            "authorities": AUTHORITIES,
            "dspy_commit": DSPY_COMMIT,
            "gepa_artifact_commit": GEPA_ARTIFACT_COMMIT,
            "outcomes": {"hover": hover_outcomes, "papillon": papillon_outcomes},
            "events": recorder.events,
        },
    )
    print(json.dumps({"status": "provider_disabled", "transports": 48}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider-disabled", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--materialize-pupa", action="store_true")
    parser.add_argument("--output-root", required=True, type=pathlib.Path)
    parser.add_argument("--rows", default=ROOT / "bench/imp/benchmark_truth/hover_papillon_calibration_rows.json", type=pathlib.Path)
    parser.add_argument("--artifact-root", default=ROOT / "tmp/gepa-artifact", type=pathlib.Path)
    args = parser.parse_args()
    if sum([args.provider_disabled, args.live, args.materialize_pupa]) != 1:
        raise SystemExit("choose exactly one mode")
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
        raise SystemExit("live execution is intentionally disabled until independent review grants provider authority")
    run_provider_disabled(args.output_root, args.rows, args.artifact_root)


if __name__ == "__main__":
    main()
