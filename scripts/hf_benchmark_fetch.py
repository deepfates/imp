#!/usr/bin/env python3
"""Fetch canonical benchmark rows through HuggingFace Parquet exports."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List

import pyarrow.parquet as pq


SPECS: Dict[str, Dict[str, Any]] = {
    "gsm8k": {
        "dataset": "openai/gsm8k",
        "config": "main",
        "split": "test",
        "full_length": 1319,
        "input_keys": ["question"],
    },
    "hotpotqa": {
        "dataset": "hotpotqa/hotpot_qa",
        "config": "fullwiki",
        "split": "validation",
        "full_length": 7405,
        "input_keys": ["question", "context"],
    },
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks", default="gsm8k,hotpotqa")
    parser.add_argument("--out", default="benchmarks/data")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--length", type=int)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    for task in split_csv(args.tasks):
        spec = SPECS[task]
        requested_length = spec["full_length"] if args.full else (args.length or 20)
        rows = fetch_task(task, spec, args.offset, requested_length)
        write_task(out_dir, task, spec, args.offset, requested_length, rows)

    return 0


def fetch_task(task: str, spec: Dict[str, Any], offset: int, length: int) -> List[Dict[str, Any]]:
    files = parquet_files(spec)
    raw_rows: List[Dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="dsex-hf-parquet-") as tmp:
        for file_index, file_info in enumerate(files):
            local_path = Path(tmp) / f"{task}-{file_index}.parquet"
            urllib.request.urlretrieve(file_info["url"], local_path)
            raw_rows.extend(pq.read_table(local_path).to_pylist())

    window = raw_rows[offset : offset + length]
    normalizer = normalize_gsm8k if task == "gsm8k" else normalize_hotpotqa
    return [normalizer(row) for row in window]


def parquet_files(spec: Dict[str, Any]) -> List[Dict[str, Any]]:
    query = urllib.parse.urlencode({"dataset": spec["dataset"]})
    url = f"https://datasets-server.huggingface.co/parquet?{query}"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = json.load(response)

    files = [
        file_info
        for file_info in data["parquet_files"]
        if file_info["config"] == spec["config"] and file_info["split"] == spec["split"]
    ]
    if not files:
        raise RuntimeError(f"no parquet files found for {spec['dataset']} {spec['config']} {spec['split']}")
    return files


def normalize_gsm8k(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "question": row["question"],
        "answer": row["answer"],
        "canonical_answer": extract_gsm8k_answer(row["answer"]),
        "source_task": "gsm8k",
    }


def normalize_hotpotqa(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": row.get("id"),
        "question": row["question"],
        "answer": row["answer"],
        "context": flatten_hotpot_context(row.get("context")),
        "supporting_facts": row.get("supporting_facts"),
        "source_task": "hotpotqa",
    }


def flatten_hotpot_context(context: Any) -> str:
    if isinstance(context, dict) and isinstance(context.get("title"), list):
        titles = context.get("title", [])
        sentences = context.get("sentences", [])
        return "\n".join(
            f"{title}: {' '.join(str(line) for line in ensure_list(lines))}"
            for title, lines in zip(titles, sentences)
        )
    if isinstance(context, list):
        return "\n".join(str(value) for value in context)
    return str(context or "")


def write_task(
    out_dir: Path,
    task: str,
    spec: Dict[str, Any],
    offset: int,
    requested_length: int,
    rows: List[Dict[str, Any]],
) -> None:
    basename = f"{task}-{spec['split']}-{offset}-{requested_length}"
    data_path = out_dir / f"{basename}.jsonl"
    manifest_path = out_dir / f"{basename}.manifest.json"
    jsonl = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows)
    data_path.write_text(jsonl, encoding="utf-8")

    manifest = {
        "task": task,
        "dataset": spec["dataset"],
        "config": spec["config"],
        "split": spec["split"],
        "offset": offset,
        "requested_length": requested_length,
        "length": len(rows),
        "rows": len(rows),
        "source": "huggingface-parquet",
        "source_url": f"https://datasets-server.huggingface.co/parquet?dataset={urllib.parse.quote(spec['dataset'])}",
        "fetched_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "sha256": hashlib.sha256(jsonl.encode("utf-8")).hexdigest(),
        "data_path": str(data_path),
        "input_keys": spec["input_keys"],
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{task}: {data_path} {manifest_path}")


def extract_gsm8k_answer(answer: Any) -> str:
    return str(answer).split("####")[-1].strip()


def ensure_list(value: Any) -> List[Any]:
    if isinstance(value, list):
        return value
    return [value]


def split_csv(value: str) -> Iterable[str]:
    for item in value.split(","):
        item = item.strip()
        if item:
            yield item


if __name__ == "__main__":
    raise SystemExit(main())
