#!/usr/bin/env python3
"""Materialize the pinned Dynamic Cheatsheet equation dataset as canonical JSONL."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import pyarrow as pa


UPSTREAM_REPOSITORY = "https://github.com/suzgunmirac/dynamic-cheatsheet"
UPSTREAM_COMMIT = "5cfe3c37e8e52b1d858d0f3df46e7f17c50991b9"
UPSTREAM_PATH = "data/MathEquationBalancer/data-00000-of-00001.arrow"
UPSTREAM_SHA256 = "4f7a605807efb3b2b5e739f39032d4e9bb5026e57ca3c8d45a3e99a861c3e5e2"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    args = parser.parse_args()

    source_bytes = args.source.read_bytes()
    if sha256(source_bytes) != UPSTREAM_SHA256:
        raise SystemExit("pinned Arrow source SHA-256 mismatch")

    with pa.memory_map(str(args.source), "r") as source:
        rows = pa.ipc.open_stream(source).read_all().to_pylist()

    normalized = []
    for index, row in enumerate(rows):
        equation = row["input"].strip()
        target = row["target"].strip()
        target_value = int(row["target_value"])
        source_id = f"dynamic-cheatsheet:equation:{index:03d}"
        group_digest = sha256(equation.encode("utf-8"))[:20]
        normalized.append(
            {
                "dataset": "dynamic_cheatsheet_math_equation_balancer",
                "dataset_commit": UPSTREAM_COMMIT,
                "expected": target,
                "group_id": f"equation:{group_digest}",
                "id": f"dc-equation-{index:03d}",
                "input": equation,
                "leakage_terms": [target],
                "source_id": source_id,
                "source_row": index,
                "target_value": target_value,
            }
        )

    if len({row["id"] for row in normalized}) != len(normalized):
        raise SystemExit("duplicate normalized IDs")
    if len({row["group_id"] for row in normalized}) != len(normalized):
        raise SystemExit("duplicate equation groups require grouped split handling")

    encoded = "".join(canonical_json(row) + "\n" for row in normalized).encode("utf-8")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(encoded)

    provenance = {
        "schema_version": 1,
        "builder": {
            "path": "benchmarks/data/playbook/build_dataset.py",
            "sha256": sha256(Path(__file__).read_bytes()),
        },
        "materialized": {
            "path": "benchmarks/data/playbook/math-equation-balancer.jsonl",
            "rows": len(normalized),
            "sha256": sha256(encoded),
        },
        "source": {
            "commit": UPSTREAM_COMMIT,
            "path": UPSTREAM_PATH,
            "repository": UPSTREAM_REPOSITORY,
            "sha256": UPSTREAM_SHA256,
        },
    }
    args.provenance.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
