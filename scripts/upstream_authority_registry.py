"""Shared fail-closed reader for upstream contract authority pins."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


REGISTRY_PATH = Path(__file__).resolve().parent.parent / "benchmarks" / "upstream_authority_registry.json"
REQUIRED_AUTHORITIES = {"dspy_stable", "dspy_instruction_optimizers", "gepa_standalone", "req_llm"}
REQUIRED_CONTRACTS = {
    "dspy_stable_upstream_fidelity",
    "req_llm_beam_runtime_dependency",
    "t1_gepa_v011_structural_differential_contract",
    "t1_instruction_optimizer_differential_contract",
}


def load_registry_authority(
    contract_id: str, path: Path = REGISTRY_PATH
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        registry = json.loads(path.read_text())
        if registry.get("schema_version") != 1:
            raise ValueError("unsupported schema_version")
        authorities = registry["authorities"]
        contracts = registry["contracts"]
        if not REQUIRED_AUTHORITIES.issubset(authorities):
            raise ValueError("missing required authorities")
        if not REQUIRED_CONTRACTS.issubset(contracts):
            raise ValueError("missing required contracts")
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
        return registry, authority
    except (OSError, KeyError, TypeError, json.JSONDecodeError, ValueError) as exc:
        raise RuntimeError(f"invalid upstream authority registry {path.resolve()}: {exc}") from exc


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
