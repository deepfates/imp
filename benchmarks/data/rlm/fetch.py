#!/usr/bin/env python3
"""Fetch, verify, and normalize the public RLM benchmark families."""

import argparse
import hashlib
import importlib.util
import json
import os
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROVENANCE_PATH = ROOT / "provenance.json"


def load_normalizer():
    spec = importlib.util.spec_from_file_location("rlm_normalize", ROOT / "normalize.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load normalize.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, destination, expected_sha256):
    if destination.exists() and sha256(destination) == expected_sha256:
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    partial.unlink(missing_ok=True)

    request = urllib.request.Request(url, headers={"User-Agent": "dsex-rlm-data/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, partial.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())

        actual = sha256(partial)
        if actual != expected_sha256:
            raise ValueError(
                f"source digest mismatch for {destination.name}: "
                f"expected {expected_sha256}, got {actual}"
            )
        os.replace(partial, destination)
    finally:
        partial.unlink(missing_ok=True)


def materialize(family, provenance, cache, normalizer):
    spec = provenance["families"][family]
    if family == "longbench_v2_codeqa":
        source_file = spec["source_file"]
        source_path = cache / f"{family}-{Path(source_file).name}"
        url = f"{spec['source']}/resolve/{spec['revision']}/{source_file}?download=true"
        download(url, source_path, spec["source_file_sha256"])
        output = ROOT / "longbench_v2_codeqa.jsonl"
        normalizer.normalize_codeqa(source_path, output)
    elif family == "oolong":
        source_file = spec["source_file"]
        source_path = cache / f"{family}-{Path(source_file).name}"
        url = f"{spec['source']}/resolve/{spec['revision']}/{source_file}?download=true"
        download(url, source_path, spec["source_file_sha256"])
        output = ROOT / "oolong_trec_coarse.jsonl"
        normalizer.normalize_oolong(source_path, output)
    elif family == "oolong_pairs":
        questions_path = cache / f"{family}-questions.json"
        questions_url = f"{spec['source']}/resolve/{spec['revision']}/{spec['questions_source_file']}?download=true"
        download(questions_url, questions_path, spec["questions_sha256"])

        answers_dir = cache / f"{family}-answers"
        answers_dir.mkdir(parents=True, exist_ok=True)
        for source_file, expected_sha256 in spec["gold_source_files"].items():
            answer_path = answers_dir / Path(source_file).name
            answer_url = f"{spec['source']}/resolve/{spec['revision']}/{source_file}?download=true"
            download(answer_url, answer_path, expected_sha256)

        context_paths = []
        for source_file, expected_sha256 in spec["context_source_files"].items():
            context_path = cache / f"{family}-{Path(source_file).name}"
            context_url = f"{spec['context_source']}/resolve/{spec['context_revision']}/{source_file}?download=true"
            download(context_url, context_path, expected_sha256)
            context_paths.append(context_path)

        output = ROOT / "oolong_pairs_trec_coarse.jsonl"
        normalizer.normalize_oolong_pairs(questions_path, answers_dir, context_paths, output)
    else:
        raise ValueError(f"unsupported complete family: {family}")

    actual = sha256(output)
    expected = spec["normalized_sha256"]
    if actual != expected:
        output.unlink(missing_ok=True)
        raise ValueError(
            f"normalized digest mismatch for {family}: expected {expected}, got {actual}"
        )
    return {"family": family, "path": str(output), "sha256": actual}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--family",
        action="append",
        choices=["longbench_v2_codeqa", "oolong", "oolong_pairs"],
        help="family to materialize; repeatable (default: both)",
    )
    parser.add_argument("--cache", type=Path, default=ROOT / ".cache")
    args = parser.parse_args()

    provenance = json.loads(PROVENANCE_PATH.read_text(encoding="utf-8"))
    normalizer = load_normalizer()
    families = args.family or ["longbench_v2_codeqa", "oolong"]
    results = [materialize(name, provenance, args.cache, normalizer) for name in families]
    print(json.dumps({"complete": True, "results": results}, sort_keys=True))


if __name__ == "__main__":
    main()
