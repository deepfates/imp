"""Shared fail-closed reader for upstream contract authority pins."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


REGISTRY_PATH = Path(__file__).resolve().parent.parent / "benchmarks" / "authorities.json"
REQUIRED_AUTHORITIES = {
    "dspy_stable",
    "dspy_instruction_optimizers",
    "gepa_v0_1_1_contract",
    "gepa_v0_1_4_contract",
    "optimize_anything_artifact",
    "req_llm",
    "swe_bench_verified",
}
REQUIRED_CONTRACTS = {
    "dspy_stable_upstream_fidelity": "dspy_stable",
    "optimize_anything_swe_bench_flask_5014_dataset": "swe_bench_verified",
    "optimize_anything_upstream_differential_protocol": "optimize_anything_artifact",
    "req_llm_beam_runtime_dependency": "req_llm",
    "t1_gepa_v014_structural_differential_contract": "gepa_v0_1_4_contract",
    "t1_gepa_v011_structural_differential_contract": "gepa_v0_1_1_contract",
    "t1_instruction_optimizer_differential_contract": "dspy_instruction_optimizers",
}


def load_registry_authority(
    contract_id: str, path: Path = REGISTRY_PATH
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        ledger = json.loads(path.read_text())
        if ledger.get("schema_version") != 1:
            raise ValueError("unsupported schema_version")
        pinned_sources = ledger["pinned_sources"]
        contracts = ledger["contracts"]
        if not REQUIRED_AUTHORITIES.issubset(pinned_sources):
            raise ValueError("missing required authorities")
        if not REQUIRED_CONTRACTS.keys() <= contracts.keys():
            raise ValueError("missing required contracts")
        for required_contract, expected_authority in REQUIRED_CONTRACTS.items():
            actual_authority = contracts[required_contract].get("authority")
            if actual_authority != expected_authority:
                raise ValueError(
                    f"contract {required_contract} must bind authority "
                    f"{expected_authority}, got {actual_authority!r}"
                )

        contract_ids_by_authority: dict[str, list[str]] = {}
        for candidate_id, candidate in contracts.items():
            authority_id = candidate["authority"]
            contract_ids_by_authority.setdefault(authority_id, []).append(candidate_id)

        authorities = {
            authority_id: _project_authority(
                authority_id,
                pinned_sources[authority_id],
                contract_ids,
            )
            for authority_id, contract_ids in contract_ids_by_authority.items()
        }

        for candidate_id, candidate in authorities.items():
            required = (
                "project",
                "repository",
                "version",
                "git_ref",
                "commit",
                "source_hashes",
                "contract_ids",
            )
            if any(not candidate.get(key) for key in required):
                raise ValueError(f"authority {candidate_id} is missing required fields")
            if not _digest(candidate["commit"], 40):
                raise ValueError(f"authority {candidate_id} has an invalid commit")
            if not candidate["source_hashes"] or any(
                not _digest(digest, 64) for digest in candidate["source_hashes"].values()
            ):
                raise ValueError(f"authority {candidate_id} has invalid source hashes")
        for candidate_id, candidate in contracts.items():
            candidate_authority = authorities[candidate["authority"]]
            if candidate_id not in candidate_authority["contract_ids"]:
                raise ValueError(
                    f"contract {candidate_id} is incompatible with authority {candidate['authority']}"
                )
        declared_contracts = [
            candidate_id
            for candidate in authorities.values()
            for candidate_id in candidate["contract_ids"]
        ]
        if sorted(declared_contracts) != sorted(contracts):
            raise ValueError("contract identifiers must be declared exactly once")
        authority = authorities[contracts[contract_id]["authority"]]
        registry = {
            "schema_version": 1,
            "authorities": authorities,
            "contracts": contracts,
        }
        return registry, authority
    except (OSError, KeyError, TypeError, json.JSONDecodeError, ValueError) as exc:
        raise RuntimeError(f"invalid upstream authority registry {path.resolve()}: {exc}") from exc


def _project_authority(
    authority_id: str,
    source: dict[str, Any],
    contract_ids: list[str],
) -> dict[str, Any]:
    authority = dict(source)
    repository = authority["repository"]
    project = urlparse(repository).path.strip("/")
    if not project:
        raise ValueError(f"authority {authority_id} has an invalid repository URL")

    source_hashes = authority.get("source_hashes")
    if not source_hashes:
        files = authority.get("files")
        if not files:
            raise ValueError(f"authority {authority_id} has no exact source hashes")
        source_hashes = {entry["path"]: entry["sha256"] for entry in files}

    authority["project"] = project
    authority["source_hashes"] = source_hashes
    authority["contract_ids"] = sorted(contract_ids)
    return authority


def source_hash_failures(actual_hashes: dict[str, str], authority: dict[str, Any]) -> list[str]:
    expected_hashes = authority["source_hashes"]
    failures = []
    if set(actual_hashes) != set(expected_hashes):
        failures.append(f"source set: expected {sorted(expected_hashes)}, got {sorted(actual_hashes)}")
    for relative_path in sorted(set(actual_hashes) & set(expected_hashes)):
        actual_hash = actual_hashes[relative_path]
        expected_hash = expected_hashes[relative_path]
        if actual_hash != expected_hash:
            failures.append(
                f"{relative_path}: expected sha256 {expected_hash}, got {actual_hash}"
            )
    return failures


def _digest(value: Any, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(char in "0123456789abcdef" for char in value)
    )
