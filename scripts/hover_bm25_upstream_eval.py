#!/usr/bin/env python3
"""Evaluate upstream GEPA HoVer BM25 retrieval for DSEx parity checks."""

from __future__ import annotations

import argparse
import json
import sys
import types
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True)
    parser.add_argument("--query", required=True)
    parser.add_argument("--k", type=int, default=24)
    args = parser.parse_args()

    gepa_root = Path(args.gepa_root).resolve()
    sys.path.insert(0, str(gepa_root))
    stub_dspy()

    from gepa_artifact.benchmarks.hover.hover_program import search

    result = search(args.query, args.k)
    docs = list(getattr(result, "passages", []))

    json.dump(
        {
            "query": args.query,
            "k": args.k,
            "retrieved_docs": docs,
            "titles": [doc.split(" | ", 1)[0] for doc in docs],
        },
        sys.stdout,
    )
    sys.stdout.write("\n")
    return 0


def stub_dspy() -> None:
    if "dspy" in sys.modules:
        return

    module = types.ModuleType("dspy")
    module.Module = object

    class Prediction(dict):
        def __init__(self, **kwargs):
            super().__init__(**kwargs)
            self.__dict__.update(kwargs)

    module.Prediction = Prediction

    class Predict:
        def __init__(self, *_args, **_kwargs):
            pass

    module.Predict = Predict
    module.ChainOfThought = Predict

    evaluate = types.SimpleNamespace(
        normalize_text=lambda value: " ".join(str(value).lower().split())
    )
    module.evaluate = evaluate
    sys.modules["dspy"] = module
    sys.modules["dspy.evaluate"] = evaluate


if __name__ == "__main__":
    raise SystemExit(main())
