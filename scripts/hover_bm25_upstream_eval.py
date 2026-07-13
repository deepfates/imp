#!/usr/bin/env python3
"""Evaluate upstream GEPA HoVer BM25 retrieval for DSEx parity checks."""

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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True)
    parser.add_argument("--query", required=True)
    parser.add_argument("--k", type=int, default=24)
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


if __name__ == "__main__":
    raise SystemExit(main())
