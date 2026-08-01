#!/usr/bin/env python3
"""Evaluate upstream GEPA HoVer BM25 retrieval for Imp parity checks."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


UPSTREAM_COMMIT = "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
UPSTREAM_SOURCE_SHA256 = (
    "705a1d4fa5452d66d21c00d8d915d5dcd57e820b077a68bf3786407d040d3522"
)
BM25S_VERSION = "0.2.12"
FROZEN_SPLITS = (
    (
        "train",
        150,
        "448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
    ),
    (
        "dev",
        300,
        "b342dbaaa4516e55b7f4f7ac046828c2201952e69de5b97751173238674a74a7",
    ),
)
FINGERPRINT_K = 24


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--query")
    mode.add_argument("--frozen-claim-retrieval-fingerprint", action="store_true")
    parser.add_argument("--k", type=int, default=24)
    parser.add_argument("--data-root")
    args = parser.parse_args()

    gepa_root = Path(args.gepa_root).resolve()
    hover_dir = gepa_root / "gepa_artifact" / "benchmarks" / "hover"
    corpus_path = hover_dir / "wiki.abstracts.2017.jsonl"
    index_path = hover_dir / "bm25s_retriever"
    verify_upstream_source(hover_dir / "hover_program.py")
    verify_index(index_path / "params.index.json")

    import bm25s
    import Stemmer

    if bm25s.__version__ != BM25S_VERSION:
        raise RuntimeError(
            f"HoVer parity requires bm25s=={BM25S_VERSION}, got {bm25s.__version__}"
        )

    stemmer = Stemmer.Stemmer("english")
    retriever = bm25s.BM25.load(index_path, mmap=True)

    if args.frozen_claim_retrieval_fingerprint:
        if args.data_root is None:
            raise RuntimeError(
                "--frozen-claim-retrieval-fingerprint requires --data-root"
            )
        emit_frozen_claim_retrieval_fingerprint(
            retriever,
            stemmer,
            corpus_path,
            Path(args.data_root).resolve(),
            bm25s,
        )
        return 0

    tokens = bm25s.tokenize(
        args.query, stopwords="en", stemmer=stemmer, show_progress=False
    )
    results, scores = retriever.retrieve(
        tokens, k=args.k, n_threads=1, show_progress=False
    )
    doc_ids = [int(doc_id) for doc_id in results[0]]
    docs_by_id = load_docs(corpus_path, doc_ids)
    docs = [docs_by_id[doc_id] for doc_id in doc_ids]

    json.dump(
        {
            "query": args.query,
            "k": args.k,
            "retrieved_docs": docs,
            "titles": [doc.split(" | ", 1)[0] for doc in docs],
            "scores": [float(score) for score in scores[0]],
            "upstream_commit": UPSTREAM_COMMIT,
            "upstream_source_sha256": UPSTREAM_SOURCE_SHA256,
            "bm25s_version": bm25s.__version__,
        },
        sys.stdout,
    )
    sys.stdout.write("\n")
    return 0


def emit_frozen_claim_retrieval_fingerprint(
    retriever,
    stemmer,
    corpus_path: Path,
    data_root: Path,
    bm25s,
    split_specs=FROZEN_SPLITS,
    k=FINGERPRINT_K,
) -> None:
    rows = load_frozen_claim_rows(data_root, split_specs)
    claims = [row["claim"] for row in rows]
    tokens = bm25s.tokenize(
        claims, stopwords="en", stemmer=stemmer, show_progress=False
    )
    results, _scores = retriever.retrieve(
        tokens, k=k, n_threads=1, show_progress=False
    )
    ordered_ids = [[int(doc_id) for doc_id in result] for result in results]

    if any(len(doc_ids) != k for doc_ids in ordered_ids):
        raise RuntimeError(f"HoVer fingerprint retrieval did not return exact top-{k}")

    titles = load_titles(corpus_path, {doc_id for ids in ordered_ids for doc_id in ids})

    for row, doc_ids in zip(rows, ordered_ids, strict=True):
        record = {
            "claim_sha256": hashlib.sha256(row["claim"].encode("utf-8")).hexdigest(),
            "doc_ids": doc_ids,
            "row_sha256": row["row_sha256"],
            "split": row["split"],
            "split_position": row["split_position"],
            "titles": [titles[doc_id] for doc_id in doc_ids],
        }
        sys.stdout.write(
            json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            + "\n"
        )


def load_frozen_claim_rows(data_root: Path, split_specs=FROZEN_SPLITS) -> list[dict]:
    rows = []

    for split, expected_count, expected_sha256 in split_specs:
        path = data_root / f"{split}.jsonl"
        source = path.read_bytes()
        actual_sha256 = hashlib.sha256(source).hexdigest()
        if actual_sha256 != expected_sha256:
            raise RuntimeError(
                f"HoVer frozen {split} bytes differ: expected {expected_sha256}, "
                f"got {actual_sha256}"
            )

        raw_rows = source.splitlines(keepends=True)
        if len(raw_rows) != expected_count or any(not row.endswith(b"\n") for row in raw_rows):
            raise RuntimeError(
                f"HoVer frozen {split} must contain {expected_count} LF-terminated rows"
            )

        for position, raw_row in enumerate(raw_rows):
            parsed = json.loads(raw_row)
            claim = parsed.get("claim")
            if not isinstance(claim, str):
                raise RuntimeError(f"HoVer frozen {split}[{position}] has no string claim")
            rows.append(
                {
                    "claim": claim,
                    "row_sha256": hashlib.sha256(raw_row).hexdigest(),
                    "split": split,
                    "split_position": position,
                }
            )

    return rows


def verify_upstream_source(source_path: Path) -> None:
    digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
    if digest != UPSTREAM_SOURCE_SHA256:
        raise RuntimeError(
            f"HoVer source does not match pinned commit {UPSTREAM_COMMIT}: {digest}"
        )


def verify_index(params_path: Path) -> None:
    params = json.loads(params_path.read_text())
    expected = {
        "k1": 0.9,
        "b": 0.4,
        "method": "lucene",
        "idf_method": "lucene",
        "version": BM25S_VERSION,
    }
    actual = {key: params.get(key) for key in expected}
    if actual != expected:
        raise RuntimeError(f"HoVer BM25S index parameters differ: {actual}")


def load_docs(corpus_path: Path, doc_ids: list[int]) -> dict[int, str]:
    wanted = set(doc_ids)
    docs = {}

    with corpus_path.open() as corpus:
        for doc_id, line in enumerate(corpus):
            if doc_id in wanted:
                row = json.loads(line)
                docs[doc_id] = f"{row['title']} | {' '.join(row['text'])}"
                if len(docs) == len(wanted):
                    break

    missing = wanted.difference(docs)
    if missing:
        raise RuntimeError(f"BM25S index returned missing corpus rows: {sorted(missing)}")

    return docs


def load_titles(corpus_path: Path, doc_ids: set[int]) -> dict[int, str]:
    titles = {}

    with corpus_path.open() as corpus:
        for doc_id, line in enumerate(corpus):
            if doc_id in doc_ids:
                titles[doc_id] = json.loads(line)["title"]
                if len(titles) == len(doc_ids):
                    break

    missing = doc_ids.difference(titles)
    if missing:
        raise RuntimeError(f"BM25S fingerprint returned missing corpus rows: {sorted(missing)}")

    return titles


if __name__ == "__main__":
    raise SystemExit(main())
