#!/usr/bin/env python3
"""Load the sealed LM Studio identity, run once, and always clean it up."""

from __future__ import annotations

import json
import subprocess
import urllib.request
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=ROOT, check=check, text=True, capture_output=True)


def require_exact_loaded_identity(identifier: str) -> None:
    loaded = json.loads(run("lms", "ps", "--json").stdout)
    if len(loaded) != 1 or loaded[0].get("identifier") != identifier:
        raise SystemExit(f"LM Studio process identity drift: {loaded!r}")

    with urllib.request.urlopen("http://127.0.0.1:1234/v1/models", timeout=30) as response:
        catalog = json.load(response)
    model_ids = [entry.get("id") for entry in catalog.get("data", [])]
    if model_ids != [identifier]:
        raise SystemExit(f"LM Studio API catalog identity drift: {model_ids!r}")


def main() -> None:
    contract = json.loads((HERE / "contract.json").read_text())
    if contract["status"] != "sealed":
        raise SystemExit("cross-task treatment is not sealed")
    if run("git", "status", "--porcelain", "--untracked-files=all").stdout.strip():
        raise SystemExit("Imp worktree must be clean")

    loaded = json.loads(run("lms", "ps", "--json").stdout)
    if loaded:
        raise SystemExit("LM Studio must begin with no loaded models for this isolated run")

    model = contract["model"]
    identifier = model["runtime_identifier"]
    load = run(
        "lms", "load", model["inventory_key"],
        "--identifier", identifier,
        "--context-length", str(model["context_length"]),
        "--parallel", str(model["parallel"]),
        "--ttl", "3600",
        "--yes",
    )
    print(load.stdout, end="")

    try:
        require_exact_loaded_identity(identifier)
        process = subprocess.run(
            ["mix", "run", str(HERE / "run.exs")],
            cwd=ROOT,
            text=True,
        )
        if process.returncode != 0:
            raise SystemExit(process.returncode)
    finally:
        stopped = run("lms", "unload", identifier, check=False)
        print(stopped.stdout, end="")
        if stopped.returncode != 0:
            print(stopped.stderr, end="")


if __name__ == "__main__":
    main()
