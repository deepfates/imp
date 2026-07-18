#!/usr/bin/env python3
"""Shared source authentication and credential isolation for Avatar C1 fixtures."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, List

ROOT = Path(__file__).resolve().parents[1]
DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
SETUP = """git clone https://github.com/stanfordnlp/dspy.git tmp/dspy-3.2.1
git -C tmp/dspy-3.2.1 checkout --detach 29448ae12756abdd14bd8796c819247ebb83673c
IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh"""

_CREDENTIAL_EXACT = {
    "ACCESS_TOKEN", "API_KEY", "AUTHORIZATION", "AUTH_TOKEN", "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AZURE_CLIENT_SECRET", "CREDENTIALS",
    "DATABASE_URL", "GOOGLE_APPLICATION_CREDENTIALS", "PASSWORD", "PGPASSWORD",
    "PRIVATE_KEY", "SECRET", "TOKEN",
}
_CREDENTIAL_SUFFIXES = (
    "_API_KEY", "_ACCESS_KEY", "_ACCESS_TOKEN", "_AUTH_TOKEN", "_CLIENT_SECRET",
    "_CREDENTIAL", "_CREDENTIALS", "_DATABASE_URL", "_PASSWORD", "_PRIVATE_KEY",
    "_SECRET", "_SECRET_KEY", "_TOKEN",
)


def credential_names(environment: Dict[str, str]) -> List[str]:
    return sorted(
        key for key in environment
        if key.upper() in _CREDENTIAL_EXACT or key.upper().endswith(_CREDENTIAL_SUFFIXES)
    )


def scrubbed_environment(environment: Dict[str, str]) -> Dict[str, str]:
    return {key: value for key, value in environment.items() if key not in credential_names(environment)}


def install_scrubbed_environment() -> None:
    environment = scrubbed_environment(dict(os.environ))
    os.environ.clear()
    os.environ.update(environment)
    os.environ["PYTHON_DOTENV_DISABLED"] = "1"
    os.environ["DOTENV_DISABLED"] = "1"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def authenticate(config: Dict[str, Any], dspy: Any) -> Dict[str, Any]:
    source = config["source"]
    ledger_path = ROOT / "benchmarks/authorities.json"
    ledger = json.loads(ledger_path.read_text())
    family = next((item for item in ledger["families"] if item["id"] == source["authority_family"]), None)
    repository = family and family["upstream_repository"]
    if family is None or repository is None:
        raise SystemExit(f"Avatar authority family is absent. Exact setup:\n{SETUP}")
    for key in ("repository", "version", "git_ref", "commit", "source_manifest"):
        if source[key] != repository[key]:
            raise SystemExit(f"Avatar fixture authority mismatch. Exact setup:\n{SETUP}")

    manifest_path = ROOT / source["source_manifest"]["path"]
    manifest = json.loads(manifest_path.read_text())
    manifest_files = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
    if sha256(manifest_path) != source["source_manifest"]["sha256"]:
        raise SystemExit(f"Avatar authority manifest digest mismatch. Exact setup:\n{SETUP}")
    if len(manifest_files) != source["source_manifest"]["file_count"]:
        raise SystemExit(f"Avatar authority manifest file count mismatch. Exact setup:\n{SETUP}")
    for entry in source["source_files"]:
        if manifest_files.get(entry["path"]) != entry["sha256"]:
            raise SystemExit(f"Avatar source hash mismatch for {entry['path']}. Exact setup:\n{SETUP}")
        if entry["sha256"] not in family["upstream_source_hashes"]:
            raise SystemExit(f"Avatar source is not owned by its family. Exact setup:\n{SETUP}")

    root = Path(dspy.__file__).resolve().parents[1]
    commit = git(root, "rev-parse", "HEAD")
    clean = git(root, "status", "--porcelain") == ""
    tag = git(root, "describe", "--tags", "--exact-match", "HEAD")
    if commit != DSPY_COMMIT or not clean or tag != source["version"]:
        raise SystemExit(f"Unauthenticated DSPy checkout. Exact setup:\n{SETUP}")
    for relative, expected in manifest_files.items():
        path = root / relative
        if not path.is_file() or sha256(path) != expected:
            raise SystemExit(f"DSPy materialization mismatch at {relative}. Exact setup:\n{SETUP}")

    return {
        "distribution_version": importlib.metadata.version("dspy"),
        "module_version": getattr(dspy, "__version__", None),
        "git_commit": commit,
        "git_clean": clean,
        "git_tag": tag,
        "source_root": str(root.relative_to(ROOT)),
        "authority_manifest_verified_files": len(manifest_files),
        "authority_manifest_sha256": sha256(manifest_path),
        "authority_family_sha256": canonical_sha256(family),
    }


def run_isolated(script: Path, config: Path) -> Dict[str, Any]:
    command = [os.environ.get("PYTHON", os.sys.executable), str(script), "--worker", "--config", str(config)]
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        env=scrubbed_environment(dict(os.environ)),
    )
    if completed.returncode:
        raise SystemExit(f"isolated Avatar worker failed:\n{completed.stderr}\n{completed.stdout}")
    report = json.loads(completed.stdout)
    report["isolation"] = {"isolated_process": True}
    return report
