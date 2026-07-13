#!/usr/bin/env python3
"""Emit a provider-free DSPy MIPROv2/SIMBA T1 differential contract.

Run with DSPy 3.3.0b1 first on ``PYTHONPATH``.  The artifact is deliberately
timeless: identical source and inputs produce byte-for-byte identical JSON.
"""

from __future__ import annotations

import argparse
import hashlib
import inspect
import json
import random
import sys
from pathlib import Path
from typing import Any

import dspy
from dspy.propose import grounded_proposer
from dspy.teleprompt import mipro_optimizer_v2, simba, simba_utils, utils


EXPECTED_VERSION = "3.3.0b1"
EXPECTED_COMMIT = "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
SOURCE_PINS = {
    "dspy/propose/grounded_proposer.py": (
        grounded_proposer,
        "c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3",
    ),
    "dspy/teleprompt/bootstrap.py": (
        __import__("dspy.teleprompt.bootstrap", fromlist=["bootstrap"]),
        "0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255",
    ),
    "dspy/teleprompt/mipro_optimizer_v2.py": (
        mipro_optimizer_v2,
        "6bf7632836d3a54ab0da3f38a8f1963813472312e9c0e3f2ff19b4377af407f3",
    ),
    "dspy/teleprompt/simba.py": (
        simba,
        "4de72e1d0cb1cd30a180569c21973c41fa272c3ebb82a365e3f307986ab67a55",
    ),
    "dspy/teleprompt/simba_utils.py": (
        simba_utils,
        "ed745647ffcfcf4090e5d5b5489cd0b13ebfff1d38a22559563f4f606b31fb2c",
    ),
    "dspy/teleprompt/utils.py": (
        utils,
        "218c38c25dde75aab9b1d452a15c75687c2e1842d7157dcc6c695f5adbcaf182",
    ),
}


class DummyProgram:
    def __init__(self, predictor_count: int) -> None:
        self._predictors = [object() for _ in range(predictor_count)]

    def predictors(self) -> list[object]:
        return self._predictors


class FakeLM:
    """Minimal LM surface consumed by prepare_models_for_resampling."""

    def __init__(self, name: str, **kwargs: Any) -> None:
        self.name = name
        self.kwargs = dict(kwargs)

    def copy(self, **kwargs: Any) -> "FakeLM":
        merged = {**self.kwargs, **kwargs}
        return FakeLM(self.name, **merged)


class FakeProgram:
    def __init__(self, lm: FakeLM) -> None:
        self.lm = lm

    def get_lm(self) -> FakeLM:
        return self.lm


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_pins() -> list[dict[str, str]]:
    failures: list[str] = []
    version = getattr(dspy, "__version__", "unknown")
    if version != EXPECTED_VERSION:
        failures.append(f"DSPy version: expected {EXPECTED_VERSION}, got {version}")

    sources = []
    for relative_path, (module, expected_hash) in SOURCE_PINS.items():
        path = Path(inspect.getsourcefile(module) or "").resolve()
        actual_hash = sha256(path) if path.is_file() else "missing"
        if actual_hash != expected_hash:
            failures.append(
                f"{relative_path}: expected sha256 {expected_hash}, got {actual_hash} ({path})"
            )
        sources.append(
            {
                "path": relative_path,
                "sha256": actual_hash,
            }
        )

    if failures:
        raise RuntimeError("pinned DSPy validation failed:\n- " + "\n- ".join(failures))
    return sources


def bare_mipro(auto: str | None, seed: int = 9) -> mipro_optimizer_v2.MIPROv2:
    optimizer = object.__new__(mipro_optimizer_v2.MIPROv2)
    optimizer.auto = auto
    optimizer.rng = random.Random(seed)
    return optimizer


