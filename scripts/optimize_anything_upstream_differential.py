#!/usr/bin/env python3
"""Pinned authority runner for Imp's Optimize Anything differential.

Python is used only for the public upstream implementation and the shared
external evaluators. The Imp optimizer under comparison remains BEAM-native.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import hmac
import io
import json
import math
import os
import secrets
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from upstream_authority_registry import (  # noqa: E402
    REGISTRY_PATH,
    load_registry_authority,
)


DEFAULT_MANIFEST = (
    ROOT / "benchmarks/config/optimize-anything-upstream-differential-v1.json"
)
PROTOCOL_CONTRACT_ID = "optimize_anything_upstream_differential_protocol"
SWE_BENCH_CONTRACT_ID = "optimize_anything_swe_bench_flask_5014_dataset"
SWE_BENCH_PARQUET = ROOT / "tmp/swe-bench-verified.parquet"
SWE_BENCH_PARQUET_KEY = "data/test-00000-of-00001.parquet"
SWE_BENCH_ROW_KEY = "rows/pallets__flask-5014.canonical-json"
ISOLATION_MODE = "macos_sandbox_exec_deny_default_v1"
SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
MAX_JSON_FRAME_BYTES = 1_000_000
MAX_JSON_DEPTH = 16
MAX_JSON_NODES = 20_000
MAX_JUNIT_REPORT_BYTES = 1_000_000
CANDIDATE_FRAME_SCHEMA_VERSION = 1
FLASK_PATCH_POLICY_ID = "flask_empty_name_guard_ast_v1"
IMPORTABLE_SUFFIXES = {".py", ".so", ".pyd", ".dylib", ".pth", ".egg-link"}

V1_CONTROLS = {
    "seeds": [0, 1, 2],
    "max_candidate_proposals": 2,
    "parallel": False,
    "max_workers": 1,
    "cache_evaluation": False,
    "reflection_minibatch_size": 1,
    "candidate_selection_strategy": "pareto",
    "frontier_type": "hybrid",
    "model": {
        "provider": "anthropic",
        "upstream_name": "anthropic/claude-haiku-4-5-20251001",
        "imp_name": "anthropic:claude-haiku-4-5-20251001",
        "temperature": 0,
        "max_tokens": 4096,
        "upstream_retries": 3,
        "imp_retries": 3,
        "imp_retry_base_delay_ms": 1000,
        "imp_retry_max_delay_ms": 4000,
    },
}
V1_EVALUATORS = {
    "circle_packing_26": {"timeout_seconds": 20, "random_seed": 0, "num_circles": 26},
    "blackbox_problem_46": {
        "problem_index": 46,
        "objective_call_budget": 20,
        "timeout_seconds": 12,
        "random_seed": 0,
    },
    "swe_bench_flask_5014": {
        "fail_to_pass_weight": 0.8,
        "pass_to_pass_weight": 0.2,
        "test_timeout_seconds": 30,
    },
}
FLASK_SEED_PATCH = """diff --git a/src/flask/blueprints.py b/src/flask/blueprints.py
--- a/src/flask/blueprints.py
+++ b/src/flask/blueprints.py
@@ -190,6 +190,7 @@ def __init__(
             root_path=root_path,
         )
\x20
+        # Blueprint name validation follows.
         if "." in name:
             raise ValueError("'name' may not contain a dot '.' character.")
\x20
"""


class ProtocolError(RuntimeError):
    """Raised when a protocol input or pinned authority is invalid."""


def load_canonical_authorities(
    registry_path: Path = REGISTRY_PATH,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    try:
        protocol_registry, protocol = load_registry_authority(
            PROTOCOL_CONTRACT_ID, registry_path
        )
        dataset_registry, dataset = load_registry_authority(
            SWE_BENCH_CONTRACT_ID, registry_path
        )
    except RuntimeError as exc:
        raise ProtocolError(
            f"cannot load canonical Optimize Anything authorities: {exc}"
        ) from exc
    if protocol_registry != dataset_registry:
        raise ProtocolError(
            "canonical Optimize Anything authority registry changed while loading"
        )
    return protocol_registry, protocol, dataset


def canonical_dataset_name(authority: dict[str, Any]) -> str:
    marker = "/datasets/"
    repository = authority["repository"]
    if marker not in repository:
        raise ProtocolError(
            "canonical SWE-bench authority is not a Hugging Face dataset URL"
        )
    return repository.split(marker, 1)[1]


class QuietLogger:
    def log(self, _message: str) -> None:
        return None


class CountingLM:
    def __init__(self, inner: Any):
        self.inner = inner
        self.calls = 0

    @property
    def total_cost(self) -> float:
        return float(self.inner.total_cost)

    @property
    def total_tokens_in(self) -> int:
        return int(self.inner.total_tokens_in)

    @property
    def total_tokens_out(self) -> int:
        return int(self.inner.total_tokens_out)

    def __call__(self, prompt: Any) -> str:
        self.calls += 1
        return self.inner(prompt)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def candidate_sha256(candidate: str) -> str:
    return sha256_bytes(candidate.encode("utf-8"))


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"cannot load protocol manifest {path}: {exc}") from exc

    required = {
        "schema_version",
        "protocol_id",
        "protocol_class",
        "authority",
        "swe_bench",
        "controls",
        "reflection_template",
        "domains",
    }
    missing = (
        sorted(required - set(manifest))
        if isinstance(manifest, dict)
        else sorted(required)
    )
    if missing:
        raise ProtocolError(
            f"protocol manifest is missing required fields: {', '.join(missing)}"
        )
    if manifest["schema_version"] != 1:
        raise ProtocolError("protocol manifest schema_version must be 1")
    if manifest["protocol_id"] != "optimize_anything_upstream_differential_v1":
        raise ProtocolError(
            "protocol manifest protocol_id is not the canonical v1 identity"
        )
    if manifest["protocol_class"] != "adapted_matched_runtime_differential":
        raise ProtocolError(
            "protocol manifest protocol_class is not the canonical v1 identity"
        )
    if not isinstance(manifest["domains"], list) or len(manifest["domains"]) != 3:
        raise ProtocolError("protocol manifest must define exactly three domains")

    domain_ids = [
        domain.get("id") for domain in manifest["domains"] if isinstance(domain, dict)
    ]
    expected_ids = ["circle_packing_26", "blackbox_problem_46", "swe_bench_flask_5014"]
    if domain_ids != expected_ids:
        raise ProtocolError(
            f"protocol domains must be ordered exactly as {expected_ids!r}"
        )

    template = manifest["reflection_template"]
    if not isinstance(template, str):
        raise ProtocolError("reflection_template must be a string")
    for placeholder in ("<objective>", "<background>", "<curr_param>", "<side_info>"):
        if template.count(placeholder) != 1:
            raise ProtocolError(
                f"reflection_template must contain {placeholder} exactly once"
            )

    controls = manifest["controls"]
    if controls != V1_CONTROLS:
        raise ProtocolError(
            "protocol manifest controls/model differ from the canonical v1 constants"
        )
    for domain in manifest["domains"]:
        if domain.get("evaluator") != V1_EVALUATORS[domain["id"]]:
            raise ProtocolError(
                f"protocol evaluator parameters differ from canonical v1 for {domain['id']}"
            )

    _, protocol_authority, dataset_authority = load_canonical_authorities()
    authority = manifest["authority"]
    expected_authority = {
        "repository": protocol_authority["repository"],
        "commit": protocol_authority["commit"],
        "source_hashes": protocol_authority["source_hashes"],
    }
    for key, expected in expected_authority.items():
        if authority.get(key) != expected:
            raise ProtocolError(
                f"protocol manifest authority.{key} differs from canonical registry authority"
            )

    swe = manifest["swe_bench"]
    expected_swe = {
        "dataset": canonical_dataset_name(dataset_authority),
        "dataset_revision": dataset_authority["commit"],
        "parquet_sha256": dataset_authority["source_hashes"][SWE_BENCH_PARQUET_KEY],
        "instance_id": dataset_authority["metadata"]["instance_id"],
        "environment_setup_commit": dataset_authority["metadata"][
            "environment_setup_commit"
        ],
    }
    for key, expected in expected_swe.items():
        if swe.get(key) != expected:
            raise ProtocolError(
                f"protocol manifest swe_bench.{key} differs from canonical registry authority"
            )
    return manifest


def resolve(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise ProtocolError(f"path escapes repository root: {relative}") from exc
    return path


def git_output(repository: Path, *args: str) -> str:
    process = subprocess.run(
        ["git", "-C", str(repository), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip()
        raise ProtocolError(f"git {' '.join(args)} failed for {repository}: {detail}")
    return process.stdout.strip()


def verify_pristine_checkout(
    repository: Path, label: str, import_roots: tuple[str, ...]
) -> None:
    drift = git_output(
        repository, "status", "--porcelain=v1", "--untracked-files=all"
    )
    if drift:
        raise ProtocolError(
            f"{label} authority is not pristine; tracked or untracked drift is present"
        )

    ignored = git_output(
        repository,
        "ls-files",
        "--others",
        "--ignored",
        "--exclude-standard",
        "--",
        *import_roots,
    )
    ignored_importables = sorted(
        path
        for path in ignored.splitlines()
        if Path(path).suffix.lower() in IMPORTABLE_SUFFIXES
    )
    if ignored_importables:
        raise ProtocolError(
            f"{label} authority contains ignored importable files: "
            + ", ".join(ignored_importables[:10])
        )


_ARCHIVE_CACHE: dict[
    tuple[str, str], tuple[tempfile.TemporaryDirectory[str], Path]
] = {}
_AUTHORITY_WORKTREE_PATHS: set[str] = set()


def materialize_pinned_archive(
    repository: Path, revision: str, label: str
) -> Path:
    key = (str(repository.resolve()), revision)
    cached = _ARCHIVE_CACHE.get(key)
    if cached is not None:
        return cached[1]

    temporary = tempfile.TemporaryDirectory(prefix=f"imp-oa-{label}-authority-")
    destination = Path(temporary.name).resolve()
    try:
        archive_checkout(repository, destination, revision=revision)
    except Exception:
        temporary.cleanup()
        raise
    _ARCHIVE_CACHE[key] = (temporary, destination)
    return destination


def canonical_json_sha256(value: Any) -> str:
    payload = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return sha256_bytes(payload)


def flask_runtime_identity(python: Path) -> dict[str, Any]:
    """Bind the local Flask test interpreter and its installed package manifest."""
    resolved = python.resolve()
    if not resolved.is_file():
        raise ProtocolError(f"pinned Flask test environment is missing: {python}")
    probe = r"""
