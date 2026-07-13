#!/usr/bin/env python3
"""Normalize pinned RLM benchmark sources without network access."""

import argparse
import collections
import hashlib
import json
from pathlib import Path


OOLONG_SOURCE = "https://huggingface.co/datasets/oolongbench/oolong-synth"
OOLONG_REVISION = "49898a421f4b14f2c9cae084d2d270f930ff4c90"
LONG_BENCH_SOURCE = "https://huggingface.co/datasets/zai-org/LongBench-v2"
LONG_BENCH_REVISION = "2b48e494f2c7a2f0af81aae178e05c7e1dde0fe9"


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(canonical_json(row) + "\n")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize_codeqa(source, output):
    records = json.loads(source.read_text(encoding="utf-8"))
    selected = [
        row
        for row in records
        if row["domain"] == "Code Repository Understanding"
        and row["sub_domain"] == "Code repo QA"
    ]
    if len(selected) != 50:
        raise ValueError(f"expected 50 CodeQA rows, found {len(selected)}")

    rows = []
    for row in selected:
        choices = {letter: row[f"choice_{letter}"] for letter in "ABCD"}
        if row["answer"] not in choices:
            raise ValueError(f"invalid answer for {row['_id']}")
        rows.append(
            {
                "id": row["_id"],
                "source": LONG_BENCH_SOURCE,
                "revision": LONG_BENCH_REVISION,
                "split": "CodeQA",
                "context": row["context"],
                "question": row["question"],
                "choices": choices,
                "answer": row["answer"],
                "source_metadata": {
                    "domain": row["domain"],
                    "sub_domain": row["sub_domain"],
                    "difficulty": row["difficulty"],
                    "length": row["length"],
                },
            }
        )
    digest = write_jsonl(output, rows)
    print(canonical_json({"dataset": "longbench_v2_codeqa", "sha256": digest, "ids": [r["id"] for r in rows]}))


def normalize_oolong(source, output):
    import pyarrow.parquet as parquet

    records = parquet.read_table(source).to_pylist()
    selected = [
        row
        for row in records
        if row["dataset"] == "trec_coarse" and row["context_len"] == 131072
    ]
    selected.sort(key=lambda row: row["id"])
    if len(selected) != 50:
        raise ValueError(f"expected 50 OOLONG rows, found {len(selected)}")
    window_counts = collections.Counter(row["context_window_id"] for row in selected)
    if sorted(window_counts.values()) != [25, 25]:
        raise ValueError(f"expected two 25-task OOLONG context windows, found {window_counts}")

    rows = []
    for row in selected:
        rows.append(
            {
                "id": str(row["id"]),
                "source": OOLONG_SOURCE,
                "revision": OOLONG_REVISION,
                "split": "trec_coarse",
                "context": row["context_window_text"],
                "question": row["question"],
                "answer": row["answer"],
                "source_metadata": {
                    "answer_type": row["answer_type"],
                    "context_len": row["context_len"],
                    "context_window_id": row["context_window_id"],
                    "input_subset": row["input_subset"],
                    "task": row["task"],
                    "task_group": row["task_group"],
                },
            }
        )
    digest = write_jsonl(output, rows)
    print(canonical_json({"dataset": "oolong", "sha256": digest, "ids": [r["id"] for r in rows]}))


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    codeqa = subparsers.add_parser("codeqa")
    codeqa.add_argument("source", type=Path)
    codeqa.add_argument("output", type=Path)
    oolong = subparsers.add_parser("oolong")
    oolong.add_argument("source", type=Path)
    oolong.add_argument("output", type=Path)
    args = parser.parse_args()

    if args.command == "codeqa":
        normalize_codeqa(args.source, args.output)
    else:
        normalize_oolong(args.source, args.output)


if __name__ == "__main__":
    main()