def mipro_budgets() -> dict[str, Any]:
    program = DummyProgram(2)
    auto_rows = []
    for mode in ("light", "medium", "heavy"):
        for zeroshot in (False, True):
            optimizer = bare_mipro(mode)
            trials, valset, minibatch, instructions, fewshot = optimizer._set_hyperparams_from_run_mode(
                program=program,
                num_trials=None,
                minibatch=False,
                zeroshot_opt=zeroshot,
                valset=list(range(1_200)),
                num_instruct_candidates=None,
                num_fewshot_candidates=None,
            )
            auto_rows.append(
                {
                    "mode": mode,
                    "zeroshot": zeroshot,
                    "predictors": 2,
                    "num_trials": trials,
                    "num_instruct_candidates": instructions,
                    "num_fewshot_candidates": fewshot,
                    "valset_size": len(valset),
                    "minibatch": minibatch,
                }
            )

    manual = bare_mipro(None)
    manual_result = manual._set_hyperparams_from_run_mode(
        program=program,
        num_trials=17,
        minibatch=True,
        zeroshot_opt=False,
        valset=list(range(80)),
        num_instruct_candidates=5,
        num_fewshot_candidates=5,
    )
    return {
        "derivation": "executed_upstream_helpers",
        "helpers": [
            "MIPROv2._set_hyperparams_from_run_mode",
            "MIPROv2._set_num_trials_from_num_candidates",
        ],
        "auto": auto_rows,
        "manual": {
            "requested": {
                "num_trials": 17,
                "minibatch": True,
                "num_instruct_candidates": 5,
                "num_fewshot_candidates": 5,
                "valset_size": 80,
            },
            "derived": {
                "num_trials": manual_result[0],
                "valset_size": len(manual_result[1]),
                "minibatch": manual_result[2],
                "num_instruct_candidates": manual_result[3],
                "num_fewshot_candidates": manual_result[4],
            },
            "recommended_trials_from_5_candidates": {
                "fewshot": manual._set_num_trials_from_num_candidates(program, False, 5),
                "zeroshot": manual._set_num_trials_from_num_candidates(program, True, 5),
            },
        },
    }


def demo_arm_topology() -> dict[str, Any]:
    def arms(num_candidate_sets: int, max_labeled_demos: int) -> list[dict[str, Any]]:
        # Exact branch projection of create_n_fewshot_demo_sets. Provider calls
        # prevent executing these branches without changing their semantics.
        rows = []
        for seed in range(-3, num_candidate_sets - 3):
            if seed == -3:
                kind = "zero_shot"
            elif seed == -2 and max_labeled_demos > 0:
                kind = "labels_only"
            elif seed == -1:
                kind = "unshuffled_bootstrap"
            else:
                kind = "shuffled_bootstrap"
            rows.append({"slot": seed + 3, "internal_seed": seed, "kind": kind})
        return rows

    return {
        "derivation": "source_derived_fixture",
        "source": "dspy/teleprompt/utils.py:create_n_fewshot_demo_sets",
        "fixture": {
            "num_candidate_sets": 6,
            "max_bootstrapped_demos": 4,
            "include_non_bootstrapped": True,
        },
        "with_labels": arms(6, 4),
        "zero_labels": arms(6, 0),
        "zero_label_invariant": (
            "the labels-only branch is not removed; slot 1 falls through to shuffled bootstrap"
        ),
        "zeroshot_mipro_invariant": (
            "MIPRO asks bootstrap for 3 bootstrapped and 0 labeled demos for proposal context, "
            "then sets demo_candidates=None before parameter optimization"
        ),
    }


def proposal_rotation() -> dict[str, Any]:
    set_ids = list(range(6))
    slots = []
    for slot in range(min(3, len(set_ids))):
        rotation = [set_ids[slot], *set_ids[slot + 1 :], *set_ids[:slot]]
        slots.append(
            {
                "proposal_slot": slot,
                "demo_set_rotation": rotation,
                "task_demos_forced_to_none": slot == 0,
            }
        )
    return {
        "derivation": "source_derived_fixture",
        "source": "dspy/propose/grounded_proposer.py:GroundedProposer.propose_instructions_for_program;GenerateModuleInstruction.forward",
        "fixture": {"instruction_slots": 3, "demo_sets": set_ids},
        "slots": slots,
        "invariants": [
            "proposal count per predictor is min(N, number of demo sets)",
            "each slot rotates its matching demo set to the front without changing the remaining cyclic order",
            "slot 0 always renders 'No task demos provided.' even if augmented demos were gathered",
        ],
    }


def minibatch_schedule(num_trials: int, full_eval_steps: int) -> dict[str, Any]:
    extra_at_end = int(num_trials % full_eval_steps != 0)
    adjusted = num_trials + num_trials // full_eval_steps + 1 + extra_at_end
    next_study_number = 1  # Baseline is Optuna trial number 0.
    objective_trial_numbers = []
    full_evaluations = []
    for objective_index in range(1, num_trials + 1):
        trial_num = next_study_number + 1
        objective_trial_numbers.append(trial_num)
        next_study_number += 1
        if trial_num % (full_eval_steps + 1) == 0 or trial_num == adjusted - 1:
            full_evaluations.append(
                {
                    "after_objective": objective_index,
                    "trigger_trial_num": trial_num,
                    "log_trial_num": trial_num + 1,
                }
            )
            next_study_number += 1  # _perform_full_evaluation adds an Optuna trial.
    return {
        "num_trials": num_trials,
        "minibatch_full_eval_steps": full_eval_steps,
        "adjusted_num_trials": adjusted,
        "baseline_full_evaluation_log_trial": 1,
        "objective_trial_numbers": objective_trial_numbers,
        "periodic_full_evaluations": full_evaluations,
    }


