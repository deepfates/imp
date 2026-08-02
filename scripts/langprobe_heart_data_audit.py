#!/usr/bin/env python3
"""Compare the published LangProBe/TensorFlow Heart file with official UCI.

This is a source-identity audit, not a data fetcher or benchmark runner.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import zipfile


LANGPROBE_LF_SHA256 = "3369f450e6fdbad6019755437f0228109cb457e62b8cf7c4b29799ba1f8fc884"
TENSORFLOW_CRLF_SHA256 = "a91c81831bb2126e5fde6ce4ebde147a78429da12005108a6677ba57ecde9244"
UCI_ARCHIVE_SHA256 = "b17cd273da9ce1caa4710fce80227ea454d4dbf9fcbc8e6a9121672751563adc"
FEATURES = (
    "age",
    "sex",
    "cp",
    "trestbps",
    "chol",
    "fbs",
    "restecg",
    "thalach",
    "exang",
    "oldpeak",
    "slope",
    "ca",
)


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def normalized_number(value: str) -> str:
    try:
        number = float(value)
    except ValueError:
        return value
    return str(int(number)) if number.is_integer() else format(number, "g")


def feature_key(values) -> tuple[str, ...]:
    return tuple(normalized_number(value) for value in values)


def audit(langprobe_path: Path, tensorflow_path: Path, uci_archive_path: Path) -> dict:
    langprobe_bytes = langprobe_path.read_bytes()
    tensorflow_bytes = tensorflow_path.read_bytes()
    uci_bytes = uci_archive_path.read_bytes()

    assert sha256(langprobe_bytes) == LANGPROBE_LF_SHA256
    assert sha256(tensorflow_bytes) == TENSORFLOW_CRLF_SHA256
    assert sha256(uci_bytes) == UCI_ARCHIVE_SHA256
    assert tensorflow_bytes.replace(b"\r\n", b"\n") == langprobe_bytes

    benchmark_rows = list(csv.DictReader(io.StringIO(langprobe_bytes.decode())))
    with zipfile.ZipFile(io.BytesIO(uci_bytes)) as archive:
        official_rows = [
            line.split(",")
            for line in archive.read("processed.cleveland.data").decode().strip().splitlines()
        ]

    official_by_features = {}
    for row in official_rows:
        official_by_features.setdefault(feature_key(row[:12]), []).append(row)

    matched = []
    unmatched = []
    for row in benchmark_rows:
        candidates = official_by_features.get(feature_key(row[name] for name in FEATURES), [])
        if len(candidates) == 1:
            matched.append((row, candidates[0]))
        else:
            unmatched.append(row)

    assert len(benchmark_rows) == len(official_rows) == 303
    assert len(matched) == 297
    assert len(unmatched) == 6
    assert sum("?" in row for row in official_rows) == 6
    assert all(int(benchmark["target"]) == (int(official[13]) >= 2) for benchmark, official in matched)

    target_cross = {}
    for benchmark, official in matched:
        key = f"uci_{official[13]}__benchmark_{benchmark['target']}"
        target_cross[key] = target_cross.get(key, 0) + 1

    return {
        "status": "not_equivalent_to_official_uci_processed_cleveland",
        "benchmark_rows": len(benchmark_rows),
        "official_rows": len(official_rows),
        "exact_feature_matches": len(matched),
        "unmatched_benchmark_rows": len(unmatched),
        "official_rows_with_missing_values": sum("?" in row for row in official_rows),
        "matched_target_rule": "benchmark positive iff official severity >= 2",
        "target_cross": target_cross,
        "langprobe_lf_sha256": sha256(langprobe_bytes),
        "tensorflow_crlf_sha256": sha256(tensorflow_bytes),
        "uci_archive_sha256": sha256(uci_bytes),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--langprobe-csv", required=True, type=Path)
    parser.add_argument("--tensorflow-csv", required=True, type=Path)
    parser.add_argument("--uci-archive", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.langprobe_csv, args.tensorflow_csv, args.uci_archive), sort_keys=True))


if __name__ == "__main__":
    main()
