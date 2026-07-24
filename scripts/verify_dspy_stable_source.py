#!/usr/bin/env python3
"""Verify the canonical DSPy 3.2.1 source materialization."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


EXPECTED_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
EXPECTED_TAG = "3.2.1"


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(root: Path, manifest_path: Path) -> int:
    if not (root / ".git").is_dir():
        raise RuntimeError(f"DSPy source target is not a Git checkout: {root}")

    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema_version") != 1 or manifest.get("commit") != EXPECTED_COMMIT:
        raise RuntimeError("DSPy authority manifest does not name the expected commit")

    commit = git(root, "rev-parse", "HEAD")
    if commit != EXPECTED_COMMIT:
        raise RuntimeError(f"DSPy commit mismatch: expected {EXPECTED_COMMIT}, got {commit}")

    tags = git(root, "tag", "--points-at", "HEAD").splitlines()
    if EXPECTED_TAG not in tags:
        raise RuntimeError(f"DSPy tag {EXPECTED_TAG} is not present at {commit}")

    status = git(root, "status", "--porcelain", "--untracked-files=all")
    if status:
        raise RuntimeError("DSPy source target is not clean")

    files = manifest.get("files")
    if not isinstance(files, list) or len(files) != 296:
        raise RuntimeError("DSPy authority manifest must contain exactly 296 files")

    for entry in files:
        path = root / entry["path"]
        if not path.is_file():
            raise RuntimeError(f"DSPy authority file is missing: {entry['path']}")
        actual = sha256(path)
        if actual != entry["sha256"]:
            raise RuntimeError(
                f"DSPy authority hash mismatch at {entry['path']}: "
                f"expected {entry['sha256']}, got {actual}"
            )

    return len(files)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("target", nargs="?", type=Path, default=Path("tmp/dspy-3.2.1"))
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("benchmarks/authority_sources/dspy-3.2.1-29448ae.json"),
    )
    args = parser.parse_args()
    count = verify(args.target.resolve(), args.manifest.resolve())
    print(f"DSPy 3.2.1 source verified: {count} authority files at {EXPECTED_COMMIT}")


if __name__ == "__main__":
    main()
