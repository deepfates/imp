#!/usr/bin/env python3
"""Provider-free DSPy 3.2.1 Ensemble observation harness."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Any


CREDENTIAL_MARKERS = (
    "API_KEY",
    "ACCESS_KEY",
    "ACCESS_TOKEN",
    "AUTHORIZATION",
    "AUTH_TOKEN",
    "BEARER_TOKEN",
    "CLIENT_SECRET",
    "CREDENTIAL",
    "DATABASE_URL",
    "PASSWORD",
    "PRIVATE_KEY",
    "SECRET",
    "TOKEN",
)


def credential_names() -> list[str]:
    names = []
    for name in os.environ:
        upper = name.upper()
        if upper == "PGPASSWORD" or any(
            upper == marker or upper.endswith("_" + marker)
            for marker in CREDENTIAL_MARKERS
        ):
            names.append(name)
    return sorted(names)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def verify_source(config: dict[str, Any], root: Path) -> dict[str, Any]:
    source = config["source"]
    commit = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if commit != source["commit"] or dirty:
        raise RuntimeError("DSPy authority checkout is not the pinned clean commit")

    for key in ("ensemble_source", "upstream_test"):
        entry = source[key]
        if sha256(root / entry["path"]) != entry["sha256"]:
            raise RuntimeError(f"DSPy authority hash mismatch: {entry['path']}")

    return {"git_commit": commit, "git_clean": True, "distribution_version": source["version"]}


def observations(config: dict[str, Any]) -> dict[str, Any]:
    os.environ["PYTHON_DOTENV_DISABLED"] = "1"
    os.environ["DOTENV_DISABLED"] = "1"
    if credential_names():
        raise RuntimeError("credential-shaped environment reached the DSPy harness")

    import dspy
    from dspy.teleprompt import Ensemble

    class MockProgram(dspy.Module):
        def __init__(self, value: int):
            super().__init__()
            self.value = value

        def forward(self, *args: Any, **kwargs: Any) -> int:
            del args, kwargs
            return self.value

    fixture = config["fixture"]
    values = fixture["program_values"]
    programs = [MockProgram(value) for value in values]
    all_outputs = Ensemble().compile(programs)()
    reduced = Ensemble(reduce_fn=lambda rows: sum(rows) / len(rows)).compile(programs)()
    subset = Ensemble(size=fixture["subset_size"]).compile(
        [MockProgram(value) for value in fixture["subset_program_values"]]
    )()

    deterministic_rejected = False
    try:
        Ensemble(deterministic=True)
    except AssertionError:
        deterministic_rejected = True

    return {
        "all_program_count": len(all_outputs),
        "reduced_mean": reduced,
        "subset_count": len(subset),
        "dspy_rejects_deterministic": deterministic_rejected,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config_path = Path(args.config).resolve()
    config = load_config(config_path)
    root = Path(os.environ.get("PYTHONPATH", "").split(os.pathsep)[0]).resolve()
    runtime = verify_source(config, root)
    observed = observations(config)
    if observed != config["fixture"]["expected"]:
        raise RuntimeError("DSPy Ensemble observations differ from the pinned fixture")

    print(
        json.dumps(
            {
                "schema_version": 1,
                "fixture_id": config["fixture_id"],
                "status": "passing",
                "provider_free": True,
                "credential_environment": {"provider_credential_names_present": []},
                "runtime_identity": runtime,
                "observations": observed,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
