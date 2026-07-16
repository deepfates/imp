#!/usr/bin/env python3
"""Pinned provider-free HotPotQA shared-corpus retrieval differential."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import dspy


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "benchmarks/config/hotpotqa-shared-retrieval-v1.json"
CONFIG = json.loads(CONFIG_PATH.read_text())


class SharedRM:
    def __init__(self, corpus: list[dict[str, str]]) -> None:
        self.corpus = corpus

    def __call__(self, query: str, k: int = 5, **_kwargs: Any) -> list[Passage]:
        query_terms = terms(query)
        ranked = sorted(
            enumerate(self.corpus),
            key=lambda pair: (-len(terms(pair[1]["text"]) & query_terms), pair[0]),
        )
        return [Passage(doc["text"]) for _, doc in ranked[:k]]


@dataclass
class Passage:
    long_text: str


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if getattr(dspy, "__version__", None) != CONFIG["dspy_authority"]["version"]:
        raise SystemExit(
            f'expected dspy {CONFIG["dspy_authority"]["version"]}, '
            f'got {getattr(dspy, "__version__", "unknown")}'
        )

    validate_protocol()

    rows = load_rows(ROOT / CONFIG["dataset"]["path"])
    corpus = build_corpus(rows)
    top_k = CONFIG["retrieval"]["top_k"]
    dspy.configure(rm=SharedRM(corpus))
    retriever = dspy.Retrieve(k=top_k)
    results = []

    for row in rows:
        prediction = retriever(row["question"])
        by_text = {doc["text"]: doc for doc in corpus}
        docs = [dict(by_text[text]) for text in prediction.passages]
        results.append(score_row(row, docs))

    report = {
        "schema_version": 1,
        "runner": "dspy-hotpot-shared-retrieval",
        "protocol_id": CONFIG["protocol_id"],
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "source": source_bindings(),
        "corpus": corpus_identity(corpus),
        "rows": results,
        "summary": summarize(results),
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(out)
    return 0


def load_rows(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def build_corpus(rows: list[dict[str, Any]]) -> list[dict[str, str]]:
    corpus: list[dict[str, str]] = []
    seen: set[str] = set()
    for row in rows:
        for line in row["context"].splitlines():
            title, separator, _body = line.partition(": ")
            if not separator or title in seen:
                continue
            seen.add(title)
            corpus.append({"id": doc_id(title), "title": title, "text": line})
    return corpus


def score_row(row: dict[str, Any], docs: list[dict[str, str]]) -> dict[str, Any]:
    titles = [doc["title"] for doc in docs]
    gold_titles = list(dict.fromkeys(row["supporting_facts"]["title"]))
    found = sum(title in titles for title in gold_titles)
    recall = found / len(gold_titles)
    context = "\n\n".join(doc["text"] for doc in docs)
    answer = row["answer"] if normalize(row["answer"]) in normalize(context) else ""
    return {
        "id": row["id"],
        "question": row["question"],
        "gold_answer": row["answer"],
        "gold_supporting_titles": gold_titles,
        "retrieved_ids": [doc["id"] for doc in docs],
        "retrieved_titles": titles,
        "context_sha256": sha256(context.encode()),
        "supporting_fact_recall": recall,
        "answer": answer,
        "answer_em": 1.0 if normalize(answer) == normalize(row["answer"]) else 0.0,
        "answer_f1": token_f1(answer, row["answer"]),
    }


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    count = len(rows)
    return {
        "rows": count,
        "mean_supporting_fact_recall": sum(r["supporting_fact_recall"] for r in rows) / count,
        "mean_answer_em": sum(r["answer_em"] for r in rows) / count,
        "mean_answer_f1": sum(r["answer_f1"] for r in rows) / count,
    }


def corpus_identity(corpus: list[dict[str, str]]) -> dict[str, Any]:
    encoded = "".join(
        f'{doc["id"]}\0{doc["title"]}\0{doc["text"]}\n' for doc in corpus
    ).encode()
    return {"documents": len(corpus), "sha256": sha256(encoded)}


def source_bindings() -> dict[str, str]:
    authority = CONFIG["dspy_authority"]
    return {
        "repository": authority["repository"],
        "version": authority["version"],
        "commit": authority["commit"],
        "script_sha256": file_sha256(Path(__file__)),
        "config_sha256": file_sha256(CONFIG_PATH),
        "dataset_sha256": file_sha256(ROOT / CONFIG["dataset"]["path"]),
        "manifest_sha256": file_sha256(ROOT / CONFIG["dataset"]["manifest"]),
        "authority_sha256": file_sha256(ROOT / authority["manifest"]),
    }


def validate_protocol() -> None:
    dataset = CONFIG["dataset"]
    manifest = json.loads((ROOT / dataset["manifest"]).read_text())
    actual = hashlib.sha256((ROOT / dataset["path"]).read_bytes()).hexdigest()
    valid = (
        dataset["sha256"] == actual
        and manifest["sha256"] == actual
        and manifest["split"] == dataset["split"]
        and manifest["offset"] == dataset["offset"]
        and manifest["rows"] == dataset["rows"] == 10
        and manifest["length"] == dataset["rows"]
        and manifest["data_path"] == dataset["path"]
        and dataset["license"] == "CC-BY-SA-4.0"
        and manifest["license"] == dataset["license"]
        and manifest["license_notice"] == dataset["license_notice"]
        and (ROOT / dataset["license_notice"]).is_file()
        and CONFIG["retrieval"]["top_k"] == 5
        and isinstance(CONFIG["scorers"], dict)
    )
    if not valid:
        raise RuntimeError("HotPotQA protocol dataset, split, or scorer preregistration is invalid")


def terms(value: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", str(value).lower()))


def normalize(value: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", str(value).lower())
    return " ".join(token for token in tokens if token not in {"a", "an", "the"})


def token_f1(prediction: str, answer: str) -> float:
    pred = normalize(prediction).split()
    gold = normalize(answer).split()
    if not pred or not gold:
        return 0.0
    overlap = sum(min(pred.count(token), gold.count(token)) for token in set(pred))
    if overlap == 0:
        return 0.0
    precision = overlap / len(pred)
    recall = overlap / len(gold)
    return 2 * precision * recall / (precision + recall)


def doc_id(title: str) -> str:
    return hashlib.sha256(title.strip().lower().encode()).hexdigest()[:16]


def sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    return sha256(path.read_bytes())


if __name__ == "__main__":
    raise SystemExit(main())
