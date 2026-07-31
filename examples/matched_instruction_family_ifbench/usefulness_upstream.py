#!/usr/bin/env python3
"""Thin stock-DSPy+GEPA reference for the frozen imp-88sn IFBench condition."""

from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import sys


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SEEDS = [2026072705, 2026072706, 2026072707]
SPLIT_SHA = {
    "train": "8d80f329bbab37a44fe2e2ea0ea8c7e69eeb976d8a8e51af5bcd4547b4221197",
    "selection": "f0c2d8e808e4783e496ecf189ead61fde4a1e80373ff85f3ea801883f68c7468",
    "test": "49779533faa842decda93a1221ce7bae615af82403e33e380ab69d2abc84610d",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_write(path: Path, content: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def install_runtime():
    sys.path.append(
        str(ROOT / "tmp/ifbench-parity-venv/lib/python3.13/site-packages")
    )
    sys.path.insert(0, str(ROOT / "scripts"))
    from dspy_gepa_version_bridge import install_source_bridge, authenticate_loaded_runtime

    bridge = install_source_bridge(ROOT / "tmp/dspy-3.2.1", ROOT / "tmp/gepa-v0.1.4")
    import dspy
    import gepa

    identity = authenticate_loaded_runtime(bridge, dspy, gepa)
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))
    import spacy.cli

    # The pinned artifact invokes the package installer at import time even
    # when its declared language model is already present. Keep scoring intact
    # while making this ordinary invocation provider/network-free until live.
    spacy.cli.download = lambda *_args, **_kwargs: None
    sys.path.insert(0, str(ROOT / "tmp/gepa-artifact"))
    sys.path.insert(0, str(ROOT / "examples/matched_gepa_mipro_ifbench_gepa014"))
    from dspy_gepa_failure_compat import patched_dspy_gepa
    from ifbench_stock_module import IFBenchCoT2StageModule
    from gepa_artifact.benchmarks.IFBench.ifbench_metric import (
        metric as scalar_metric,
        metric_with_feedback,
    )

    return dspy, identity, patched_dspy_gepa, IFBenchCoT2StageModule, scalar_metric, metric_with_feedback


def rows(split: str, allow_test: bool = False) -> list[dict]:
    if split == "test" and not allow_test:
        raise RuntimeError("held-out rows are unavailable before artifact selection")
    path = HERE / "data" / ("held_out.jsonl" if split == "test" else f"{split}.jsonl")
    if sha256(path) != SPLIT_SHA[split]:
        raise RuntimeError(f"{split} digest drift")
    return [json.loads(line) for line in path.read_text().splitlines()]


def examples(dspy, source: list[dict], feedback_allowed: bool):
    return [
        dspy.Example(
            prompt=row["prompt"],
            instruction_id_list=copy.deepcopy(row["instruction_id_list"]),
            kwargs=copy.deepcopy(row["kwargs"]),
            feedback_allowed=feedback_allowed,
            source_id=row["source_id"],
        ).with_inputs("prompt")
        for row in source
    ]


def openrouter_body(provider: str, prompt_price: float, completion_price: float) -> dict:
    return {
        "provider": {
            "only": [provider],
            "order": [provider],
            "allow_fallbacks": False,
            "require_parameters": True,
            "data_collection": "deny",
            "max_price": {
                "prompt": prompt_price,
                "completion": completion_price,
                "request": 0,
            },
        },
        "usage": {"include": True},
    }


def lms(dspy, seed: int):
    key = os.environ["OPENROUTER_API_KEY"]
    task = dspy.LM(
        "openrouter/openai/gpt-5.4-mini",
        api_key=key,
        cache=False,
        max_tokens=2048,
        num_retries=0,
        timeout=120,
        seed=seed,
        extra_body=openrouter_body("openai", 0.75, 4.5),
    )
    reflection = dspy.LM(
        "openrouter/anthropic/claude-sonnet-4.6",
        api_key=key,
        cache=False,
        max_tokens=1024,
        num_retries=0,
        timeout=120,
        temperature=1,
        extra_body=openrouter_body("anthropic", 3, 15),
    )
    return task, reflection


def semantic_metric(dspy, metric_with_feedback):
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


def optimizer(dspy, metric, reflection_lm, seed: int):
    return dspy.GEPA(
        metric=metric,
        max_metric_calls=80,
        reflection_minibatch_size=8,
        candidate_selection_strategy="pareto",
        reflection_lm=reflection_lm,
        component_selector="round_robin",
        use_merge=False,
        num_threads=1,
        failure_score=0.0,
        track_stats=True,
        seed=seed,
        gepa_kwargs={"acceptance_criterion": "strict_improvement"},
    )