def categorical_shape() -> dict[str, Any]:
    optimizer = bare_mipro(None)
    instructions = {0: ["i0", "i1", "i2"], 1: ["j0", "j1"]}
    demos = {0: [[], [], [], []], 1: [[], [], [], []]}

    def normalize(distributions: dict[str, Any]) -> dict[str, Any]:
        return {
            name: {
                "distribution": type(distribution).__name__,
                "choices": list(distribution.choices),
            }
            for name, distribution in sorted(distributions.items())
        }

    return {
        "derivation": "executed_upstream_helper",
        "helper": "MIPROv2._get_param_distributions",
        "with_demos": normalize(
            optimizer._get_param_distributions(DummyProgram(2), instructions, demos)
        ),
        "without_demos": normalize(
            optimizer._get_param_distributions(DummyProgram(2), instructions, None)
        ),
        "invariant": "one instruction categorical per predictor and, only when demos are truthy, one demo categorical per predictor",
    }


def simba_buckets() -> dict[str, Any]:
    model_major_scores = [
        [0.1, 0.9, 0.5, 0.2],
        [0.8, 0.4, 0.5, 0.7],
        [0.2, 0.1, 0.5, 0.3],
    ]
    flat = [score for model_scores in model_major_scores for score in model_scores]
    batch_size = len(model_major_scores[0])
    buckets = []
    for example_index in range(batch_size):
        scores = sorted(flat[example_index::batch_size], reverse=True)
        maximum, minimum = scores[0], scores[-1]
        average = sum(scores) / len(scores)
        buckets.append(
            {
                "example_index": example_index,
                "scores_desc": scores,
                "sort_key": [maximum - minimum, maximum, maximum - average],
            }
        )
    buckets.sort(key=lambda row: row["sort_key"], reverse=True)
    scores_array = simba.np.asarray(flat)
    return {
        "derivation": "source_derived_fixture_using_upstream_numpy_binding",
        "source": "dspy/teleprompt/simba.py:SIMBA.compile STEP 3",
        "fixture": {"model_major_scores": model_major_scores},
        "percentiles": {
            "p10": float(simba.np.percentile(scores_array, 10)),
            "p90": float(simba.np.percentile(scores_array, 90)),
        },
        "ordered_buckets": buckets,
        "ordering_invariant": "descending lexicographic (max-min gap, max score, max-average gap)",
    }


def finalist_indices(max_winning_index: int, num_candidates: int) -> list[int]:
    count = num_candidates + 1
    if max_winning_index < 1:
        indices = [0] * count
    else:
        indices = [round(i * max_winning_index / (count - 1)) for i in range(count)]
    return list(dict.fromkeys(indices))


def demo_eviction(seed: int, num_demos: int, max_demos: int) -> dict[str, Any]:
    rng = random.Random(seed)
    rng_np = simba.np.random.default_rng(seed)
    denominator = max_demos if max_demos > 0 else 3
    requested = max(
        int(rng_np.poisson(num_demos / denominator)),
        int(num_demos >= denominator),
    )
    requested = min(requested, num_demos)
    sampled = [rng.randrange(num_demos) for _ in range(requested)] if num_demos else []
    return {
        "seed": seed,
        "num_demos": num_demos,
        "max_demos": max_demos,
        "poisson_denominator": denominator,
        "requested_drop_count": requested,
        "sampled_indices_with_replacement": sampled,
        "actually_removed_indices": sorted(set(sampled)),
    }


