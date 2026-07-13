#!/usr/bin/env python3
"""Build the pinned, source-disjoint TREC fine-label confidence dataset."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import urllib.request
from collections import Counter


DATASET_REVISION = "eb1e45c1ba990fecca7cf84b67ce845edbcf49bf"
SELECTION_SEED = "dsex-confidence-calibration-trec-fine-v1"
DEFAULT_COUNT = 200
PROMPT_IDS = ("taxonomy_full_v1", "taxonomy_compact_v1")
SOURCES = {
    "train": {
        "filename": "train_5500.label",
        "url": "https://cogcomp.seas.upenn.edu/Data/QA/QC/train_5500.label",
        "sha256": "9e4c8bdcaffb96ed61041bd64b564183d52793a8e91d84fc3a8646885f466ec3",
    },
    "test": {
        "filename": "TREC_10.label",
        "url": "https://cogcomp.seas.upenn.edu/Data/QA/QC/TREC_10.label",
        "sha256": "033f22c028c2bbba9ca682f68ffe204dc1aa6e1cf35dd6207f2d4ca67f0d0e8e",
    },
}
FINE_LABELS = (
    "ABBR:abb",
    "ABBR:exp",
    "ENTY:animal",
    "ENTY:body",
    "ENTY:color",
    "ENTY:cremat",
    "ENTY:currency",
    "ENTY:dismed",
    "ENTY:event",
    "ENTY:food",
    "ENTY:instru",
    "ENTY:lang",
    "ENTY:letter",
    "ENTY:other",
    "ENTY:plant",
    "ENTY:product",
    "ENTY:religion",
    "ENTY:sport",
    "ENTY:substance",
    "ENTY:symbol",
    "ENTY:techmeth",
    "ENTY:termeq",
    "ENTY:veh",
    "ENTY:word",
    "DESC:def",
    "DESC:desc",
    "DESC:manner",
    "DESC:reason",
    "HUM:gr",
    "HUM:ind",
    "HUM:title",
    "HUM:desc",
    "LOC:city",
    "LOC:country",
    "LOC:mount",
    "LOC:other",
    "LOC:state",
    "NUM:code",
    "NUM:count",
    "NUM:date",
    "NUM:dist",
    "NUM:money",
    "NUM:ord",
    "NUM:other",
    "NUM:period",
    "NUM:perc",
    "NUM:speed",
    "NUM:temp",
    "NUM:volsize",
    "NUM:weight",
)


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def normalized_group(text: str) -> str:
    normalized = " ".join(text.casefold().split())
    return f"trec-question-sha256:{sha256(normalized.encode('utf-8'))}"


def download_source(split: str, cache_dir: pathlib.Path) -> tuple[pathlib.Path, bytes]:
    source = SOURCES[split]
    path = cache_dir / source["filename"]
    cache_dir.mkdir(parents=True, exist_ok=True)

    if not path.exists():
        with urllib.request.urlopen(source["url"]) as response:
            path.write_bytes(response.read())

    body = path.read_bytes()
    actual = sha256(body)
    if actual != source["sha256"]:
        raise ValueError(
            f"{split} source digest mismatch: expected {source['sha256']}, got {actual}"
        )

    return path, body


def parse_rows(split: str, body: bytes) -> list[dict[str, object]]:
    rows = []
    source_sha = SOURCES[split]["sha256"]

    for source_row, raw_line in enumerate(body.replace(b"\xf0", b" ").splitlines()):
        label, separator, raw_text = raw_line.strip().decode("utf-8").partition(" ")
        text = raw_text.strip()
        if not separator or not text or label not in FINE_LABELS:
            raise ValueError(f"invalid {split} row {source_row}: {raw_line!r}")

        rows.append(
            {
                "group_id": normalized_group(text),
                "label": label,
                "source_file_sha256": source_sha,
                "source_id": f"cogcomp-trec:{split}:{source_sha[:16]}:{source_row}",
                "source_label": label,
                "source_row": source_row,
                "source_split": split,
                "text": text,
            }
        )

    return rows


def selection_key(row: dict[str, object], split: str) -> str:
    value = f"{SELECTION_SEED}\0{split}\0{row['source_id']}\0{row['text']}"
    return sha256(value.encode("utf-8"))


def unique_groups(rows: list[dict[str, object]], split: str) -> list[dict[str, object]]:
    selected = []
    seen = set()

    for row in sorted(rows, key=lambda row: selection_key(row, split)):
        if row["group_id"] not in seen:
            selected.append(row)
            seen.add(row["group_id"])

    return selected


def select_rows(
    train: list[dict[str, object]], test: list[dict[str, object]], count: int
) -> tuple[list[dict[str, object]], dict[str, int]]:
    all_train_groups = {row["group_id"] for row in train}
    train_unique = unique_groups(train, "train")
    test_unique = unique_groups(test, "test")
    eligible_test = [row for row in test_unique if row["group_id"] not in all_train_groups]

    if len(train_unique) < count or len(eligible_test) < count:
        raise ValueError(
            f"requested {count} rows per split, but only {len(train_unique)} train and "
            f"{len(eligible_test)} source-disjoint test rows are available"
        )

    return train_unique[:count] + eligible_test[:count], {
        "train_duplicate_groups_removed": len(train) - len(train_unique),
        "test_duplicate_groups_removed": len(test) - len(test_unique),
        "test_groups_overlapping_any_train_group_removed": len(test_unique) - len(eligible_test),
    }


def materialize(rows: list[dict[str, object]], count: int) -> list[dict[str, object]]:
    output = []

    for offset, row in enumerate(rows):
        split = "calibration" if offset < count else "heldout"
        split_offset = offset if split == "calibration" else offset - count
        output.append(
            {
                **row,
                "dataset": "CogComp/trec",
                "dataset_revision": DATASET_REVISION,
                "id": f"trec-fine:{split}:{split_offset:04d}",
                "prompt": PROMPT_IDS[split_offset % len(PROMPT_IDS)],
                "split": split,
                "task": "trec_fine_v1",
            }
        )

    return output


def encoded_jsonl(rows: list[dict[str, object]]) -> bytes:
    lines = [json.dumps(row, sort_keys=True, separators=(",", ":")) for row in rows]
    return ("\n".join(lines) + "\n").encode("utf-8")


def label_counts(rows: list[dict[str, object]], split: str) -> dict[str, int]:
    counts = Counter(row["label"] for row in rows if row["split"] == split)
    return dict(sorted(counts.items()))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path("benchmarks/data/confidence-calibration-trec-fine.jsonl"),
    )
    parser.add_argument(
        "--provenance",
        type=pathlib.Path,
        default=pathlib.Path("benchmarks/data/confidence-calibration-trec-fine.provenance.json"),
    )
    parser.add_argument(
        "--cache-dir",
        type=pathlib.Path,
        default=pathlib.Path("/tmp/dsex-confidence-trec"),
    )
    parser.add_argument("--count", type=int, default=DEFAULT_COUNT)
    args = parser.parse_args()

    if args.count < 1:
        parser.error("--count must be positive")

    _, train_body = download_source("train", args.cache_dir)
    _, test_body = download_source("test", args.cache_dir)
    train = parse_rows("train", train_body)
    test = parse_rows("test", test_body)
    selected, exclusions = select_rows(train, test, args.count)
    rows = materialize(selected, args.count)
    data = encoded_jsonl(rows)

    provenance = {
        "schema_version": 1,
        "dataset": "CogComp/trec",
        "dataset_card": "https://huggingface.co/datasets/CogComp/trec",
        "dataset_loader_revision": DATASET_REVISION,
        "dataset_loader_version": "2.0.0",
        "homepage": "https://cogcomp.seas.upenn.edu/Data/QA/QC/",
        "labels": {
            "field": "fine_label",
            "ordered_values": list(FINE_LABELS),
            "origin": "exact human-assigned source labels; no DSEx labels were created",
        },
        "license": "unknown (as reported by the pinned dataset card)",
        "output": {
            "calibration_count": args.count,
            "heldout_count": args.count,
            "label_counts": {
                "calibration": label_counts(rows, "calibration"),
                "heldout": label_counts(rows, "heldout"),
            },
            "path": str(args.output),
            "sha256": sha256(data),
        },
        "partition_contract": {
            "calibration_source_split": "official train",
            "heldout_source_split": "official TREC-10 test",
            "group_id": "SHA-256 of case-folded, whitespace-normalized question text",
            "heldout_overlap_policy": "exclude a heldout group present anywhere in train",
            "source_id": "source split, immutable source-file digest prefix, and source row",
        },
        "selection": {
            "algorithm": "SHA-256 rank after normalized-question deduplication",
            "exclusions": exclusions,
            "prompt_assignment": "alternating rank within each split",
            "prompt_ids": list(PROMPT_IDS),
            "seed": SELECTION_SEED,
        },
        "sources": SOURCES,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.provenance.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    args.provenance.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