def evaluate(program, dspy, source, scalar_metric):
    output = []
    for row, example in zip(source, examples(dspy, source, False), strict=True):
        error = None
        try:
            prediction = program(prompt=row["prompt"])
            actual = getattr(prediction, "response", None)
            score = float(scalar_metric(example, prediction))
        except Exception as exc:  # retained diagnostic failure, not reflection advice
            actual, score = None, 0.0
            error = {"type": type(exc).__name__, "message": str(exc)}
        output.append({"source_id": row["source_id"], "response": actual, "score": score, "error": error})
    return output


def aggregate(output):
    return {
        "score": sum(row["score"] for row in output) / len(output),
        "errors": sum(row["error"] is not None for row in output),
        "rows": output,
    }


def disabled():
    dspy, identity, _patch, module, scalar, feedback = install_runtime()
    train, selection = rows("train"), rows("selection")
    assert len(train) == 16 and len(selection) == 32
    assert sha256(HERE / "data/held_out.jsonl") == SPLIT_SHA["test"]
    program = module()
    task = dspy.LM("openrouter/openai/gpt-5.4-mini", cache=False, max_tokens=2048, num_retries=0)
    reflection = dspy.LM("openrouter/anthropic/claude-sonnet-4.6", cache=False, max_tokens=1024, num_retries=0)
    program.set_lm(task)
    _ = optimizer(dspy, semantic_metric(dspy, feedback), reflection, SEEDS[0])
    assert scalar is not None
    print(json.dumps({
        "status": "provider_disabled",
        "provider_authority_used": False,
        "seeds": SEEDS,
        "split_sha256": SPLIT_SHA,
        "per_seed_upstream_ceiling": {"task": 624, "optimizer": 12},
        "effective_gepa": {key: identity[key] for key in ("source_commit", "source_tree", "api_sha256")},
    }, sort_keys=True))


def live():
    dspy, identity, patch, module, scalar, feedback = install_runtime()
    train_rows, selection_rows = rows("train"), rows("selection")
    output_root = Path(os.environ.get("IMP_88SN_UPSTREAM_OUTPUT", "/tmp/imp-88sn-ifbench-upstream")).resolve()

    for seed in SEEDS:
        seed_dir = output_root / str(seed)
        if seed_dir.exists():
            raise RuntimeError(f"output already exists: {seed_dir}")
        seed_dir.mkdir(parents=True)
        task_lm, reflection_lm = lms(dspy, seed)
        baseline = module()
        baseline.set_lm(task_lm)
        baseline_selection = aggregate(evaluate(baseline, dspy, selection_rows, scalar))
        candidate = copy.deepcopy(baseline)
        with dspy.context(lm=task_lm), patch():
            selected = optimizer(dspy, semantic_metric(dspy, feedback), reflection_lm, seed).compile(
                candidate,
                trainset=examples(dspy, train_rows, True),
                valset=examples(dspy, selection_rows, True),
            )
        selected_selection = aggregate(evaluate(selected, dspy, selection_rows, scalar))
        artifact_path = seed_dir / "selected-program.json"
        artifact_temp = seed_dir / "selected-program.private.json"
        descriptor = os.open(artifact_temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        selected.save(artifact_temp)
        os.replace(artifact_temp, artifact_path)
        if not artifact_path.is_file():
            raise RuntimeError("DSPy selected artifact was not written before held-out access")

        test_rows = rows("test", allow_test=True)
        baseline_test = aggregate(evaluate(baseline, dspy, test_rows, scalar))
        selected_test = aggregate(evaluate(selected, dspy, test_rows, scalar))
        result = {
            "seed": seed,
            "effective_gepa": identity,
            "artifact_path": str(artifact_path),
            "artifact_sha256": sha256(artifact_path),
            "baseline_selection": baseline_selection,
            "selected_selection": selected_selection,
            "baseline_test": baseline_test,
            "selected_test": selected_test,
            "task_history": task_lm.history,
            "optimizer_history": reflection_lm.history,
        }
        result_path = seed_dir / "result.json"
        private_write(result_path, json.dumps(result, indent=2, default=str) + "\n")
        print(json.dumps(result, default=str))


if __name__ == "__main__":
    mode = os.environ.get("IMP_88SN_MODE", "disabled")
    if mode == "disabled":
        disabled()
    elif mode == "live":
        live()
    else:
        raise RuntimeError(f"unknown IMP_88SN_MODE {mode!r}")
