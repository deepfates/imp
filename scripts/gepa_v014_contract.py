#!/usr/bin/env python3
"""Emit provider-free structural contracts for pinned standalone GEPA v0.1.4.

The comparison imports the exact released helpers. It exercises no LM and
makes no effectiveness, paper-reproduction, or exact cross-runtime RNG claim.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import runpy
import subprocess
import sys
from functools import partial
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from upstream_authority_registry import (  # noqa: E402
    REGISTRY_PATH,
    load_registry_authority,
    source_hash_failures,
)

CONTRACT_ID = "t1_gepa_v014_structural_differential_contract"
load_authority_registry = partial(load_registry_authority, CONTRACT_ID)
UPSTREAM_REGISTRY, AUTHORITY = load_authority_registry()
EXPECTED_VERSION = AUTHORITY["version"]
EXPECTED_TAG = AUTHORITY["git_ref"].removeprefix("refs/tags/")
EXPECTED_COMMIT = AUTHORITY["commit"]
EXPECTED_PROJECT_VERSION = AUTHORITY["metadata"]["project_version"]
SOURCE_PINS = AUTHORITY["source_hashes"]

# The still-valid deterministic v0.1.1 fixtures are reusable harness code. Each
# helper imports and executes the GEPA modules from the v0.1.4 root placed first
# on sys.path below; no historical upstream output is substituted.
HISTORICAL_HARNESS = runpy.run_path(str(SCRIPT_DIR / "gepa_v011_contract.py"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args], check=False, capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed for {root}: {result.stderr.strip()}")
    return result.stdout.strip()


def project_version(root: Path) -> str:
    for line in (root / "pyproject.toml").read_text().splitlines():
        if line.startswith("version="):
            return line.split("=", 1)[1].strip().strip('"')
    return "missing"


def validate_pins(root: Path) -> list[dict[str, str]]:
    failures: list[str] = []
    commit = git(root, "rev-parse", "HEAD")
    tags = git(root, "tag", "--points-at", "HEAD").splitlines()
    declared_version = project_version(root)

    if commit != EXPECTED_COMMIT:
        failures.append(f"commit: expected {EXPECTED_COMMIT}, got {commit}")
    if EXPECTED_TAG not in tags:
        failures.append(f"tag: expected {EXPECTED_TAG} at HEAD, got {tags}")
    if declared_version != EXPECTED_PROJECT_VERSION:
        failures.append(
            f"pyproject version: expected tagged-source value {EXPECTED_PROJECT_VERSION}, got {declared_version}"
        )

    sources = []
    actual_hashes = {}
    for relative in SOURCE_PINS:
        path = root / relative
        actual = sha256(path) if path.is_file() else "missing"
        actual_hashes[relative] = actual
        sources.append({"path": relative, "sha256": actual})
    failures.extend(source_hash_failures(actual_hashes, AUTHORITY))

    if failures:
        raise RuntimeError("pinned GEPA validation failed:\n- " + "\n- ".join(failures))
    return sources


def _proposal(identifier: int, before: list[float], after: list[float]):
    from gepa.proposer.base import CandidateProposal, SubsampleEvaluation

    return CandidateProposal(
        candidate={"identifier": str(identifier)},
        parent_program_ids=[0],
        subsample_scores_before=before,
        subsample_scores_after=after,
        eval_before=SubsampleEvaluation(scores=before),
        eval_after=SubsampleEvaluation(scores=after),
        metadata={"identifier": identifier},
    )


def acceptance_contract() -> dict[str, Any]:
    from gepa.strategies.acceptance import ImprovementOrEqualAcceptance, StrictImprovementAcceptance

    fixtures = [([0.5, 0.3], [0.6, 0.4]), ([0.5, 0.3], [0.5, 0.3]),
                ([0.5, 0.3], [0.4, 0.2]), ([], [])]

    def rows(criterion):
        return [
            {"before": before, "after": after,
             "accepted": criterion.should_accept(_proposal(i, before, after), None)}
            for i, (before, after) in enumerate(fixtures)
        ]

    return {
        "derivation": "executed_upstream_acceptance_criteria",
        "strict_improvement": rows(StrictImprovementAcceptance()),
        "improvement_or_equal": rows(ImprovementOrEqualAcceptance()),
    }


def proposal_selection_contract() -> dict[str, Any]:
    from gepa.strategies.acceptance import StrictImprovementAcceptance
    from gepa.strategies.proposal_selection import AllImprovements, BestImprovement, TopKImprovements

    fixtures = [([0.5], [0.8]), ([0.5], [0.3]), ([0.5], [0.6]),
                ([0.5], [0.9]), ([0.5], [0.9])]
    proposals = [_proposal(i, before, after) for i, (before, after) in enumerate(fixtures)]
    criterion = StrictImprovementAcceptance()

    def ids(strategy):
        return [proposal.metadata["identifier"] for proposal in strategy.select(proposals, None, criterion)]

    return {
        "derivation": "executed_upstream_parallel_proposal_selection",
        "proposals": [
            {"id": i, "before": before, "after": after}
            for i, (before, after) in enumerate(fixtures)
        ],
        "all_improvements": ids(AllImprovements()),
        "best_improvement": ids(BestImprovement()),
        "top_k_2": ids(TopKImprovements(k=2)),
    }


def build_artifact(root: Path, sources: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "evidence_tier": CONTRACT_ID,
        "scope": "provider-free GEPA v0.1.4 structural semantics; not effectiveness evidence",
        "gepa": {
            "version": EXPECTED_VERSION,
            "tag": EXPECTED_TAG,
            "commit": EXPECTED_COMMIT,
            "project_metadata_version": EXPECTED_PROJECT_VERSION,
            "project_metadata_version_note":
                f"the {EXPECTED_TAG} tag retains version={EXPECTED_PROJECT_VERSION} in pyproject.toml",
            "checkout": str(root.resolve()),
            "sources": sources,
        },
        "acceptance": acceptance_contract(),
        "proposal_selection": proposal_selection_contract(),
        "pareto_selection": HISTORICAL_HARNESS["pareto_contract"](),
        "component_rotation": HISTORICAL_HARNESS["component_rotation_contract"](),
        "merge": HISTORICAL_HARNESS["merge_contract"](),
        "frontier_mappings": HISTORICAL_HARNESS["frontier_contract"](),
        "budget_stops": HISTORICAL_HARNESS["budget_stop_contract"](),
        "json_result_resume": HISTORICAL_HARNESS["json_result_contract"](),
        "named_program_mutation": HISTORICAL_HARNESS["named_mutation_contract"](),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    root = args.gepa_root.resolve()
    sys.path.insert(0, str(root / "src"))

    try:
        artifact = build_artifact(root, validate_pins(root))
    except Exception as exc:
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    rendered = json.dumps(artifact, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered)
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
