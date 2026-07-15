#!/usr/bin/env python3
"""Verify the complete pinned DSPy source target without importing it."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


DSPY_VERSION = "3.3.0b1"
SOURCE_FILE_COUNT = 149
SOURCE_TREE_SHA256 = "282755ac176deb51438b685ad227fdb088ae378404a9c97e7c0fa236c3e06f3a"
REQUIRED_TOP_LEVEL_ENTRIES = {"dspy", f"dspy-{DSPY_VERSION}.dist-info"}
ALLOWED_TOP_LEVEL_ENTRIES = REQUIRED_TOP_LEVEL_ENTRIES | {".lock"}


def verify_target_shape(root: Path) -> None:
    entries = {path.name for path in root.iterdir()}
    if not REQUIRED_TOP_LEVEL_ENTRIES <= entries or not entries <= ALLOWED_TOP_LEVEL_ENTRIES:
        raise RuntimeError(
            "DSPy source target has an invalid top-level shape: "
            f"required {sorted(REQUIRED_TOP_LEVEL_ENTRIES)}, "
            f"allowed {sorted(ALLOWED_TOP_LEVEL_ENTRIES)}, got {sorted(entries)}"
        )

    links = [path.relative_to(root) for path in root.rglob("*") if path.is_symlink()]
    if links:
        raise RuntimeError(f"DSPy source target contains symbolic links: {links}")


def source_files(root: Path) -> list[Path]:
    return sorted(
        path
        for path in (root / "dspy").rglob("*")
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"
    )


def tree_digest(root: Path, files: list[Path]) -> str:
    digest = hashlib.sha256()
    source_root = root / "dspy"
    for path in files:
        relative = path.relative_to(source_root).as_posix().encode("utf-8")
        content = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def verify(root: Path) -> None:
    verify_target_shape(root)

    metadata = root / f"dspy-{DSPY_VERSION}.dist-info" / "METADATA"
    if not metadata.is_file() or f"Version: {DSPY_VERSION}\n" not in metadata.read_text():
        raise RuntimeError(f"DSPy {DSPY_VERSION} package metadata is missing from {root}")

    files = source_files(root)
    actual_digest = tree_digest(root, files)
    if len(files) != SOURCE_FILE_COUNT or actual_digest != SOURCE_TREE_SHA256:
        raise RuntimeError(
            "DSPy source target mismatch: "
            f"expected {SOURCE_FILE_COUNT} files/{SOURCE_TREE_SHA256}, "
            f"got {len(files)} files/{actual_digest}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("target", nargs="?", type=Path, default=Path("tmp/dspy-current-target"))
    args = parser.parse_args()
    verify(args.target)
    print(
        f"DSPy {DSPY_VERSION} source target verified: "
        f"{SOURCE_FILE_COUNT} files, {SOURCE_TREE_SHA256}"
    )


if __name__ == "__main__":
    main()
