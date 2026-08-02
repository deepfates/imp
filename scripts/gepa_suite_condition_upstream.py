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
ARMS = ("baseline", "mipro_v2_heavy", "gepa_v0_1_4_no_merge")


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
    parser.add_argument("--api-base")
    parser.add_argument("--api-key-env", default="OPENROUTER_API_KEY")
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


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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


def source_metric(meta: Any):
    return meta.metric


def gepa_metric(dspy: Any, meta: Any):
    feedback_map = (meta.feedback_fn_maps or [{}])[0]

    def lookup(name: str):
        return feedback_map.get(name) or feedback_map.get(f"{name}.predict")

    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        overall = meta.metric(gold, pred, trace)
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
        result = meta.metric_with_feedback(gold, pred, trace)
        if hasattr(result, "feedback"):
            return dspy.Prediction(score=overall, feedback=result.feedback)
        return dspy.Prediction(score=overall, feedback=f"This trajectory scored {overall}.")

    return metric


def make_lm(dspy: Any, model: str | None, args: argparse.Namespace):
    if not model:
        raise RuntimeError("live execution requires every declared model role")
    import os

    return dspy.LM(
        model=model,
        api_base=args.api_base,
        api_key=os.environ[args.api_key_env],
        temperature=1.0,
        cache=False,
        max_tokens=16_384,
    )


def configure_program(program: Any, task_lm: Any, judge_lm: Any, family: str) -> None:
    program.set_lm(task_lm)
    if family == "Papillon":
        program.untrusted_model = task_lm
        utils = importlib.import_module("gepa_artifact.benchmarks.papillon.papillon_utils")
        utils.llm_judge.set_lm(judge_lm)


def evaluate(dspy: Any, program: Any, rows: list[Any], metric: Any) -> dict[str, Any]:
    result = dspy.Evaluate(
        devset=rows,
        metric=metric,
        num_threads=1,
        return_all_scores=True,
        failure_score=0.0,
        max_errors=10_000,
    )(program)
    scores = [float(item[2]) for item in result.results]
    return {"mean": sum(scores) / len(scores), "count": len(scores), "scores": scores}


def optimize(dspy: Any, program: Any, meta: Any, train: list[Any], dev: list[Any], args: argparse.Namespace, task_lm: Any, reflection_lm: Any, metric_calls: int):
    if args.arm == "baseline":
        return program
    if args.arm == "mipro_v2_heavy":
        optimizer = dspy.MIPROv2(
            metric=source_metric(meta),
            prompt_model=reflection_lm,
            task_model=task_lm,
            auto="heavy",
            num_threads=1,
            max_errors=10_000,
            seed=args.seed,
            track_stats=True,
        )
        return optimizer.compile(program, trainset=train, valset=dev, requires_permission_to_run=False)
    optimizer = dspy.GEPA(
        metric=gepa_metric(dspy, meta),
        max_metric_calls=metric_calls,
        reflection_minibatch_size=3,
        reflection_lm=reflection_lm,
        component_selector="round_robin",
        use_merge=False,
        num_threads=1,
        failure_score=0.0,
        track_stats=True,
        seed=args.seed,
        gepa_kwargs={"acceptance_criterion": "strict_improvement"},
    )
    return optimizer.compile(program, trainset=train, valset=dev)


def predictor_state(program: Any) -> dict[str, str]:
    return {name: predictor.signature.instructions for name, predictor in program.named_predictors()}


def main() -> None:
    args = parse_args()
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

    preflight = {
        "status": "provider_disabled_ready" if not args.run and not args.fresh else "running",
        "family": args.family,
        "arm": args.arm,
        "seed": args.seed,
        "splits": spec["split_counts"],
        "metric_calls": spec["metric_calls"],
        "runtime": {"bridge": bridge.as_dict(), "gepa": runtime},
        "heldout_decoded": False,
        "retrieval": retrieval,
    }
    if not args.run and not args.fresh:
        print(json.dumps(preflight, sort_keys=True))
        return

    task_lm = make_lm(dspy, args.task_model, args)
    reflection_lm = make_lm(dspy, args.reflection_model, args)
    judge_lm = make_lm(dspy, args.judge_model, args)
    program = copy.deepcopy(meta.program[0])
    configure_program(program, task_lm, judge_lm, args.family)

    if args.fresh:
        if args.state is None:
            raise RuntimeError("fresh mode requires --state")
        program.load(args.state)
        test = load_rows(dspy, test_path, spec["input_keys"])
        calls = []
        with dspy.context(lm=task_lm):
            for row in test[:4]:
                prediction = program(**row.inputs())
                calls.append(dict(prediction))
        payload = {**preflight, "status": "fresh_ok", "calls": calls, "heldout_decoded": True}
        if args.output:
            args.output.write_text(json.dumps(payload, sort_keys=True, default=str))
        else:
            print(json.dumps(payload, sort_keys=True, default=str))
        return

    if args.output is None:
        raise RuntimeError("live run requires --output")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    state_path = args.output.with_suffix(".state.json")
    fresh_path = args.output.with_suffix(".fresh.json")
    train = load_rows(dspy, train_path, spec["input_keys"])
    dev = load_rows(dspy, dev_path, spec["input_keys"])
    with dspy.context(lm=task_lm):
        selected = optimize(dspy, program, meta, train, dev, args, task_lm, reflection_lm, spec["metric_calls"])
        test = load_rows(dspy, test_path, spec["input_keys"])
        baseline_result = evaluate(dspy, program, test, source_metric(meta))
        selected_result = evaluate(dspy, selected, test, source_metric(meta))
    selected.save(state_path, save_program=False)

    child_args = [
        sys.executable, "-P", str(Path(__file__).resolve()), "--fresh", "--run",
        "--dspy-root", str(args.dspy_root), "--gepa-root", str(args.gepa_root),
        "--artifact-root", str(args.artifact_root), "--dataset-root", str(args.dataset_root),
        "--family", args.family, "--arm", args.arm, "--seed", str(args.seed),
        "--task-model", args.task_model, "--reflection-model", args.reflection_model,
        "--judge-model", args.judge_model, "--api-key-env", args.api_key_env,
        "--state", str(state_path), "--output", str(fresh_path),
    ]
    if args.api_base:
        child_args += ["--api-base", args.api_base]
    if args.retrieval_root:
        child_args += ["--retrieval-root", str(args.retrieval_root)]
    if args.retrieval_receipt:
        child_args += ["--retrieval-receipt", str(args.retrieval_receipt)]
    subprocess.run(child_args, check=True)
    payload = {
        **preflight,
        "status": "complete",
        "heldout_decoded": True,
        "baseline": baseline_result,
        "selected": selected_result,
        "causal_lift": selected_result["mean"] - baseline_result["mean"],
        "predictors": predictor_state(selected),
        "state_sha256": sha256(state_path),
        "fresh_sha256": sha256(fresh_path),
    }
    args.output.write_text(json.dumps(payload, sort_keys=True, default=str))


if __name__ == "__main__":
    main()