import importlib.metadata
import hashlib
import json
import platform
import sys

distributions = []
for distribution in importlib.metadata.distributions():
    name = distribution.metadata.get("Name")
    version = distribution.version
    if name and version:
        files = []
        for relative in sorted(distribution.files or [], key=str):
            path = distribution.locate_file(relative)
            if path.is_file():
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
            else:
                digest = "missing"
            files.append([str(relative), digest])
        content = json.dumps(files, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        distributions.append({
            "name": name.lower().replace("_", "-"),
            "version": version,
            "installed_file_count": len(files),
            "installed_files_sha256": hashlib.sha256(content).hexdigest(),
        })

print(json.dumps({
    "implementation": platform.python_implementation(),
    "python_version": platform.python_version(),
    "cache_tag": sys.implementation.cache_tag,
    "platform_system": platform.system(),
    "platform_release": platform.release(),
    "platform_machine": platform.machine(),
    "distributions": sorted(
        distributions,
        key=lambda row: (row["name"], row["version"], row["installed_files_sha256"]),
    ),
}, sort_keys=True, separators=(",", ":")))
"""
    process = subprocess.run(
        [str(python), "-I", "-c", probe],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
        env={
            "HOME": tempfile.gettempdir(),
            "PATH": os.pathsep.join((str(python.parent), "/usr/bin", "/bin")),
            "PYTHONNOUSERSITE": "1",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        },
    )
    if process.returncode != 0:
        raise ProtocolError(
            "cannot inventory pinned Flask test runtime: "
            + compact_text(process.stderr.strip(), 500)
        )
    try:
        manifest = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise ProtocolError("pinned Flask test runtime inventory is invalid") from exc
    if not isinstance(manifest, dict) or not isinstance(manifest.get("distributions"), list):
        raise ProtocolError("pinned Flask test runtime inventory is incomplete")
    return {
        "schema_version": 1,
        "interpreter_sha256": sha256_file(resolved),
        "installed_distribution_manifest": manifest,
        "installed_distribution_manifest_sha256": canonical_json_sha256(manifest),
        "lock_kind": "installed_distribution_manifest",
        "cross_platform_reproducible": False,
        "reproducibility_scope": (
            "content-identical interpreter and installed-distribution manifest "
            "on the recorded OS release and architecture"
        ),
        "residual_limitation": (
            "installed distribution metadata and file content are bound, but this is not a "
            "cross-platform resolver lock or container image"
        ),
    }


def verify_swe_bench_dataset(
    manifest: dict[str, Any], flask: Path, dataset_authority: dict[str, Any]
) -> dict[str, Any]:
    expected_parquet = dataset_authority["source_hashes"][SWE_BENCH_PARQUET_KEY]
    expected_row = dataset_authority["source_hashes"][SWE_BENCH_ROW_KEY]
    if not SWE_BENCH_PARQUET.is_file():
        raise ProtocolError(
            f"SWE-bench parquet authority unavailable locally: {SWE_BENCH_PARQUET}"
        )
    actual_parquet = sha256_file(SWE_BENCH_PARQUET)
    if actual_parquet != expected_parquet:
        raise ProtocolError(
            "SWE-bench parquet hash mismatch: "
            f"expected {expected_parquet}, got {actual_parquet}"
        )

    try:
        import pyarrow.parquet as parquet
    except ImportError as exc:
        raise ProtocolError(
            "SWE-bench parquet row verification unavailable: pyarrow is not installed"
        ) from exc
    try:
        table = parquet.read_table(SWE_BENCH_PARQUET)
        rows = [
            row
            for row in table.to_pylist()
            if row.get("instance_id") == dataset_authority["metadata"]["instance_id"]
        ]
    except Exception as exc:
        raise ProtocolError(
            f"cannot read canonical SWE-bench parquet authority: {exc}"
        ) from exc
    if len(rows) != 1:
        raise ProtocolError(
            "canonical SWE-bench parquet must contain exactly one pallets__flask-5014 row"
        )
    row = rows[0]
    actual_row = canonical_json_sha256(row)
    if actual_row != expected_row:
        raise ProtocolError(
            f"SWE-bench Flask row hash mismatch: expected {expected_row}, got {actual_row}"
        )

    try:
        fail_to_pass = json.loads(row["FAIL_TO_PASS"])
        pass_to_pass = json.loads(row["PASS_TO_PASS"])
    except (KeyError, TypeError, json.JSONDecodeError) as exc:
        raise ProtocolError(
            f"canonical SWE-bench Flask row has invalid test lists: {exc}"
        ) from exc

    swe = manifest["swe_bench"]
    row_identity = {
        "instance_id": row.get("instance_id"),
        "base_commit": row.get("base_commit"),
        "environment_setup_commit": row.get("environment_setup_commit"),
        "reference_patch": row.get("patch"),
        "test_patch": row.get("test_patch"),
        "fail_to_pass": fail_to_pass,
        "pass_to_pass": pass_to_pass,
        "repository": f"https://github.com/{row.get('repo')}",
    }
    for key, expected in row_identity.items():
        if swe.get(key) != expected:
            raise ProtocolError(
                f"protocol manifest swe_bench.{key} differs from the verified canonical row"
            )

    setup_commit = dataset_authority["metadata"]["environment_setup_commit"]
    try:
        resolved_setup = git_output(
            flask, "rev-parse", "--verify", f"{setup_commit}^{{commit}}"
        )
    except ProtocolError as exc:
        raise ProtocolError(
            "SWE-bench environment setup authority unavailable locally: "
            f"Flask repository does not contain commit {setup_commit}"
        ) from exc
    if resolved_setup != setup_commit:
        raise ProtocolError(
            f"SWE-bench environment setup authority mismatch: expected {setup_commit}, got {resolved_setup}"
        )

    return {
        "parquet_path": str(SWE_BENCH_PARQUET.relative_to(ROOT)),
        "parquet_sha256": actual_parquet,
        "row_sha256": actual_row,
        "environment_setup_commit": resolved_setup,
        "environment_setup_verification": "git_commit_object_present",
    }


def verify_authorities(manifest: dict[str, Any]) -> dict[str, Any]:
    _, authority, dataset_authority = load_canonical_authorities()
    upstream = resolve(ROOT, manifest["authority"]["workspace"])
    if not upstream.is_dir():
        raise ProtocolError(
            f"pinned Optimize Anything workspace is missing: {upstream}"
        )
    actual_commit = git_output(upstream, "rev-parse", "HEAD")
    if actual_commit != authority["commit"]:
        raise ProtocolError(
            f"Optimize Anything authority commit mismatch: expected {authority['commit']}, got {actual_commit}"
        )
    verify_pristine_checkout(
        upstream, "Optimize Anything", ("src", "examples")
    )
    _AUTHORITY_WORKTREE_PATHS.update(
        {str(upstream.resolve()), str((upstream / "src").resolve())}
    )
    upstream_archive = materialize_pinned_archive(
        upstream, authority["commit"], "upstream"
    )

    verified_sources: dict[str, str] = {}
    for relative, expected in authority["source_hashes"].items():
        path = resolve(upstream_archive, relative)
        if not path.is_file():
            raise ProtocolError(f"pinned authority source is missing: {relative}")
        actual = sha256_file(path)
        if actual != expected:
            raise ProtocolError(
                f"pinned authority source hash mismatch for {relative}: expected {expected}, got {actual}"
            )
        verified_sources[relative] = actual

    swe = manifest["swe_bench"]
    flask = resolve(ROOT, swe["workspace"])
    if not flask.is_dir():
        raise ProtocolError(f"pinned Flask workspace is missing: {flask}")
    flask_commit = git_output(flask, "rev-parse", "HEAD")
    if flask_commit != swe["base_commit"]:
        raise ProtocolError(
            f"Flask authority commit mismatch: expected {swe['base_commit']}, got {flask_commit}"
        )
    verify_pristine_checkout(flask, "Flask", ("src", "tests"))
    flask_archive = materialize_pinned_archive(flask, swe["base_commit"], "flask")
    flask_source = resolve(flask_archive, swe["source_path"])
    actual_flask_hash = sha256_file(flask_source)
    if actual_flask_hash != swe["source_sha256"]:
        raise ProtocolError(
            f"Flask source hash mismatch: expected {swe['source_sha256']}, got {actual_flask_hash}"
        )

    dataset_verification = verify_swe_bench_dataset(manifest, flask, dataset_authority)
    isolation = verify_candidate_isolation()
    flask_python = flask / ".venv/bin/python"
    flask_runtime = flask_runtime_identity(flask_python)

    return {
        "upstream": upstream_archive,
        "flask": flask_archive,
        "flask_python": flask_python,
        "flask_runtime": flask_runtime,
        "source_materialization": "git_archive_of_pinned_commit",
        "source_hashes": verified_sources,
        "flask_source_sha256": actual_flask_hash,
        "protocol_authority": authority,
        "dataset_authority": dataset_authority,
        "dataset_verification": dataset_verification,
        "isolation": isolation,
    }


def activate_authority(upstream: Path) -> None:
    paths = [str(upstream / "src"), str(upstream)]
    sys.path[:] = [
        entry
        for entry in sys.path
        if not entry
        or str(Path(entry).resolve()) not in _AUTHORITY_WORKTREE_PATHS
    ]
    for path in reversed(paths):
        if path not in sys.path:
            sys.path.insert(0, path)

    os.environ["PYTHONPATH"] = os.pathsep.join(paths)


def domain_config(manifest: dict[str, Any], domain_id: str) -> dict[str, Any]:
    for domain in manifest["domains"]:
        if domain["id"] == domain_id:
            return domain
    raise ProtocolError(f"unknown protocol domain: {domain_id}")


def reflection_template(manifest: dict[str, Any], domain: dict[str, Any]) -> str:
    return (
        manifest["reflection_template"]
        .replace("<objective>", domain["objective"])
        .replace("<background>", domain["background"])
    )


def seed_candidate(manifest: dict[str, Any], domain_id: str, upstream: Path) -> str:
    activate_authority(upstream)
    if domain_id == "circle_packing_26":
        from examples.circle_packing.main import SEED_CODE

        return SEED_CODE.strip() + "\n"
    if domain_id == "blackbox_problem_46":
        from examples.blackbox.main import SEED_CODE

        return SEED_CODE.strip() + "\n"
    if domain_id == "swe_bench_flask_5014":
        return FLASK_SEED_PATCH
    raise ProtocolError(f"unknown protocol domain: {domain_id}")


def compact_text(value: Any, limit: int = 4000) -> str:
    text = "" if value is None else str(value)
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n...[truncated {len(text) - limit} characters]"


def isolation_report() -> dict[str, Any]:
    return {
        "mode": ISOLATION_MODE,
        "required": True,
        "environment": "fixed_allowlist_no_inherited_credentials",
        "filesystem": "deny_default_ephemeral_write_roots",
        "network": "denied_except_authenticated_objective_unix_socket",
        "candidate_output": "discarded_not_persisted",
    }


def _path_rule(kind: str, path: Path) -> str:
    return f"({kind} {json.dumps(str(path.resolve()))})"


def _read_roots(python: Path, extra: tuple[Path, ...] = ()) -> tuple[Path, ...]:
    candidates = [
        python,
        python.resolve(),
        python.parent.parent,
        python.resolve().parent.parent,
        *extra,
    ]
    for system_path in (
        Path("/etc/apache2/mime.types"),
        Path("/etc/httpd/mime.types"),
        Path("/etc/httpd/conf/mime.types"),
        Path("/etc/mime.types"),
    ):
        if system_path.exists():
            candidates.append(system_path)
    unique: dict[str, Path] = {}
    for candidate in candidates:
        if candidate.exists():
            resolved = candidate.resolve()
            unique[str(resolved)] = resolved
    return tuple(unique.values())


def _sandbox_profile(
    python: Path,
    writable_root: Path,
    *,
    extra_read_roots: tuple[Path, ...] = (),
    extra_write_roots: tuple[Path, ...] = (),
    objective_socket: Path | None = None,
) -> str:
    executable_rules = (
        "(require-any "
        + " ".join(
            f"(literal {json.dumps(str(path))})" for path in {python, python.resolve()}
        )
        + ")"
    )
    read_rules = (
        "(require-any "
        + " ".join(
            _path_rule("subpath" if path.is_dir() else "literal", path)
            for path in _read_roots(python, (*extra_read_roots, writable_root))
        )
        + ")"
    )
    write_rules = (
        "(require-any "
        + " ".join(
            _path_rule("subpath", path) for path in (writable_root, *extra_write_roots)
        )
        + ")"
    )
    network_rule = ""
    if objective_socket is not None:
        network_rule = (
            "(allow network-outbound "
            f"(remote unix-socket (path-literal {json.dumps(str(objective_socket.resolve()))})))"
        )
    return f"""(version 1)
(deny default)
(import "system.sb")
(allow process-exec {executable_rules})
(allow signal (target self))
(allow file-read-metadata file-test-existence)
(allow file-read* file-test-existence {read_rules})
(allow file-write* {write_rules})
{network_rule}
"""


def _candidate_environment(
    root: Path, python: Path, pythonpath: tuple[Path, ...] = ()
) -> dict[str, str]:
    return {
        "HOME": str(root / "home"),
        "TMPDIR": str(root / "tmp"),
        "PATH": os.pathsep.join((str(python.parent), "/usr/bin", "/bin")),
        "PYTHONPATH": os.pathsep.join(str(path.resolve()) for path in pythonpath),
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "OMP_NUM_THREADS": "1",
        "OPENBLAS_NUM_THREADS": "1",
        "VECLIB_MAXIMUM_THREADS": "1",
    }


_ISOLATION_VERIFIED: dict[str, Any] | None = None
_ISOLATION_LOCK = threading.Lock()
_CANDIDATE_LAUNCH_LOCK = threading.Lock()


def verify_candidate_isolation(
    *, sandbox_exec: Path = SANDBOX_EXEC, force: bool = False
) -> dict[str, Any]:
    global _ISOLATION_VERIFIED
    if not force and sandbox_exec == SANDBOX_EXEC and _ISOLATION_VERIFIED is not None:
        return dict(_ISOLATION_VERIFIED)
    if sys.platform != "darwin":
        raise ProtocolError(
            f"candidate isolation unavailable: {ISOLATION_MODE} requires macOS"
        )
    if not sandbox_exec.is_file() or not os.access(sandbox_exec, os.X_OK):
        raise ProtocolError(
            f"candidate isolation unavailable: sandbox-exec is missing at {sandbox_exec}"
        )

    with (
        _ISOLATION_LOCK,
        tempfile.TemporaryDirectory(prefix="imp-oa-isolation-probe-") as raw,
    ):
        root = Path(raw).resolve()
        (root / "home").mkdir(mode=0o700)
        (root / "tmp").mkdir(mode=0o700)
        python = Path(sys.executable)
        profile = _sandbox_profile(python, root)
        descriptor, denied_path = tempfile.mkstemp(prefix="imp-oa-denied-")
        os.write(descriptor, b"host-secret")
        os.close(descriptor)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        denied_socket = root / "denied.sock"
        listener.bind(str(denied_socket))
        listener.listen(1)
        probe = """
import errno, os, socket, sys
if os.environ.get('IMP_OA_PROBE_SECRET') is not None:
    raise SystemExit(40)
try:
    open(sys.argv[1], 'rb').read()
    raise SystemExit(41)
except OSError as exc:
    if exc.errno not in (errno.EPERM, errno.EACCES):
        raise
try:
    open(sys.argv[1] + '.write', 'w').write('x')
    raise SystemExit(42)
except OSError as exc:
    if exc.errno not in (errno.EPERM, errno.EACCES):
        raise
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(sys.argv[2])
    raise SystemExit(43)
except OSError as exc:
    if exc.errno not in (errno.EPERM, errno.EACCES):
        raise
"""
        try:
            process = subprocess.run(
                [
                    str(sandbox_exec),
                    "-p",
                    profile,
                    str(python),
                    "-c",
                    probe,
                    denied_path,
                    str(denied_socket),
                ],
                cwd=root,
                env=_candidate_environment(root, python),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ProtocolError(
                f"candidate isolation unavailable: sandbox probe failed: {exc}"
            ) from exc
        finally:
            listener.close()
            Path(denied_path).unlink(missing_ok=True)
            Path(denied_path + ".write").unlink(missing_ok=True)
        if process.returncode != 0:
            detail = process.stderr.decode("utf-8", errors="replace").strip()
            raise ProtocolError(
                "candidate isolation unavailable: sandbox policy probe was not enforced"
                + (f" ({compact_text(detail, 500)})" if detail else "")
            )

    report = isolation_report()
    if not force and sandbox_exec == SANDBOX_EXEC:
        _ISOLATION_VERIFIED = dict(report)
    return report


class _DiscardedOutputProcess:
    def __init__(self, process: subprocess.Popen[bytes]):
        self._process = process

    def communicate(self, *args: Any, **kwargs: Any) -> tuple[bytes, bytes]:
        self._process.communicate(*args, **kwargs)
        return b"", b""

    def __getattr__(self, name: str) -> Any:
        return getattr(self._process, name)


class CandidateSandbox:
    def __init__(
        self,
        python: Path,
        *,
        pythonpath: tuple[Path, ...] = (),
        read_roots: tuple[Path, ...] = (),
        write_roots: tuple[Path, ...] = (),
        objective_proxy: bool = False,
    ):
        verify_candidate_isolation()
        self.python = python
        self.pythonpath = pythonpath
        self.read_roots = read_roots
        self.write_roots = write_roots
        self._temporary = tempfile.TemporaryDirectory(prefix="imp-oa-candidate-")
        self.root = Path(self._temporary.name).resolve()
        (self.root / "home").mkdir(mode=0o700)
        (self.root / "tmp").mkdir(mode=0o700)
        self.objective_socket = (
            self.root / "objective.sock" if objective_proxy else None
        )
        self.profile = _sandbox_profile(
            python,
            self.root,
            extra_read_roots=read_roots,
            extra_write_roots=write_roots,
            objective_socket=self.objective_socket,
        )
        self.environment = _candidate_environment(self.root, python, pythonpath)

    def close(self) -> None:
        self._temporary.cleanup()

    def command(self, command: list[str]) -> list[str]:
        if not command or Path(command[0]).resolve() != self.python.resolve():
            raise ProtocolError("candidate launcher attempted an unexpected executable")
        return [str(SANDBOX_EXEC), "-p", self.profile, *command]

    @contextmanager
    def interpose_upstream_popen(self):
        original_popen = subprocess.Popen
        original_tempdir = tempfile.tempdir

        def sandboxed_popen(command: list[str], *args: Any, **kwargs: Any) -> Any:
            kwargs["cwd"] = self.root
            kwargs["env"] = self.environment
            kwargs["stdout"] = subprocess.DEVNULL
            kwargs["stderr"] = subprocess.DEVNULL
            process = original_popen(self.command(list(command)), *args, **kwargs)
            return _DiscardedOutputProcess(process)

        with _CANDIDATE_LAUNCH_LOCK:
            tempfile.tempdir = str(self.root / "tmp")
            subprocess.Popen = sandboxed_popen  # type: ignore[assignment]
            try:
                yield
            finally:
                subprocess.Popen = original_popen  # type: ignore[assignment]
                tempfile.tempdir = original_tempdir

    def run(
        self, command: list[str], *, cwd: Path, timeout: int
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            self.command(command),
            cwd=cwd,
            env=self.environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )


def _json_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object key: {key}")
        value[key] = item
    return value


def _finite_json_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError("non-finite JSON number")
    return parsed


def load_bounded_json_bytes(payload: bytes, *, label: str) -> Any:
    """Decode a strict, duplicate-free, finite and structurally bounded JSON frame."""
    if not payload or len(payload) > MAX_JSON_FRAME_BYTES:
        raise ProtocolError(f"{label} exceeds the protocol limit")
    try:
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=_json_no_duplicates,
            parse_float=_finite_json_float,
            parse_constant=lambda constant: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON constant: {constant}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise ProtocolError(f"{label} is not valid strict JSON") from exc
    _bounded_json_value(value, label=label)
    return value


def _bounded_json_value(
    value: Any,
    *,
    depth: int = 0,
    nodes: list[int] | None = None,
    label: str = "candidate JSON frame",
) -> None:
    if nodes is None:
        nodes = [0]
    if depth > MAX_JSON_DEPTH:
        raise ProtocolError(f"{label} exceeds the nesting limit")
    nodes[0] += 1
    if nodes[0] > MAX_JSON_NODES:
        raise ProtocolError(f"{label} exceeds the node limit")
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ProtocolError(f"{label} contains a non-finite number")
        return
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, list):
        for item in value:
            _bounded_json_value(item, depth=depth + 1, nodes=nodes, label=label)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise ProtocolError(f"{label} contains a non-string object key")
            _bounded_json_value(item, depth=depth + 1, nodes=nodes, label=label)
        return
    raise ProtocolError(f"{label} contains an unsupported value")


def load_candidate_frame(path: Path, kind: str) -> dict[str, Any]:
    """Load the candidate's bounded JSON result without object deserialization."""
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise ProtocolError("candidate did not produce a result frame") from exc
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_JSON_FRAME_BYTES:
        raise ProtocolError("candidate result frame is not a bounded regular file")
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as handle:
            payload = handle.read(MAX_JSON_FRAME_BYTES + 1)
    except OSError as exc:
        raise ProtocolError("candidate result frame cannot be read safely") from exc
    if not payload or len(payload) > MAX_JSON_FRAME_BYTES:
        raise ProtocolError("candidate result frame exceeds the protocol limit")
    frame = load_bounded_json_bytes(payload, label="candidate result frame")
    if not isinstance(frame, dict) or set(frame) != {
        "schema_version",
        "kind",
        "status",
        "result",
    }:
        raise ProtocolError("candidate result frame has an invalid schema")
    if (
        type(frame["schema_version"]) is not int
        or frame["schema_version"] != CANDIDATE_FRAME_SCHEMA_VERSION
        or type(frame["kind"]) is not str
        or frame["kind"] != kind
    ):
        raise ProtocolError("candidate result frame has an unexpected identity")
    if type(frame["status"]) is not str or frame["status"] not in {"ok", "error"}:
        raise ProtocolError("candidate result frame has an invalid status")
    if frame["status"] == "error" and frame["result"] is not None:
        raise ProtocolError("candidate error frame must not contain a result")
    if frame["status"] == "ok" and not isinstance(frame["result"], dict):
        raise ProtocolError("candidate success frame must contain a mapping result")
    return frame


def _candidate_wrapper(
    candidate: str,
    *,
    kind: str,
    entry_point: str,
    entry_kwargs: dict[str, Any],
    result_path: Path,
    seed: int,
) -> str:
    """Build the isolated runner. Its only result channel is a strict JSON file."""
    request = {
        "candidate": candidate,
        "kind": kind,
        "entry_point": entry_point,
        "entry_kwargs": entry_kwargs,
        "result_path": str(result_path),
        "seed": seed,
        "max_bytes": MAX_JSON_FRAME_BYTES,
        "max_depth": MAX_JSON_DEPTH,
        "max_nodes": MAX_JSON_NODES,
    }
    return f"""
import json as _json
import math as _math
import os as _os
import random as _random
import socket as _socket
import struct as _struct

_REQUEST = _json.loads({json.dumps(json.dumps(request, separators=(",", ":")))})

def _receive_exact(_connection, _size):
    _chunks = bytearray()
    while len(_chunks) < _size:
        _chunk = _connection.recv(_size - len(_chunks))
        if not _chunk:
            raise RuntimeError("objective service closed the request")
        _chunks.extend(_chunk)
    return bytes(_chunks)

class _ObjectiveProxy:
    def __init__(self, _socket_path, _token):
        self._socket_path = _socket_path
        self._token = _token

    def __call__(self, _value):
        with _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM) as _connection:
            _connection.settimeout(5)
            _connection.connect(self._socket_path)
            _connection.sendall(self._token.encode("ascii") + b"\\n")
            _size = _struct.unpack("!I", _receive_exact(_connection, 4))[0]
            if _size > _REQUEST["max_bytes"]:
                raise RuntimeError("objective service response is invalid")
            _reservation = _json.loads(_receive_exact(_connection, _size).decode("utf-8"))
            if not _reservation.get("accepted"):
                raise RuntimeError("objective call budget exceeded")
            _converted = _value.tolist() if hasattr(_value, "tolist") else _value.item() if hasattr(_value, "item") else _value
            _payload = _json.dumps({{"value": _converted}}, separators=(",", ":"), allow_nan=False).encode("utf-8")
            if len(_payload) > _REQUEST["max_bytes"]:
                raise ValueError("objective input exceeds the protocol limit")
            _connection.sendall(_struct.pack("!I", len(_payload)) + _payload)
            _size = _struct.unpack("!I", _receive_exact(_connection, 4))[0]
            if _size > _REQUEST["max_bytes"]:
                raise RuntimeError("objective service response is invalid")
            _response = _json.loads(_receive_exact(_connection, _size).decode("utf-8"))
            if not _response.get("ok"):
                raise RuntimeError("objective input was rejected")
            return float(_response["score"])

def _json_data(_value, _depth=0, _nodes=None):
    if _nodes is None:
        _nodes = [0]
    if _depth > _REQUEST["max_depth"]:
        raise ValueError("result exceeds nesting limit")
    _nodes[0] += 1
    if _nodes[0] > _REQUEST["max_nodes"]:
        raise ValueError("result exceeds node limit")
    if _value is None or type(_value) in (str, bool, int):
        return _value
    if type(_value) is float:
        if not _math.isfinite(_value):
            raise ValueError("result contains a non-finite float")
        return _value
    if isinstance(_value, (list, tuple)):
        return [_json_data(_item, _depth + 1, _nodes) for _item in _value]
    if type(_value) is dict:
        if not all(type(_key) is str for _key in _value):
            raise ValueError("result contains a non-string object key")
        return {{_key: _json_data(_item, _depth + 1, _nodes) for _key, _item in _value.items()}}
    if type(_value).__module__.startswith("numpy") and hasattr(_value, "tolist"):
        return _json_data(_value.tolist(), _depth + 1, _nodes)
    raise TypeError("result contains a non-JSON value")

def _valid_result(_kind, _result):
    if type(_result) is not dict:
        return False
    if _kind == "circle_packing_v1":
        return set(_result) == {{"circles", "all_scores"}} and type(_result["circles"]) is list and type(_result["all_scores"]) is list
    if _kind == "blackbox_v1":
        return set(_result) == {{"x", "score", "all_attempts"}} and type(_result["all_attempts"]) is list
    return False

def _write(_frame):
    _payload = _json.dumps(_frame, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(_payload) > _REQUEST["max_bytes"]:
        _payload = b'{{"kind":"' + _REQUEST["kind"].encode("ascii") + b'","result":null,"schema_version":1,"status":"error"}}'
    _descriptor = _os.open(_REQUEST["result_path"], _os.O_WRONLY | _os.O_CREAT | _os.O_TRUNC, 0o600)
    with _os.fdopen(_descriptor, "wb") as _handle:
        _handle.write(_payload)
        _handle.flush()
        _os.fsync(_handle.fileno())

_random.seed(_REQUEST["seed"])
try:
    import numpy as _numpy
    _numpy.random.seed(_REQUEST["seed"])
except ImportError:
    pass
try:
    import torch as _torch
    _torch.manual_seed(_REQUEST["seed"])
    if _torch.cuda.is_available():
        _torch.cuda.manual_seed_all(_REQUEST["seed"])
except ImportError:
    pass

_frame = {{"schema_version": 1, "kind": _REQUEST["kind"], "status": "error", "result": None}}
try:
    _context = {{"__name__": "__main__"}}
    exec(_REQUEST["candidate"], _context)
    _kwargs = _REQUEST["entry_kwargs"]
    if "objective_socket" in _kwargs:
        _kwargs = dict(_kwargs)
        _kwargs["objective_function"] = _ObjectiveProxy(_kwargs.pop("objective_socket"), _kwargs.pop("objective_token"))
    _result = _context[_REQUEST["entry_point"]](**_kwargs)
    _result = _json_data(_result)
    if not _valid_result(_REQUEST["kind"], _result):
        raise ValueError("result does not match the required schema")
    _frame = {{"schema_version": 1, "kind": _REQUEST["kind"], "status": "ok", "result": _result}}
except BaseException:
    pass
_write(_frame)
"""


def run_candidate_json(
    candidate: str,
    *,
    kind: str,
    entry_point: str,
    entry_kwargs: dict[str, Any],
    seed: int,
    timeout_seconds: int,
    sandbox: CandidateSandbox,
) -> tuple[bool, dict[str, Any] | None, float, str | None]:
    result_path = sandbox.root / "result.json"
    runner_path = sandbox.root / "runner.py"
    runner_path.write_text(
        _candidate_wrapper(
            candidate,
            kind=kind,
            entry_point=entry_point,
            entry_kwargs=entry_kwargs,
            result_path=result_path,
            seed=seed,
        ),
        encoding="utf-8",
    )
    started = time.monotonic()
    try:
        process = sandbox.run(
            [str(sandbox.python), str(runner_path)],
            cwd=sandbox.root,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        return False, None, time.monotonic() - started, "candidate execution timed out"
    elapsed = time.monotonic() - started
    if process.returncode != 0:
        return False, None, elapsed, "candidate execution failed"
    try:
        frame = load_candidate_frame(result_path, kind)
    except ProtocolError as exc:
        return False, None, elapsed, str(exc)
    if frame["status"] != "ok":
        return False, None, elapsed, "candidate returned an invalid result"
    return True, frame["result"], elapsed, None


def finite_score(value: Any, failure_score: float) -> float:
    try:
        score = float(value)
    except (TypeError, ValueError):
        return failure_score
    return score if math.isfinite(score) else failure_score


def evaluate_circle(candidate: str, config: dict[str, Any]) -> dict[str, Any]:
    import numpy as np
    from examples.circle_packing.utils import validate_packing

    started = time.monotonic()
    sandbox = CandidateSandbox(Path(sys.executable))
    try:
        execution_success, returned, execution_time, execution_error = run_candidate_json(
            candidate,
            kind="circle_packing_v1",
            entry_point="main",
            entry_kwargs={
                "timeout": config["timeout_seconds"],
                "current_best_solution": None,
            },
            seed=config["random_seed"],
            timeout_seconds=config["timeout_seconds"],
            sandbox=sandbox,
        )
    finally:
        sandbox.close()
    side_info: dict[str, Any] = {
        "domain": "circle_packing_26",
        "execution_success": execution_success,
        "execution_time_seconds": execution_time,
        "candidate_output_retained": False,
        "isolation": isolation_report(),
    }
    score = 0.0
    if not execution_success:
        side_info["error"] = execution_error or "candidate execution failed"
    else:
        if (
            not isinstance(returned, dict)
            or set(returned) != {"circles", "all_scores"}
            or not isinstance(returned["circles"], list)
        ):
            side_info["error"] = (
                "main() must return a mapping with circles and all_scores"
            )
        elif not isinstance(returned["all_scores"], list) or not returned["all_scores"]:
            side_info["error"] = "all_scores must be a non-empty list"
        else:
            try:
                circles = np.asarray(returned["circles"], dtype=float)
                valid, details = validate_packing(config["num_circles"], circles)
                side_info["validation"] = json_value(details)
                side_info["valid"] = bool(valid)
                if valid:
                    score = finite_score(details.get("sum_radii"), 0.0)
            except Exception:  # Candidate output is intentionally untrusted.
                side_info["error"] = "packing validation failed"

    side_info["score"] = score
    return {
        "score": score,
        "side_info": side_info,
        "objective_calls": 0,
        "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
    }


class ObjectiveProxy:
    """Capability-only client; the candidate receives no parent ledger state or path."""

    def __init__(self, socket_path: str, token: str):
        self._socket_path = socket_path
        self._token = token

    def __call__(self, value: Any) -> float:
        import json as _json
        import socket as _socket
        import struct as _struct

        def receive_exact(connection: Any, size: int) -> bytes:
            chunks = bytearray()
            while len(chunks) < size:
                chunk = connection.recv(size - len(chunks))
                if not chunk:
                    raise RuntimeError("objective service closed the request")
                chunks.extend(chunk)
            return bytes(chunks)

        def receive(connection: Any) -> dict[str, Any]:
            size = _struct.unpack("!I", receive_exact(connection, 4))[0]
            if size > 1_000_000:
                raise RuntimeError("objective service response is invalid")
            return _json.loads(receive_exact(connection, size).decode("utf-8"))

        with _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(self._socket_path)
            connection.sendall(self._token.encode("ascii") + b"\n")
            reservation = receive(connection)
            if not reservation.get("accepted"):
                raise RuntimeError("objective call budget exceeded")

            converted = value
            if hasattr(converted, "tolist"):
                converted = converted.tolist()
            elif hasattr(converted, "item"):
                converted = converted.item()
            payload = _json.dumps(
                {"value": converted}, separators=(",", ":"), allow_nan=False
            ).encode("utf-8")
            if len(payload) > 1_000_000:
                raise ValueError("objective input exceeds the protocol limit")
            connection.sendall(_struct.pack("!I", len(payload)) + payload)
            response = receive(connection)
            if not response.get("ok"):
                raise RuntimeError("objective input was rejected")
            return float(response["score"])


class TrustedObjectiveService:
    def __init__(self, problem: Any, budget: int, socket_path: Path):
        self.problem = problem
        self.budget = budget
        self.socket_path = socket_path
        self.token = secrets.token_hex(32)
        self.attempted_calls = 0
        self.failed_calls = 0
        self.rejected_calls = 0
        self.observations: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._evaluation_lock = threading.Lock()
        self._stop = threading.Event()
        self._workers: list[threading.Thread] = []
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        self._listener.listen(32)
        self._listener.settimeout(0.2)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "TrustedObjectiveService":
        self._thread.start()
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self._stop.set()
        self._listener.close()
        self._thread.join(timeout=2)
        for worker in self._workers:
            worker.join(timeout=2)
        self.socket_path.unlink(missing_ok=True)

    def proxy(self) -> ObjectiveProxy:
        return ObjectiveProxy(str(self.socket_path), self.token)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            worker = threading.Thread(
                target=self._handle, args=(connection,), daemon=True
            )
            self._workers.append(worker)
            worker.start()

    @staticmethod
    def _receive_exact(connection: socket.socket, size: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < size:
            chunk = connection.recv(size - len(chunks))
            if not chunk:
                raise EOFError("request ended early")
            chunks.extend(chunk)
        return bytes(chunks)

    @classmethod
    def _receive_frame(cls, connection: socket.socket) -> bytes:
        size = struct.unpack("!I", cls._receive_exact(connection, 4))[0]
        if size > 1_000_000:
            raise ValueError("request exceeds protocol limit")
        return cls._receive_exact(connection, size)

    @staticmethod
    def _send(connection: socket.socket, value: dict[str, Any]) -> None:
        payload = json.dumps(value, separators=(",", ":"), allow_nan=False).encode(
            "utf-8"
        )
        connection.sendall(struct.pack("!I", len(payload)) + payload)

    def _record_failure(self) -> None:
        with self._lock:
            self.failed_calls += 1

    def _handle(self, connection: socket.socket) -> None:
        with connection:
            connection.settimeout(5)
            try:
                token = bytearray()
                while len(token) <= 128:
                    byte = connection.recv(1)
                    if not byte:
                        return
                    if byte == b"\n":
                        break
                    token.extend(byte)
                if not hmac.compare_digest(token.decode("ascii"), self.token):
                    return

                with self._lock:
                    self.attempted_calls += 1
                    attempt = self.attempted_calls
                    accepted = attempt <= self.budget
                    if not accepted:
                        self.rejected_calls += 1
                self._send(connection, {"accepted": accepted, "attempt": attempt})
                if not accepted:
                    return

                payload = load_bounded_json_bytes(
                    self._receive_frame(connection), label="objective request frame"
                )
                if not isinstance(payload, dict) or set(payload) != {"value"}:
                    raise ValueError("invalid objective request")
                import numpy as np

                point = np.asarray(payload["value"], dtype=float)
                with self._evaluation_lock:
                    score = float(self.problem.do_evaluate(point))
                if not math.isfinite(score):
                    raise ValueError("objective returned a non-finite score")
                observation = {"attempt": attempt, "x": point.tolist(), "score": score}
                with self._lock:
                    self.observations.append(observation)
                self._send(connection, {"ok": True, "score": score})
            except Exception:
                self._record_failure()
                try:
                    self._send(connection, {"ok": False})
                except Exception:
                    pass


def evaluate_blackbox(candidate: str, config: dict[str, Any]) -> dict[str, Any]:
    from examples.blackbox.evalset.problems import problems

    started = time.monotonic()
    problem = problems[config["problem_index"]]
    budget = config["objective_call_budget"]
    sandbox = CandidateSandbox(Path(sys.executable), objective_proxy=True)
    assert sandbox.objective_socket is not None
    service = TrustedObjectiveService(problem, budget, sandbox.objective_socket)
    try:
        with service:
            execution_success, returned, execution_time, execution_error = run_candidate_json(
                candidate,
                kind="blackbox_v1",
                entry_point="solve",
                entry_kwargs={
                    "objective_socket": str(sandbox.objective_socket),
                    "objective_token": service.token,
                    "config": {
                        "bounds": json_value(problem.bounds),
                        "dim": problem.dim,
                        "budget": budget,
                    },
                    "best_xs": [],
                },
                seed=config["random_seed"],
                timeout_seconds=config["timeout_seconds"],
                sandbox=sandbox,
            )
    finally:
        sandbox.close()

    audited = list(service.observations)
    calls = service.attempted_calls
    side_info: dict[str, Any] = {
        "domain": "blackbox_problem_46",
        "problem_index": config["problem_index"],
        "objective_call_budget": budget,
        "objective_calls": calls,
        "objective_completed_calls": len(audited),
        "objective_failed_calls": service.failed_calls,
        "objective_rejected_calls": service.rejected_calls,
        "execution_success": execution_success,
        "execution_time_seconds": execution_time,
        "candidate_output_retained": False,
        "isolation": isolation_report(),
    }
    score = -1.0e9
    contract_valid = (
        isinstance(returned, dict)
        and set(returned) == {"x", "score", "all_attempts"}
        and isinstance(returned.get("all_attempts"), list)
    )
    if not execution_success:
        side_info["error"] = execution_error or "candidate execution failed"
    elif not contract_valid:
        side_info["error"] = (
            "solve() must return a mapping with x, score, and all_attempts"
        )
    elif calls == 0:
        side_info["error"] = "candidate did not call the objective"
    elif calls > budget:
        side_info["error"] = "candidate exceeded the objective call budget"
    elif not audited:
        side_info["error"] = "candidate produced no valid objective observation"
    else:
        best = min(audited, key=lambda row: row["score"])
        side_info["best_observed"] = json_value(best)
        score = finite_score(-best["score"], -1.0e9)

    side_info["score"] = score
    side_info["observations_sha256"] = sha256_bytes(
        json.dumps(json_value(audited), sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
    )
    return {
        "score": score,
        "side_info": side_info,
        "objective_calls": calls,
        "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
    }


def archive_checkout(
    repository: Path, destination: Path, *, revision: str = "HEAD"
) -> None:
    process = subprocess.run(
        ["git", "-C", str(repository), "archive", "--format=tar", revision],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise ProtocolError(
            f"cannot archive pinned authority: {process.stderr.decode('utf-8', errors='replace').strip()}"
        )
    with tarfile.open(fileobj=io.BytesIO(process.stdout), mode="r:") as archive:
        archive.extractall(destination, filter="data")


def apply_patch(checkout: Path, patch: str, allowed_path: str) -> tuple[bool, str]:
    if not patch.strip():
        return False, "candidate patch is empty"
    inspection = subprocess.run(
        ["git", "apply", "--numstat", "-"],
        cwd=checkout,
        input=patch,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if inspection.returncode != 0:
        return False, "candidate patch is not a valid unified diff"
    changed = []
    for line in inspection.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 3 or fields[0] == "-" or fields[1] == "-":
            return (
                False,
                "candidate patch must be a text diff with ordinary numstat entries",
            )
        changed.append(fields[2])
    if changed != [allowed_path]:
        return False, f"candidate patch must touch only {allowed_path}"

    process = subprocess.run(
        ["git", "apply", "--whitespace=nowarn", "-"],
        cwd=checkout,
        input=patch,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        return False, "candidate patch does not apply cleanly"
    return True, ""


def _blueprint_init(tree: ast.Module) -> ast.FunctionDef:
    classes = [
        node
        for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "Blueprint"
    ]
    if len(classes) != 1:
        raise ProtocolError("Flask source must contain exactly one Blueprint class")
    methods = [
        node
        for node in classes[0].body
        if isinstance(node, ast.FunctionDef) and node.name == "__init__"
    ]
    if len(methods) != 1:
        raise ProtocolError("Flask Blueprint must contain exactly one __init__ method")
    return methods[0]


def _is_safe_empty_name_guard(statement: ast.stmt) -> bool:
    if not isinstance(statement, ast.If) or statement.orelse:
        return False
    test = statement.test
    if not (
        isinstance(test, ast.UnaryOp)
        and isinstance(test.op, ast.Not)
        and isinstance(test.operand, ast.Name)
        and test.operand.id == "name"
        and isinstance(test.operand.ctx, ast.Load)
    ):
        return False
    if len(statement.body) != 1 or not isinstance(statement.body[0], ast.Raise):
        return False
    raised = statement.body[0]
    call = raised.exc
    return bool(
        raised.cause is None
        and isinstance(call, ast.Call)
        and isinstance(call.func, ast.Name)
        and call.func.id == "ValueError"
        and isinstance(call.func.ctx, ast.Load)
        and not call.keywords
        and len(call.args) == 1
        and isinstance(call.args[0], ast.Constant)
        and type(call.args[0].value) is str
        and len(call.args[0].value) <= 200
    )


def enforce_flask_patch_policy(
    checkout: Path, source_path: str, baseline_source: str
) -> dict[str, Any]:
    """Admit only a no-op or one capability-limited empty-name guard."""
    candidate_source = resolve(checkout, source_path).read_text(encoding="utf-8")
    if candidate_source.splitlines()[:2] != baseline_source.splitlines()[:2]:
        raise ProtocolError("candidate patch may not alter Python encoding boundaries")
    try:
        baseline_tree = ast.parse(baseline_source, type_comments=True)
        candidate_tree = ast.parse(candidate_source, type_comments=True)
    except SyntaxError as exc:
        raise ProtocolError("candidate Flask patch does not produce valid Python") from exc

    baseline_dump = ast.dump(baseline_tree, include_attributes=False)
    if ast.dump(candidate_tree, include_attributes=False) == baseline_dump:
        return {
            "policy_id": FLASK_PATCH_POLICY_ID,
            "semantic_delta": "none",
            "candidate_authored_receipt": False,
        }

    candidate_init = _blueprint_init(candidate_tree)
    for index, statement in enumerate(candidate_init.body):
        if not _is_safe_empty_name_guard(statement):
            continue
        reduced_tree = ast.parse(candidate_source, type_comments=True)
        del _blueprint_init(reduced_tree).body[index]
        if ast.dump(reduced_tree, include_attributes=False) == baseline_dump:
            return {
                "policy_id": FLASK_PATCH_POLICY_ID,
                "semantic_delta": "single_literal_empty_name_guard",
                "candidate_capabilities": [
                    "truth_test_of_name",
                    "raise_builtin_ValueError_with_literal_message",
                ],
                "candidate_authored_receipt": False,
            }
    raise ProtocolError(
        "candidate Flask patch exceeds the empty-name guard capability policy"
    )


def _junit_nodeid(testcase: ET.Element) -> str | None:
    classname = testcase.get("classname")
    name = testcase.get("name")
    if not classname or not name:
        return None
    return f"{classname.replace('.', '/')}.py::{name}"


def verify_pytest_receipt(report_path: Path, tests: list[str]) -> dict[str, Any]:
    """Validate pytest's bounded receipt after candidate capabilities are constrained."""
    if not tests or len(tests) != len(set(tests)):
        raise ProtocolError("pytest completion receipt requires unique requested tests")
    try:
        metadata = report_path.stat()
    except OSError as exc:
        raise ProtocolError("pytest did not produce a completion receipt") from exc
    if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= MAX_JUNIT_REPORT_BYTES:
        raise ProtocolError("pytest completion receipt is not a bounded regular file")
    try:
        payload = report_path.read_bytes()
        if b"<!DOCTYPE" in payload.upper() or b"<!ENTITY" in payload.upper():
            raise ProtocolError("pytest completion receipt contains forbidden XML declarations")
        root = ET.fromstring(payload)
    except (OSError, ET.ParseError) as exc:
        raise ProtocolError("pytest completion receipt is invalid") from exc

    expected = set(tests)
    completed: set[str] = set()
    for testcase in root.iter("testcase"):
        nodeid = _junit_nodeid(testcase)
        if nodeid is None or nodeid not in expected:
            raise ProtocolError("pytest completion receipt contains an unexpected test")
        if nodeid in completed:
            raise ProtocolError("pytest completion receipt contains a duplicate test")
        if any(child.tag in {"failure", "error", "skipped"} for child in testcase):
            raise ProtocolError("pytest completion receipt includes an incomplete test")
        completed.add(nodeid)
    if completed != expected:
        raise ProtocolError(
            "pytest completion receipt does not contain every requested test"
        )
    return {
        "format": "junitxml-v1",
        "expected_tests": len(expected),
        "completed_tests": len(completed),
        "passed_tests": len(completed),
        "report_sha256": sha256_bytes(payload),
    }


def run_pytest(
    checkout: Path,
    python: Path,
    tests: list[str],
    timeout_seconds: int,
) -> dict[str, Any]:
    started = time.monotonic()
    report_path = checkout / f".imp-oa-pytest-{secrets.token_hex(16)}.xml"
    sandbox = CandidateSandbox(
        python,
        pythonpath=(checkout / "src",),
        read_roots=(checkout, python.parent.parent),
        write_roots=(checkout,),
    )
    try:
        process = sandbox.run(
            [
                str(python),
                "-m",
                "pytest",
                "-q",
                "--disable-warnings",
                "-p",
                "no:cacheprovider",
                f"--junitxml={report_path}",
                *tests,
            ],
            cwd=checkout,
            timeout=timeout_seconds,
        )
        receipt: dict[str, Any] | None = None
        error: str | None = None
        if process.returncode == 0:
            try:
                receipt = verify_pytest_receipt(report_path, tests)
            except ProtocolError as exc:
                error = str(exc)
        return {
            "passed": process.returncode == 0 and receipt is not None,
            "exit_status": process.returncode,
            **({"completion_receipt": receipt} if receipt is not None else {}),
            **({"error": error} if error is not None else {}),
            "candidate_output_retained": False,
            "isolation": isolation_report(),
            "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
        }
    except subprocess.TimeoutExpired:
        return {
            "passed": False,
            "exit_status": None,
            "error": f"pytest exceeded {timeout_seconds} seconds",
            "candidate_output_retained": False,
            "isolation": isolation_report(),
            "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
        }
    finally:
        report_path.unlink(missing_ok=True)
        sandbox.close()


def evaluate_flask(
    candidate: str,
    config: dict[str, Any],
    manifest: dict[str, Any],
    flask: Path,
    python: Path,
) -> dict[str, Any]:
    started = time.monotonic()
    swe = manifest["swe_bench"]
    if not python.is_file():
        raise ProtocolError(f"pinned Flask test environment is missing: {python}")

    with tempfile.TemporaryDirectory(prefix="imp-oa-flask-") as directory:
        checkout = Path(directory)
        shutil.copytree(flask, checkout, dirs_exist_ok=True, symlinks=True)
        baseline_source = resolve(checkout, swe["source_path"]).read_text(
            encoding="utf-8"
        )
        applied, error = apply_patch(checkout, candidate, swe["source_path"])
        if not applied:
            return {
                "score": 0.0,
                "side_info": {
                    "domain": "swe_bench_flask_5014",
                    "patch_applied": False,
                    "error": error,
                    "score": 0.0,
                },
                "objective_calls": 0,
                "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
            }

        try:
            patch_policy = enforce_flask_patch_policy(
                checkout, swe["source_path"], baseline_source
            )
        except ProtocolError as exc:
            return {
                "score": 0.0,
                "side_info": {
                    "domain": "swe_bench_flask_5014",
                    "patch_applied": True,
                    "patch_policy": {
                        "policy_id": FLASK_PATCH_POLICY_ID,
                        "admitted": False,
                    },
                    "error": str(exc),
                    "score": 0.0,
                },
                "objective_calls": 0,
                "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
            }

        test_applied, test_error = apply_patch(
            checkout, swe["test_patch"], "tests/test_blueprints.py"
        )
        if not test_applied:
            raise ProtocolError(
                f"pinned SWE-bench test patch no longer applies: {test_error}"
            )

        fail_to_pass_tests = list(swe["fail_to_pass"])
        pass_to_pass_tests = list(swe["pass_to_pass"])
        if len(fail_to_pass_tests) != 1 or len(pass_to_pass_tests) != 59:
            raise ProtocolError(
                "verified SWE-bench Flask suites must contain exactly 1 F2P and 59 P2P tests"
            )
        fail_to_pass = run_pytest(
            checkout,
            python,
            fail_to_pass_tests,
            config["test_timeout_seconds"],
        )
        pass_to_pass = run_pytest(
            checkout,
            python,
            pass_to_pass_tests,
            config["test_timeout_seconds"],
        )
        score = config["fail_to_pass_weight"] * int(fail_to_pass["passed"]) + config[
            "pass_to_pass_weight"
        ] * int(pass_to_pass["passed"])
        side_info = {
            "domain": "swe_bench_flask_5014",
            "instance_id": swe["instance_id"],
            "patch_applied": True,
            "patch_policy": {**patch_policy, "admitted": True},
            "test_trust_boundary": (
                "host_ast_capability_policy_then_sandboxed_pytest_receipt"
            ),
            "fail_to_pass": fail_to_pass,
            "pass_to_pass": pass_to_pass,
            "score": score,
        }
        return {
            "score": score,
            "side_info": side_info,
            "objective_calls": 0,
            "wall_time_ms": max(round((time.monotonic() - started) * 1000), 1),
        }


def evaluate_domain(
    manifest: dict[str, Any],
    authorities: dict[str, Any],
    domain_id: str,
    candidate: str,
) -> dict[str, Any]:
    domain = domain_config(manifest, domain_id)
    if not isinstance(candidate, str):
        raise ProtocolError("candidate must be UTF-8 text")
    if len(candidate.encode("utf-8")) > 512_000:
        raise ProtocolError("candidate exceeds the 512 KiB protocol limit")

    activate_authority(authorities["upstream"])
    if domain_id == "circle_packing_26":
        row = evaluate_circle(candidate, domain["evaluator"])
    elif domain_id == "blackbox_problem_46":
        row = evaluate_blackbox(candidate, domain["evaluator"])
    elif domain_id == "swe_bench_flask_5014":
        row = evaluate_flask(
            candidate,
            domain["evaluator"],
            manifest,
            authorities["flask"],
            authorities["flask_python"],
        )
    else:
        raise ProtocolError(f"unknown protocol domain: {domain_id}")

    return {
        "protocol_id": manifest["protocol_id"],
        "domain": domain_id,
        "candidate_sha256": candidate_sha256(candidate),
        "isolation": authorities.get("isolation", isolation_report()),
        **row,
    }


def describe(manifest: dict[str, Any], authorities: dict[str, Any]) -> dict[str, Any]:
    domains = []
    for domain in manifest["domains"]:
        seed = seed_candidate(manifest, domain["id"], authorities["upstream"])
        template = reflection_template(manifest, domain)
        domains.append(
            {
                "id": domain["id"],
                "kind": domain["kind"],
                "objective": domain["objective"],
                "background": domain["background"],
                "seed_candidate": seed,
                "seed_candidate_sha256": candidate_sha256(seed),
                "reflection_template": template,
                "reflection_template_sha256": sha256_bytes(template.encode("utf-8")),
                "evaluator": domain["evaluator"],
            }
        )
    return {
        "schema_version": 1,
        "protocol_id": manifest["protocol_id"],
        "protocol_class": manifest["protocol_class"],
        "authority": {
            "repository": authorities["protocol_authority"]["repository"],
            "commit": authorities["protocol_authority"]["commit"],
            "source_hashes": authorities["source_hashes"],
        },
        "swe_bench": {
            key: manifest["swe_bench"][key]
            for key in (
                "dataset",
                "dataset_revision",
                "parquet_sha256",
                "instance_id",
                "repository",
                "base_commit",
                "environment_setup_commit",
                "source_path",
                "source_sha256",
                "fail_to_pass",
                "pass_to_pass",
            )
        }
        | {
            "verification": authorities["dataset_verification"],
            "test_runtime": authorities["flask_runtime"],
        },
        "controls": manifest["controls"],
        "claim_scope": manifest["claim_scope"],
        "isolation": authorities["isolation"],
        "domains": domains,
    }


def run_upstream(
    manifest: dict[str, Any],
    authorities: dict[str, Any],
    domain_id: str,
    seed: int,
) -> dict[str, Any]:
    activate_authority(authorities["upstream"])
    from gepa.lm import LM
    from gepa.optimize_anything import (
        EngineConfig,
        GEPAConfig,
        ReflectionConfig,
        TrackingConfig,
        optimize_anything,
    )

    controls = manifest["controls"]
    if seed not in controls["seeds"]:
        raise ProtocolError(f"seed {seed} is outside the fixed protocol seeds")
    domain = domain_config(manifest, domain_id)
    initial = seed_candidate(manifest, domain_id, authorities["upstream"])
    model = controls["model"]
    lm = CountingLM(
        LM(
            model["upstream_name"],
            temperature=model["temperature"],
            max_tokens=model["max_tokens"],
            num_retries=model["upstream_retries"],
        )
    )
    evaluations: list[dict[str, Any]] = []

    def evaluator(
        candidate: str, opt_state: Any = None
    ) -> tuple[float, dict[str, Any]]:
        del opt_state
        row = evaluate_domain(manifest, authorities, domain_id, candidate)
        evaluations.append(row)
        return row["score"], row["side_info"]

    config = GEPAConfig(
        engine=EngineConfig(
            seed=seed,
            raise_on_exception=True,
            track_best_outputs=True,
            max_candidate_proposals=controls["max_candidate_proposals"],
            candidate_selection_strategy=controls["candidate_selection_strategy"],
            frontier_type=controls["frontier_type"],
            parallel=controls["parallel"],
            max_workers=controls["max_workers"],
            num_parallel_proposals=1,
            cache_evaluation=controls["cache_evaluation"],
        ),
        reflection=ReflectionConfig(
            reflection_lm=lm,
            reflection_minibatch_size=controls["reflection_minibatch_size"],
            reflection_prompt_template=reflection_template(manifest, domain),
        ),
        tracking=TrackingConfig(logger=QuietLogger()),
        merge=None,
        refiner=None,
    )

    started = time.monotonic()
    result = optimize_anything(
        seed_candidate=initial,
        evaluator=evaluator,
        config=config,
    )
    elapsed_ms = max(round((time.monotonic() - started) * 1000), 1)
    best_candidate = result.best_candidate
    verified = evaluate_domain(manifest, authorities, domain_id, best_candidate)
    reported_best = float(result.val_aggregate_scores[result.best_idx])
    if not math.isclose(
        reported_best, float(verified["score"]), rel_tol=1.0e-12, abs_tol=1.0e-12
    ):
        raise ProtocolError(
            f"upstream best score failed independent verification: {reported_best} != {verified['score']}"
        )
    if result.total_metric_calls != len(evaluations):
        raise ProtocolError(
            f"upstream metric-call accounting mismatch: result={result.total_metric_calls}, observed={len(evaluations)}"
        )

    return {
        "schema_version": 1,
        "protocol_id": manifest["protocol_id"],
        "runtime": "upstream_python",
        "authority_commit": manifest["authority"]["commit"],
        "domain": domain_id,
        "seed": seed,
        "model": model,
        "controls": {
            key: controls[key]
            for key in (
                "max_candidate_proposals",
                "parallel",
                "max_workers",
                "cache_evaluation",
                "reflection_minibatch_size",
                "candidate_selection_strategy",
                "frontier_type",
            )
        },
        "baseline_score": float(result.val_aggregate_scores[0]),
        "best_score": reported_best,
        "absolute_lift": reported_best - float(result.val_aggregate_scores[0]),
        "best_candidate": best_candidate,
        "best_candidate_sha256": candidate_sha256(best_candidate),
        "metric_calls": int(result.total_metric_calls),
        "objective_calls": sum(int(row["objective_calls"]) for row in evaluations),
        "reflection_calls": lm.calls,
        "input_tokens": lm.total_tokens_in,
        "output_tokens": lm.total_tokens_out,
        "cost_usd": lm.total_cost,
        "wall_time_ms": elapsed_ms,
        "independent_verification": verified,
        "evaluation_trace": [
            {
                "candidate_sha256": row["candidate_sha256"],
                "score": row["score"],
                "objective_calls": row["objective_calls"],
                "wall_time_ms": row["wall_time_ms"],
            }
            for row in evaluations
        ],
    }


def json_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else str(value)
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(item) for item in value]
    if hasattr(value, "tolist"):
        return json_value(value.tolist())
    if hasattr(value, "item"):
        return json_value(value.item())
    return str(value)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(json_value(value), indent=2, sort_keys=True) + "\n"
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    subparsers = parser.add_subparsers(dest="command", required=True)

    describe_parser = subparsers.add_parser("describe")
    describe_parser.add_argument("--out", type=Path)

    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--domain", required=True)
    evaluate_parser.add_argument("--candidate", required=True, type=Path)
    evaluate_parser.add_argument("--out", type=Path)

    run_parser = subparsers.add_parser("run-upstream")
    run_parser.add_argument("--domain", required=True)
    run_parser.add_argument("--seed", required=True, type=int)
    run_parser.add_argument("--out", type=Path)

    verify_parser = subparsers.add_parser("verify-evaluators")
    verify_parser.add_argument("--out", type=Path)
    return parser.parse_args()


def emit(value: Any, out: Path | None) -> None:
    if out is not None:
        write_json(out, value)
        print(out)
    else:
        print(json.dumps(json_value(value), sort_keys=True))


def verify_evaluators(
    manifest: dict[str, Any], authorities: dict[str, Any]
) -> dict[str, Any]:
    rows = []
    for domain in manifest["domains"]:
        domain_id = domain["id"]
        candidate = seed_candidate(manifest, domain_id, authorities["upstream"])
        baseline = evaluate_domain(manifest, authorities, domain_id, candidate)
        row: dict[str, Any] = {"domain": domain_id, "baseline": baseline}
        if domain_id == "swe_bench_flask_5014":
            reference = evaluate_domain(
                manifest,
                authorities,
                domain_id,
                manifest["swe_bench"]["reference_patch"],
            )
            if reference["score"] != 1.0:
                raise ProtocolError(
                    f"official Flask reference patch did not achieve score 1.0: {reference['score']}"
                )
            if baseline["score"] >= reference["score"]:
                raise ProtocolError(
                    "Flask baseline must score below the official reference patch"
                )
            row["reference"] = reference
        rows.append(row)
    return {
        "schema_version": 1,
        "protocol_id": manifest["protocol_id"],
        "authority_verified": True,
        "dataset_verification": authorities["dataset_verification"],
        "test_runtime": authorities["flask_runtime"],
        "isolation": authorities["isolation"],
        "rows": rows,
    }


def main() -> int:
    args = parse_args()
    try:
        manifest_path = (
            args.manifest
            if args.manifest.is_absolute()
            else resolve(ROOT, str(args.manifest))
        )
        manifest = load_manifest(manifest_path)
        authorities = verify_authorities(manifest)
        if args.command == "describe":
            value = describe(manifest, authorities)
        elif args.command == "evaluate":
            candidate = args.candidate.read_text(encoding="utf-8")
            value = evaluate_domain(manifest, authorities, args.domain, candidate)
        elif args.command == "run-upstream":
            value = run_upstream(manifest, authorities, args.domain, args.seed)
        elif args.command == "verify-evaluators":
            value = verify_evaluators(manifest, authorities)
        else:  # pragma: no cover - argparse enforces the command set.
            raise ProtocolError(f"unsupported command: {args.command}")
        emit(value, args.out)
        return 0
    except (OSError, ProtocolError) as exc:
        print(f"protocol error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