def rollout_models() -> dict[str, Any]:
    base = FakeLM("base", rollout_id=7, cache=False)
    no_teacher = simba_utils.prepare_models_for_resampling(FakeProgram(base), 4)

    teacher = FakeLM("teacher", rollout_id=100)
    with_teacher = simba_utils.prepare_models_for_resampling(
        FakeProgram(base), 4, {"lm": teacher}
    )

    def describe(models: list[FakeLM], teacher_lm: FakeLM | None = None) -> list[dict[str, Any]]:
        return [
            {
                "model_name": model.name,
                "rollout_id": model.kwargs["rollout_id"],
                "temperature": model.kwargs.get("temperature"),
                "is_teacher_object": model is teacher_lm,
            }
            for model in models
        ]

    return {
        "derivation": "executed_upstream_helper",
        "helper": "prepare_models_for_resampling",
        "base_start_rollout_id": 7,
        "without_teacher": describe(no_teacher),
        "with_teacher": describe(with_teacher, teacher),
        "teacher_rollout_id_after_call": teacher.kwargs["rollout_id"],
        "invariants": [
            "rollout IDs are consecutive starting at the base LM's rollout_id, defaulting to zero",
            "copies use temperature 1.0",
            "an explicit teacher occupies and is mutated to the first rollout ID; base copies start at the second ID",
        ],
    }


def tied_rule_semantics() -> dict[str, Any]:
    cases = []
    for name, score, p10, p90 in (
        ("at_lower_boundary", 0.2, 0.2, 0.8),
        ("at_upper_boundary", 0.8, 0.2, 0.8),
        ("strictly_between", 0.5, 0.2, 0.8),
    ):
        suppressed = score <= p10 or score >= p90
        cases.append(
            {
                "id": name,
                "good_score": score,
                "bad_score": score,
                "batch_p10": p10,
                "batch_p90": p90,
                "eligible": not suppressed,
                "result": (
                    "strategy_returns_false_before_provider"
                    if suppressed
                    else "good_trajectory_replaced_with_NA_then_provider_is_invoked"
                ),
            }
        )
    return {
        "derivation": "source_derived_fixture",
        "source": "dspy/teleprompt/simba_utils.py:append_a_rule",
        "cases": cases,
        "invariants": [
            "eligibility is strict: good > p10 and bad < p90",
            "an eligible tie enters good <= bad; because eligibility implies score < p90, the good trajectory is the side suppressed as N/A",
        ],
    }


def build_artifact(sources: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "evidence_tier": "t1_instruction_optimizer_differential_contract",
        "scope": "provider-free operational control-flow contract; not optimizer effectiveness evidence",
        "dspy": {
            "version": EXPECTED_VERSION,
            "commit": EXPECTED_COMMIT,
            "sources": sources,
        },
        "mipro_v2": {
            "budgets": mipro_budgets(),
            "demo_arm_topology": demo_arm_topology(),
            "proposal_rotation": proposal_rotation(),
            "released_minibatch_schedule": {
                "derivation": "source_derived_fixture",
                "source": "dspy/teleprompt/mipro_optimizer_v2.py:MIPROv2._optimize_prompt_parameters",
                "cases": [minibatch_schedule(10, 5), minibatch_schedule(12, 5)],
            },
            "categorical_parameter_shape": categorical_shape(),
        },
        "simba": {
            "batch_bucket_ordering": simba_buckets(),
            "finalist_index_selection": {
                "derivation": "source_derived_fixture",
                "source": "dspy/teleprompt/simba.py:SIMBA.compile final validation",
                "cases": [
                    {"max_winning_index": m, "num_candidates": n, "indices": finalist_indices(m, n)}
                    for m, n in ((0, 6), (3, 6), (8, 6), (6, 4))
                ],
                "invariant": "rounded evenly spaced winning-history indices are de-duplicated in first-seen order",
            },
            "demo_eviction": {
                "derivation": "source_derived_fixture_using_upstream_numpy_binding",
                "source": "dspy/teleprompt/simba.py:SIMBA.compile STEP 4",
                "cases": [
                    demo_eviction(7, 0, 4),
                    demo_eviction(7, 2, 4),
                    demo_eviction(7, 4, 4),
                    demo_eviction(5, 4, 4),
                    demo_eviction(7, 3, 0),
                ],
                "invariants": [
                    "Poisson mean is max predictor demo count divided by max_demos (or 3 when max_demos <= 0)",
                    "at least one drop is requested at capacity",
                    "indices are sampled with replacement, so actual removals may be fewer than the requested count",
                    "the same sampled index set is removed from every predictor",
                ],
            },
            "rollout_model_ids": rollout_models(),
            "tied_rule_semantics": tied_rule_semantics(),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="also write the deterministic JSON to this path")
    args = parser.parse_args()

    try:
        artifact = build_artifact(validate_pins())
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
