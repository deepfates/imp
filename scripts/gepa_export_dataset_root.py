#!/usr/bin/env python3
"""Export GEPA artifact benchmark splits into DSEx GEPA campaign JSONL format."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List


FAMILY_SPECS: Dict[str, Dict[str, Any]] = {
    "AIMEBench": {
        "module": "gepa_artifact.benchmarks.AIME",
        "program": "CoT",
        "signature": "problem -> answer",
        "instructions": "Solve the problem and provide the answer in the correct format.",
        "input_keys": ["problem"],
        "output_key": "answer",
        "metric_calls": 1839,
        "upstream_metric": "AIME.metric integer exact match",
    },
    "HotpotQABench": {
        "module": "gepa_artifact.benchmarks.hotpotQA",
        "program": "HotpotMultiHop",
        "signature": "question -> answer",
        "instructions": "Answer the multi-hop question using retrieved evidence.",
        "input_keys": ["question"],
        "output_key": "answer",
        "metric_calls": 6871,
        "upstream_metric": "dspy.evaluate.answer_exact_match",
    },
    "hoverBench": {
        "module": "gepa_artifact.benchmarks.hover",
        "program": "HoverMultiHop",
        "signature": "claim -> retrieved_docs",
        "instructions": "Verify the claim using retrieved supporting evidence.",
        "input_keys": ["claim"],
        "output_key": "retrieved_docs",
        "metric_calls": 7051,
        "upstream_metric": "hover_utils.discrete_retrieval_eval",
    },
    "IFBench": {
        "module": "gepa_artifact.benchmarks.IFBench",
        "program": "IFBenchCoT2StageProgram",
        "signature": "prompt -> response",
        "instructions": "Respond to the query while satisfying all instruction-following constraints.",
        "input_keys": ["prompt"],
        "output_key": "response",
        "metric_calls": 3593,
        "upstream_metric": "IFBench.ifbench_metric.metric",
    },
    "LiveBenchMathBench": {
        "module": "gepa_artifact.benchmarks.livebench_math",
        "program": "CoT",
        "signature": "question -> answer",
        "instructions": "Solve the question and provide the answer in the correct format.",
        "input_keys": ["question"],
        "output_key": "answer",
        "metric_calls": 1839,
        "upstream_metric": "livebench_math.calculate_livebench_score",
    },
    "Papillon": {
        "module": "gepa_artifact.benchmarks.papillon",
        "program": "PAPILLON",
        "signature": "user_query -> llm_request, response",
        "instructions": "Answer the user query while preserving privacy-sensitive information.",
        "input_keys": ["user_query"],
        "output_key": "response",
        "metric_calls": 2426,
        "upstream_metric": "papillon_utils.compute_overall_score",
    },
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--max-per-split", type=int)
    args = parser.parse_args()

    gepa_root = Path(args.gepa_root).resolve()
    out = Path(args.out).resolve()
    sys.path.insert(0, str(gepa_root))

    out.mkdir(parents=True, exist_ok=True)
    exported_specs: List[Dict[str, Any]] = []

    for family, spec in FAMILY_SPECS.items():
        benchmark = instantiate_benchmark(spec["module"], family)
        family_dir = out / family
        family_dir.mkdir(parents=True, exist_ok=True)

        split_counts = {}
        split_checksums = {}
        for split_name, examples in [
            ("train", benchmark.train_set),
            ("dev", benchmark.val_set),
            ("test", benchmark.test_set),
        ]:
            records = [example_to_record(example) for example in list(examples)]
            if args.max_per_split is not None:
                records = records[: args.max_per_split]

            path = family_dir / f"{split_name}.jsonl"
            write_jsonl(path, records)
            split_counts[split_name] = len(records)
            split_checksums[split_name] = "sha256:" + sha256(path)

        exported_specs.append(
            {
                **{key: value for key, value in spec.items() if key != "module"},
                "family": family,
                "dataset_source": f"{gepa_root}@{git_sha(gepa_root)}",
                "split_counts": split_counts,
                "split_checksums": split_checksums,
                **family_extra_metadata(gepa_root, family),
                "metric_fidelity": (
                    "upstream_metric_named_for_adapter; DSEx campaign runner ports "
                    "deterministic adapters, Papillon judge scoring, IFBench registry "
                    "checks, and guarded LiveBenchMath symbolic bridge branches"
                ),
            }
        )

    write_json(
        out / "families.json",
        {
            "schema_version": 1,
            "runner": "gepa_export_dataset_root.py",
            "gepa_root": str(gepa_root),
            "gepa_commit": git_sha(gepa_root),
            "families": exported_specs,
        },
    )

    print(out)
    return 0


def instantiate_benchmark(module_name: str, family: str):
    module = importlib.import_module(module_name)
    metas = getattr(module, "benchmark")
    meta = metas[0]
    dataset_mode = getattr(meta, "dataset_mode", None)
    benchmark = meta.benchmark(dataset_mode=dataset_mode) if dataset_mode else meta.benchmark()
    expected_name = meta.name or benchmark.__class__.__name__
    if expected_name != family:
        raise RuntimeError(f"expected family {family}, got benchmark {expected_name}")
    return benchmark


def family_extra_metadata(gepa_root: Path, family: str) -> Dict[str, Any]:
    if family != "hoverBench":
        return {}

    hover_dir = gepa_root / "gepa_artifact" / "benchmarks" / "hover"
    corpus = hover_dir / "wiki.abstracts.2017.jsonl"
    index = hover_dir / "bm25s_retriever"

    retrieval: Dict[str, Any] = {
        "kind": "bm25s_wiki_abstracts_2017",
        "source_url": "https://huggingface.co/dspy/cache/resolve/main/wiki.abstracts.2017.tar.gz",
        "corpus_path": str(corpus),
        "index_path": str(index),
        "status": "present" if corpus.exists() and index.exists() else "missing",
    }

    if corpus.exists():
        retrieval["corpus_checksum"] = "sha256:" + sha256(corpus)

    if index.exists():
        if index.is_file():
            retrieval["index_checksum"] = "sha256:" + sha256(index)
        else:
            retrieval["index_checksum"] = "sha256:" + sha256_tree(index)

    return {"retrieval": retrieval}


def example_to_record(example: Any) -> Dict[str, Any]:
    if hasattr(example, "toDict"):
        data = example.toDict()
    elif isinstance(example, dict):
        data = dict(example)
    else:
        data = dict(example)
    return json_safe(data)


def json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): json_safe(val) for key, val in value.items() if not str(key).startswith("_")}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def write_jsonl(path: Path, records: Iterable[Dict[str, Any]]) -> None:
    with path.open("w") as f:
        for record in records:
            f.write(json.dumps(record, sort_keys=True) + "\n")


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_tree(path: Path) -> str:
    h = hashlib.sha256()
    for file_path in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = file_path.relative_to(path).as_posix()
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        with file_path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        h.update(b"\0")
    return h.hexdigest()


def git_sha(path: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return "unknown"


if __name__ == "__main__":
    raise SystemExit(main())
