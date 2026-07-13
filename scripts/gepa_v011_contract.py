#!/usr/bin/env python3
"""Emit provider-free structural contracts for GEPA v0.1.1.

The script requires an exact source checkout. It imports only released GEPA
helpers and uses deterministic fixtures; it does not invoke an LM or provider.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any


EXPECTED_VERSION = "0.1.1"
EXPECTED_TAG = "v0.1.1"
EXPECTED_COMMIT = "b4dbb55b7601dac448cdb836d5a401ca7d9eb920"
# v0.1.1 was tagged with 0.1.0 still present in pyproject.toml. Pin both facts
# so a repackaged wheel or a later checkout cannot masquerade as this source.
EXPECTED_PROJECT_VERSION = "0.1.0"
SOURCE_PINS = {
    "src/gepa/core/engine.py": "92627720354261b9eb5359337b9b237a2a29ebf179b22a4b724b737bde81a088",
    "src/gepa/core/result.py": "5ee9ccfdf31e2d4d1262793c569e44ef7b39659a3e971e4f3dc7d656d69a1d85",
    "src/gepa/core/state.py": "08108908eb922808c2ad134c9717d32b107581a5766e6b99199c248d538999e5",
    "src/gepa/gepa_utils.py": "60aca7024e31a3e273a01187a6329f381f297a77ec7b6add4b9c90b4d64e9b6c",
    "src/gepa/proposer/merge.py": "cd0a3254927e399d0cae4a212076f7577161027b3c4ff19d03c3d2150408ee5a",
    "src/gepa/strategies/component_selector.py": "248cc6eb125eeddaa98f90b7780db2754ec0444a6143aeb1f97ff5660cf39568",
    "src/gepa/utils/stop_condition.py": "3f18fa989a376711dc198d60963dc9b866da6d5a81f5c5339e242b3301764a0c",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=False,
        capture_output=True,
        text=True,
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
    for relative, expected in SOURCE_PINS.items():
        path = root / relative
        actual = sha256(path) if path.is_file() else "missing"
        if actual != expected:
            failures.append(f"{relative}: expected sha256 {expected}, got {actual}")
        sources.append({"path": relative, "sha256": actual})

    if failures:
        raise RuntimeError("pinned GEPA validation failed:\n- " + "\n- ".join(failures))
    return sources


def normalize(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): normalize(item) for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))}
    if isinstance(value, (set, tuple)):
        return [normalize(item) for item in sorted(value, key=str)]
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def acceptance_contract() -> dict[str, Any]:
    # Exact projections of GEPAEngine.run's released acceptance branches.
    mutation = [
        {"before": before, "after": after, "accepted": after > before}
        for before, after in ((1.0, 1.1), (1.0, 1.0), (1.0, 0.9))
    ]
    merge = [
        {"parent_scores": parents, "after": after, "accepted": after >= max(parents)}
        for parents, after in (([1.0, 0.5], 1.1), ([1.0, 0.5], 1.0), ([1.0, 0.5], 0.9))
    ]
    return {
        "derivation": "source_exact_branch_fixture",
        "source": "src/gepa/core/engine.py:GEPAEngine.run",
        "mutation": mutation,
        "merge": merge,
    }


def pareto_contract() -> dict[str, Any]:
    from gepa.gepa_utils import remove_dominated_programs, select_program_candidate_from_pareto_front

    mapping = {"x": {0}, "y": {0}, "z": {1}}
    scores = [0.7, 0.8]
    reduced = remove_dominated_programs(mapping, scores=scores)
    rng = random.Random(17)
    draws = [select_program_candidate_from_pareto_front(mapping, scores, rng) for _ in range(300)]
    counts = {str(candidate): draws.count(candidate) for candidate in sorted(set(draws))}
    return {
        "derivation": "executed_upstream_helpers",
        "helpers": ["remove_dominated_programs", "select_program_candidate_from_pareto_front"],
        "mapping": normalize(mapping),
        "reduced_mapping": normalize(reduced),
        "draw_count": len(draws),
        "counts": counts,
        "coverage_weighted_invariant": counts["0"] > counts["1"],
    }


def component_rotation_contract() -> dict[str, Any]:
    from gepa.strategies.component_selector import RoundRobinReflectionComponentSelector

    state = SimpleNamespace(
        named_predictor_id_to_update_next_for_program_candidate=[0],
        list_of_named_predictors=["critic", "planner", "writer"],
    )
    selector = RoundRobinReflectionComponentSelector()
    selected = [selector(state, [], [], 0, {})[0] for _ in range(5)]
    return {
        "derivation": "executed_upstream_helper",
        "helper": "RoundRobinReflectionComponentSelector.__call__",
        "selected": selected,
        "next_cursor": state.named_predictor_id_to_update_next_for_program_candidate[0],
    }


def merge_contract() -> dict[str, Any]:
    from gepa.proposer.merge import (
        filter_ancestors,
        find_common_ancestor_pair,
        sample_and_attempt_merge_programs_by_common_predictors,
    )

    candidates = [
        {"planner": "base planner", "writer": "base writer", "critic": "base critic"},
        {"planner": "left planner", "writer": "base writer", "critic": "left critic"},
        {"planner": "base planner", "writer": "right writer", "critic": "right critic"},
    ]
    parents = [[], [0], [0]]
    aggregate_scores = [0.1, 0.6, 0.7]
    eligible = filter_ancestors(1, 2, {0}, ([], []), aggregate_scores, candidates)
    blocked_by_quality = filter_ancestors(1, 2, {0}, ([], []), [0.9, 0.6, 0.7], candidates)
    blocked_as_repeated = filter_ancestors(1, 2, {0}, ([(1, 2, 0)], []), aggregate_scores, candidates)
    ancestor_triplet = find_common_ancestor_pair(
        random.Random(0), parents, [1, 2], ([], []), aggregate_scores, candidates, max_attempts=3
    )

    performed: tuple[list[tuple[int, int, int]], list[Any]] = ([], [])
    merged = sample_and_attempt_merge_programs_by_common_predictors(
        aggregate_scores,
        random.Random(0),
        [1, 2],
        performed,
        candidates,
        parents,
        has_val_support_overlap=lambda _left, _right: True,
        max_attempts=3,
    )
    assert merged is not None
    merged_candidate, left, right, ancestor = merged
    overlap_blocked = sample_and_attempt_merge_programs_by_common_predictors(
        aggregate_scores,
        random.Random(0),
        [1, 2],
        ([], []),
        candidates,
        parents,
        has_val_support_overlap=lambda _left, _right: False,
        max_attempts=3,
    )
    return {
        "derivation": "executed_upstream_helpers",
        "helpers": ["filter_ancestors", "find_common_ancestor_pair", "sample_and_attempt_merge_programs_by_common_predictors"],
        "eligible_ancestors": eligible,
        "quality_filtered": blocked_by_quality,
        "repeated_filtered": blocked_as_repeated,
        "ancestor_triplet": list(ancestor_triplet or []),
        "merged_candidate": normalize(merged_candidate),
        "merged_parent_ids": [left, right],
        "merged_ancestor": ancestor,
        "overlap_blocked": overlap_blocked is None,
    }


def make_state(frontier_type: str):
    from gepa.core.state import GEPAState, ValsetEvaluation

    base = ValsetEvaluation(
        outputs_by_val_id={"v0": None, "v1": None},
        scores_by_val_id={"v0": 0.2, "v1": 0.2},
        objective_scores_by_val_id={
            "v0": {"quality": 0.5, "safety": 0.5},
            "v1": {"quality": 0.5, "safety": 0.5},
        },
    )
    state = GEPAState({"main": "base"}, base, frontier_type=frontier_type)
    fixtures = [
        (
            {"main": "quality"},
            {"v0": 1.0, "v1": 0.0},
            {"v0": {"quality": 1.0, "safety": 0.2}, "v1": {"quality": 0.8, "safety": 0.4}},
        ),
        (
            {"main": "safety"},
            {"v0": 0.0, "v1": 1.0},
            {"v0": {"quality": 0.6, "safety": 1.0}, "v1": {"quality": 0.6, "safety": 1.0}},
        ),
    ]
    for candidate, scores, objectives in fixtures:
        state.update_state_with_new_program(
            [0],
            candidate,
            ValsetEvaluation(
                outputs_by_val_id={"v0": None, "v1": None},
                scores_by_val_id=scores,
                objective_scores_by_val_id=objectives,
            ),
            None,
            0,
        )
    return state


def frontier_contract() -> dict[str, Any]:
    def canonical(policy: str) -> list[dict[str, Any]]:
        rows = []
        for key, winners in make_state(policy).get_pareto_front_mapping().items():
            if policy == "instance":
                dimension = ["instance", key]
            elif policy == "objective":
                dimension = ["objective", key]
            elif policy == "hybrid":
                kind, identity = key
                dimension = ["instance" if kind == "val_id" else kind, identity]
            else:
                _kind, val_id, objective = key
                dimension = ["cartesian", val_id, objective]
            rows.append({"dimension": dimension, "winners": sorted(winners)})
        return sorted(rows, key=lambda row: json.dumps(row["dimension"]))

    return {policy: canonical(policy) for policy in ("instance", "objective", "hybrid", "cartesian")}


def budget_stop_contract() -> dict[str, Any]:
    from gepa.utils.stop_condition import (
        MaxCandidateProposalsStopper,
        MaxMetricCallsStopper,
        NoImprovementStopper,
        ScoreThresholdStopper,
    )

    metric = MaxMetricCallsStopper(10)
    proposals = MaxCandidateProposalsStopper(3)
    threshold = ScoreThresholdStopper(0.9)
    no_improvement = NoImprovementStopper(2)
    metric_rows = [metric(SimpleNamespace(total_num_evals=value)) for value in (9, 10)]
    proposal_rows = [proposals(SimpleNamespace(i=value)) for value in (1, 2)]
    threshold_rows = [
        threshold(SimpleNamespace(program_full_scores_val_set=[value])) for value in (0.89, 0.9)
    ]
    no_improvement_rows = [
        no_improvement(SimpleNamespace(program_full_scores_val_set=[value]))
        for value in (0.5, 0.5, 0.6, 0.59, 0.6)
    ]
    return {
        "derivation": "executed_upstream_helpers",
        "metric_calls_at_9_10": metric_rows,
        "candidate_proposals_i_at_1_2": proposal_rows,
        "score_threshold_at_089_09": threshold_rows,
        "no_improvement_sequence": no_improvement_rows,
    }


def json_result_contract() -> dict[str, Any]:
    from gepa.core.result import GEPAResult

    result = GEPAResult(
        candidates=[{"planner": "base", "writer": "clear"}, {"planner": "plan", "writer": "clear"}],
        parents=[[None], [0]],
        val_aggregate_scores=[0.5, 0.75],
        val_subscores=[{"v0": 0.5}, {"v0": 0.75}],
        per_val_instance_best_candidates={"v0": {1}},
        discovery_eval_counts=[0, 3],
        total_metric_calls=7,
        num_full_val_evals=2,
        seed=19,
    )
    encoded = json.dumps(result.to_dict(), sort_keys=True)
    restored = GEPAResult.from_dict(json.loads(encoded))
    rng = random.Random(result.seed)
    return {
        "derivation": "executed_upstream_GEPAResult_JSON_roundtrip",
        "roundtrip_equal": restored.to_dict() == result.to_dict(),
        "best_candidate": normalize(restored.best_candidate),
        "seed": restored.seed,
        "seed_replay_draws": [rng.randrange(1000) for _ in range(4)],
        "live_rng_state_serialized": False,
    }


def named_mutation_contract() -> dict[str, Any]:
    candidate = {"planner": "base planner", "writer": "base writer"}
    proposed = dict(candidate)
    proposed["writer"] = "concise writer"
    return {
        "derivation": "provider_free_named_candidate_fixture",
        "before": candidate,
        "component": "writer",
        "text": "concise writer",
        "after": proposed,
        "unchanged_components": ["planner"],
    }


def build_artifact(root: Path, sources: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "evidence_tier": "t1_gepa_v011_structural_differential_contract",
        "scope": "provider-free GEPA v0.1.1 structural semantics; not effectiveness evidence",
        "gepa": {
            "version": EXPECTED_VERSION,
            "tag": EXPECTED_TAG,
            "commit": EXPECTED_COMMIT,
            "project_metadata_version": EXPECTED_PROJECT_VERSION,
            "project_metadata_version_note": "the v0.1.1 tag retains version=0.1.0 in pyproject.toml",
            "checkout": str(root.resolve()),
            "sources": sources,
        },
        "acceptance": acceptance_contract(),
        "pareto_selection": pareto_contract(),
        "component_rotation": component_rotation_contract(),
        "merge": merge_contract(),
        "frontier_mappings": frontier_contract(),
        "budget_stops": budget_stop_contract(),
        "json_result_resume": json_result_contract(),
        "named_program_mutation": named_mutation_contract(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gepa-root", type=Path, required=True, help="exact GEPA v0.1.1 checkout")
    parser.add_argument("--out", type=Path, help="also write deterministic JSON here")
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
