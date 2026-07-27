#!/usr/bin/env python3
"""Build the frozen source-disjoint IFBench slice from the pinned GEPA artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


TRAIN_SHA = "a5ec13223a93879b7172da783d54669d5873dc4632b57fd6d961730c9679fc8c"
TEST_SHA = "11c3d683dcc7f4908a4d3cacd05c9a8bbd5484af2f8fde969e7abe2b8bad3e34"
GEPA_COMMIT = "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def write_split(path: Path, rows: list[dict], source: str, offset: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for index, row in enumerate(rows, start=offset):
            value = dict(row)
            value["source_id"] = f"ifbench-{source}-{index:06d}"
            handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    source = args.gepa_root.resolve() / "gepa_artifact/benchmarks/IFBench/data"
    train_source = source / "IFBench_train.jsonl"
    test_source = source / "IFBench_test.jsonl"
    if digest(train_source) != TRAIN_SHA or digest(test_source) != TEST_SHA:
        raise SystemExit("pinned IFBench source digest drift")

    raw_train = read_rows(train_source)
    raw_test = read_rows(test_source)
    out = args.out.resolve()
    family = out / "IFBench"

    # These follow the pinned paper split ownership: train rows 300:600,
    # validation rows 0:300, and the independent test file. The bounded slice
    # is fixed before any model call and never resamples by observed outcome.
    write_split(family / "train.jsonl", raw_train[300:316], "train", 300)
    write_split(family / "dev.jsonl", raw_train[0:24], "dev", 0)
    write_split(family / "test.jsonl", raw_test[0:48], "test", 0)

    checksums = {
        split: "sha256:" + digest(family / f"{split}.jsonl")
        for split in ("train", "dev", "test")
    }
    spec = {
        "dataset_scope": "capped_source_disjoint",
        "dataset_source": f"https://github.com/gepa-ai/gepa-artifact@{GEPA_COMMIT}",
        "family": "IFBench",
        "input_keys": ["prompt"],
        "instructions": "Respond to the query while satisfying all instruction-following constraints.",
        "max_per_split": None,
        "metric_calls": 104,
        "metric_fidelity": "pinned IFBench registry checks and source-exact reflective descriptions",
        "output_key": "response",
        "program": "IFBenchCoT2StageProgram",
        "signature": "prompt -> response",
        "split_checksums": checksums,
        "split_counts": {"train": 16, "dev": 24, "test": 48},
        "upstream_metric": "IFBench.ifbench_metric.metric",
    }
    write_json(out / "families.json", {"families": [spec]})
    write_json(
        out / "source-manifest.json",
        {
            "schema_version": 1,
            "gepa_artifact_commit": GEPA_COMMIT,
            "source_files": {
                "IFBench_train.jsonl": TRAIN_SHA,
                "IFBench_test.jsonl": TEST_SHA,
            },
            "selection": {
                "train": {"source": "IFBench_train.jsonl", "indices": [300, 315]},
                "dev": {"source": "IFBench_train.jsonl", "indices": [0, 23]},
                "test": {"source": "IFBench_test.jsonl", "indices": [0, 47]},
            },
            "split_checksums": checksums,
        },
    )


if __name__ == "__main__":
    main()
