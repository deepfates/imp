#!/usr/bin/env python3
"""Build the result-blind matched IFBench split from the pinned GEPA artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path


TRAIN_SHA256 = "a5ec13223a93879b7172da783d54669d5873dc4632b57fd6d961730c9679fc8c"
TEST_SHA256 = "11c3d683dcc7f4908a4d3cacd05c9a8bbd5484af2f8fde969e7abe2b8bad3e34"
GEPA_COMMIT = "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def instruction_ids(row: dict) -> tuple[str, ...]:
    values = row.get("instruction_id_list") or row.get("instruction_id") or []
    if not values or not all(isinstance(value, str) and value for value in values):
        raise ValueError("IFBench row has no stable instruction ids")
    return tuple(sorted(set(values)))


def round_robin(rows: list[dict], count: int) -> list[tuple[int, dict]]:
    """Cover constraint ids evenly without inspecting prompts or model outcomes."""
    buckets: dict[str, list[tuple[int, dict]]] = defaultdict(list)
    for index, row in enumerate(rows):
        for instruction_id in instruction_ids(row):
            buckets[instruction_id].append((index, row))

    selected: list[tuple[int, dict]] = []
    selected_indices: set[int] = set()
    offsets = {instruction_id: 0 for instruction_id in buckets}
    ordered_ids = sorted(buckets)

    while len(selected) < count:
        made_progress = False
        for instruction_id in ordered_ids:
            bucket = buckets[instruction_id]
            offset = offsets[instruction_id]
            while offset < len(bucket) and bucket[offset][0] in selected_indices:
                offset += 1
            offsets[instruction_id] = offset
            if offset >= len(bucket):
                continue

            index, row = bucket[offset]
            offsets[instruction_id] += 1
            selected_indices.add(index)
            selected.append((index, row))
            made_progress = True
            if len(selected) == count:
                break

        if not made_progress:
            raise ValueError(f"only {len(selected)} unique rows available for requested {count}")

    return selected


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def write_jsonl(path: Path, selected: list[tuple[int, dict]], source: str) -> list[str]:
    ids: list[str] = []
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for source_index, row in selected:
            source_id = f"ifbench-{source}-{source_index:06d}"
            value = dict(row)
            value["source_id"] = source_id
            handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
            ids.append(source_id)
    return ids


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True, type=Path)
    parser.add_argument("--out", default=Path(__file__).resolve().parent / "data", type=Path)
    args = parser.parse_args()

    source = args.gepa_root.resolve() / "gepa_artifact/benchmarks/IFBench/data"
    train_path = source / "IFBench_train.jsonl"
    test_path = source / "IFBench_test.jsonl"
    if sha256(train_path) != TRAIN_SHA256 or sha256(test_path) != TEST_SHA256:
        raise SystemExit("pinned IFBench source digest drift")

    all_train = read_jsonl(train_path)
    all_test = read_jsonl(test_path)
    if len(all_train) < 600 or len(all_test) != 294:
        raise SystemExit("pinned IFBench split cardinality drift")

    # These are the exact upstream split owners. Selection is result-blind and
    # performed independently inside each owner before any model execution.
    splits = {
        "train": round_robin(all_train[300:600], 16),
        "selection": round_robin(all_train[0:300], 32),
        "held_out": round_robin(all_test, 64),
    }
    offsets = {"train": 300, "selection": 0, "held_out": 0}
    output = args.out.resolve()
    split_ids: dict[str, list[str]] = {}
    source_indices: dict[str, list[int]] = {}

    for name, selected in splits.items():
        absolute = [(index + offsets[name], row) for index, row in selected]
        split_ids[name] = write_jsonl(output / f"{name}.jsonl", absolute, name)
        source_indices[name] = [index for index, _row in absolute]

    digests = {name: sha256(output / f"{name}.jsonl") for name in splits}
    all_ids = [source_id for ids in split_ids.values() for source_id in ids]
    if len(all_ids) != len(set(all_ids)):
        raise SystemExit("generated split identities overlap")

    write_json(
        output / "receipt.json",
        {
            "schema_version": 1,
            "authority": {
                "gepa_artifact_commit": GEPA_COMMIT,
                "train_sha256": TRAIN_SHA256,
                "test_sha256": TEST_SHA256,
            },
            "selection": {
                "algorithm": "sorted_instruction_id_round_robin_first_unused_source_order",
                "result_blind": True,
                "source_owners": {
                    "train": "IFBench_train.jsonl[300:600]",
                    "selection": "IFBench_train.jsonl[0:300]",
                    "held_out": "IFBench_test.jsonl",
                },
                "source_indices": source_indices,
            },
            "counts": {name: len(ids) for name, ids in split_ids.items()},
            "split_ids": split_ids,
            "split_sha256": digests,
        },
    )


if __name__ == "__main__":
    main()
