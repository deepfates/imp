#!/usr/bin/env python3
"""Normalize pinned RLM benchmark sources without network access."""

import argparse
import collections
import hashlib
import json
from pathlib import Path


OOLONG_SOURCE = "https://huggingface.co/datasets/oolongbench/oolong-synth"
OOLONG_REVISION = "49898a421f4b14f2c9cae084d2d270f930ff4c90"
OOLONG_PAIRS_SOURCE = "https://huggingface.co/datasets/mit-oasys/oolong-pairs"
OOLONG_PAIRS_REVISION = "d1e1522b86ac0c169bbc890b0471408aaa29e8fa"
OOLONG_PAIRS_DATASET_SOURCE = (
    f"{OOLONG_PAIRS_SOURCE} + oolongbench/oolong-synth"
)
OOLONG_PAIRS_DATASET_REVISION = (
    f"pairs@{OOLONG_PAIRS_REVISION}; contexts@{OOLONG_REVISION}"
)
OOLONG_PAIRS_CONTEXT_GRID = (
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
    131072,
    262144,
    524288,
    1048576,
)
OOLONG_PAIRS_CONTEXT_WINDOW_IDS = {
    1024: 0,
    2048: 3,
    4096: 8,
    8192: 9,
    16384: 12,
    32768: 0,
    65536: 3,
    131072: 8,
    262144: 9,
    524288: 12,
    1048576: 16,
}
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


def _load_oolong_pair_contexts(sources):
    import pyarrow.parquet as parquet

    contexts = {}
    for source in sources:
        parquet_file = parquet.ParquetFile(source)
        columns = ["context_len", "context_window_id", "context_window_text", "dataset"]
        for batch in parquet_file.iter_batches(columns=columns, batch_size=128):
            for row in batch.to_pylist():
                size = row["context_len"]
                if row["dataset"] != "trec_coarse" or size not in OOLONG_PAIRS_CONTEXT_WINDOW_IDS:
                    continue
                if row["context_window_id"] != OOLONG_PAIRS_CONTEXT_WINDOW_IDS[size]:
                    continue
                context = row["context_window_text"]
                previous = contexts.get(size)
                if previous is not None and previous != context:
                    raise ValueError(f"context window {size} changed within the pinned source")
                contexts[size] = context

    missing = [size for size in OOLONG_PAIRS_CONTEXT_GRID if size not in contexts]
    if missing:
        raise ValueError(f"missing canonical OOLONG-Pairs contexts: {missing}")
    return {str(size): contexts[size] for size in OOLONG_PAIRS_CONTEXT_GRID}


def _load_oolong_pair_answers(answers_dir):
    answers = {}
    for size in OOLONG_PAIRS_CONTEXT_GRID:
        path = answers_dir / f"oolong-pairs-{size}.json"
        rows = json.loads(path.read_text(encoding="utf-8"))
        indexed = {str(row["id"]): row for row in rows}
        expected_ids = {str(index) for index in range(1, 21)}
        if set(indexed) != expected_ids:
            raise ValueError(f"{path} must contain exactly OOLONG-Pairs IDs 1..20")
        answers[str(size)] = {}
        for query_id, row in indexed.items():
            answer = row.get("answer")
            if not isinstance(answer, list) or not all(isinstance(pair, str) for pair in answer):
                raise ValueError(f"{path} query {query_id} must contain a list of pair strings")
            answers[str(size)][query_id] = answer
    return answers


def normalize_oolong_pairs(questions_source, answers_dir, context_sources, output):
    questions = json.loads(questions_source.read_text(encoding="utf-8"))
    expected_ids = [str(index) for index in range(1, 21)]
    indexed_questions = {str(row["id"]): row for row in questions}
    if list(indexed_questions) != expected_ids:
        raise ValueError("questions.json must contain OOLONG-Pairs IDs 1..20 in order")

    contexts = _load_oolong_pair_contexts(context_sources)
    gold_by_context_size = _load_oolong_pair_answers(answers_dir)
    query_rows = []
    for query_id in expected_ids:
        question = indexed_questions[query_id]
        query_rows.append(
            {
                "id": query_id,
                "source": OOLONG_PAIRS_DATASET_SOURCE,
                "revision": OOLONG_PAIRS_DATASET_REVISION,
                "split": "trec_coarse",
                "gold_by_context_size": {
                    size: gold_by_context_size[size][query_id]
                    for size in (str(value) for value in OOLONG_PAIRS_CONTEXT_GRID)
                },
                "question": question["question"],
            }
        )

    rows = [
        {
            "id": "__contexts__",
            "source": OOLONG_PAIRS_DATASET_SOURCE,
            "revision": OOLONG_PAIRS_DATASET_REVISION,
            "split": "trec_coarse",
            "contexts": contexts,
            "source_metadata": {
                "context_window_id_by_context_size": {
                    str(size): OOLONG_PAIRS_CONTEXT_WINDOW_IDS[size]
                    for size in OOLONG_PAIRS_CONTEXT_GRID
                }
            },
        },
        *query_rows,
    ]

    digest = write_jsonl(output, rows)
    print(canonical_json({"dataset": "oolong_pairs", "sha256": digest, "ids": expected_ids}))


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    codeqa = subparsers.add_parser("codeqa")
    codeqa.add_argument("source", type=Path)
    codeqa.add_argument("output", type=Path)
    oolong = subparsers.add_parser("oolong")
    oolong.add_argument("source", type=Path)
    oolong.add_argument("output", type=Path)
    pairs = subparsers.add_parser("oolong_pairs")
    pairs.add_argument("questions", type=Path)
    pairs.add_argument("answers_dir", type=Path)
    pairs.add_argument("context_sources", type=Path, nargs="+")
    pairs.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if args.command == "codeqa":
        normalize_codeqa(args.source, args.output)
    elif args.command == "oolong_pairs":
        normalize_oolong_pairs(args.questions, args.answers_dir, args.context_sources, args.output)
    else:
        normalize_oolong(args.source, args.output)


if __name__ == "__main__":
    main()
