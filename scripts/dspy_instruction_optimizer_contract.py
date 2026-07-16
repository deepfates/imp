#!/usr/bin/env python3
"""Emit a provider-free DSPy MIPROv2/SIMBA T1 differential contract.

Run with the registry-pinned DSPy checkout first on ``PYTHONPATH``. The artifact is deliberately
timeless: identical source and inputs produce byte-for-byte identical JSON.
"""

from __future__ import annotations

import argparse
import hashlib
import inspect
import json
import random
import sys
import threading
from functools import partial
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from upstream_authority_registry import (  # noqa: E402
    REGISTRY_PATH,
    load_registry_authority,
    source_hash_failures as registry_source_hash_failures,
)

CONTRACT_ID = "t1_instruction_optimizer_differential_contract"
load_authority_registry = partial(load_registry_authority, CONTRACT_ID)


UPSTREAM_REGISTRY, AUTHORITY = load_authority_registry()
EXPECTED_VERSION = AUTHORITY["version"]
EXPECTED_COMMIT = AUTHORITY["commit"]

import dspy
from dspy.propose import grounded_proposer
from dspy.teleprompt import bootstrap as bootstrap_module
from dspy.teleprompt import mipro_optimizer_v2, simba, simba_utils, utils


SOURCE_PINS = {
    "dspy/propose/grounded_proposer.py": grounded_proposer,
    "dspy/teleprompt/bootstrap.py": bootstrap_module,
    "dspy/teleprompt/mipro_optimizer_v2.py": mipro_optimizer_v2,
    "dspy/teleprompt/simba.py": simba,
    "dspy/teleprompt/simba_utils.py": simba_utils,
    "dspy/teleprompt/utils.py": utils,
}

if set(SOURCE_PINS) != set(AUTHORITY["source_hashes"]):
    raise RuntimeError("DSPy contract source set is incompatible with the upstream authority registry")

REPEATED_CALL_RUNTIME_SOURCE_PINS = (
    {
        "path": "dspy/predict/predict.py",
        "sha256": "25acd81c09875e52442452fb318eff62161513de6fa08271e6a6766eb8d81a23",
    },
    {
        "path": "dspy/utils/dummies.py",
        "sha256": "e62b4cdaea8468277f4b11527d8c288e70a95a89d686982f089f1c26bf62a50c",
    },
    {
        "path": "dspy/utils/hasher.py",
        "sha256": "e04ed4699ddf39f2cf9992016b2ebbde715e0f16f255eec6f158a9fe86f477d2",
    },
)
REPEATED_CALL_TRACE_EXPRESSION = "trace.append((self, {**kwargs}, pred))"
REPEATED_CALL_SELECTION_EXPRESSION = (
    "demos = [rng.choice(demos[:-1]) if rng.random() < 0.5 else demos[-1]]"
)
REPEATED_CALL_CASE_SPECS = (
    {"id": "trace_set_0", "trace_set": 0},
    {"id": "trace_set_2", "trace_set": 2},
    {"id": "trace_set_3", "trace_set": 3},
    {"id": "trace_set_4", "trace_set": 4},
    {"id": "trace_set_5", "trace_set": 5},
    {"id": "trace_set_13", "trace_set": 13},
    {"id": "trace_set_30", "trace_set": 30},
)
EXPECTED_DSPY_REPEATED_CALL_OUTCOMES = {
    "trace_set_0": {
        "hasher_seed": "0460c53e6c18f543c88ad72c26a1cda739768f1a0c7ae6222eb47f71b6817e84",
        "rng_draw": 0.7157076233012117,
        "branch": "final",
        "selected_index": 3,
        "selected_call_id": "call_3",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
    "trace_set_2": {
        "hasher_seed": "2e37eef58a2ff9d19682684a2eb368c5cdc7856effd8a0b7bc91c91315a92644",
        "rng_draw": 0.8601016835594661,
        "branch": "final",
        "selected_index": 3,
        "selected_call_id": "call_3",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
    "trace_set_3": {
        "hasher_seed": "de3f5ae5261e369be2eb3bcc1f893af058ce02155c9e5b11c081f3a0d66e461a",
        "rng_draw": 0.2573183427206168,
        "branch": "earlier",
        "selected_index": 0,
        "selected_call_id": "call_0",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
    "trace_set_4": {
        "hasher_seed": "524ee8bb69ee7de2b014e71bd5ec5559849db9cd64ba1f485c1d2454d70ddf19",
        "rng_draw": 0.748174734575589,
        "branch": "final",
        "selected_index": 3,
        "selected_call_id": "call_3",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
    "trace_set_5": {
        "hasher_seed": "20708280eab2905c622c1ae25ec213371c6834f1aeb973a4fd387da7ef4d55f1",
        "rng_draw": 0.2170616038822879,
        "branch": "earlier",
        "selected_index": 1,
        "selected_call_id": "call_1",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
    "trace_set_13": {
        "hasher_seed": "3f8a151ec65a0bf07918da5a0c9d57d1f510a1c6ed92ca26e4e2267bd1f915bd",
        "rng_draw": 0.3303275522921808,
        "branch": "earlier",
        "selected_index": 2,
        "selected_call_id": "call_2",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
    "trace_set_30": {
        "hasher_seed": "b3f7ac72c6942122bc819a1bc11aed0c2ca007053090744f95364753870f99e7",
        "rng_draw": 0.5050866552652811,
        "branch": "final",
        "selected_index": 3,
        "selected_call_id": "call_3",
        "selected_count": 1,
        "runtime_predictor_call_count": 4,
        "runtime_lm_call_count": 4,
        "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
    },
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


def source_hash_failures(actual_hashes: dict[str, str], authority: dict[str, Any] = AUTHORITY) -> list[str]:
    return registry_source_hash_failures(actual_hashes, authority)


def validate_pins() -> list[dict[str, str]]:
    failures: list[str] = []
    version = getattr(dspy, "__version__", "unknown")
    if version != EXPECTED_VERSION:
        failures.append(f"DSPy version: expected {EXPECTED_VERSION}, got {version}")

    sources = []
    actual_hashes = {}
    for relative_path, module in SOURCE_PINS.items():
        path = Path(inspect.getsourcefile(module) or "").resolve()
        actual_hash = sha256(path) if path.is_file() else "missing"
        actual_hashes[relative_path] = actual_hash
        sources.append(
            {
                "path": relative_path,
                "sha256": actual_hash,
            }
        )

    dspy_root = Path(inspect.getsourcefile(dspy) or "").resolve().parent
    for pin in REPEATED_CALL_RUNTIME_SOURCE_PINS:
        source_path = dspy_root / Path(pin["path"]).relative_to("dspy")
        actual_hash = sha256(source_path) if source_path.is_file() else "missing"
        if actual_hash != pin["sha256"]:
            failures.append(
                f"{pin['path']}: expected {pin['sha256']}, got {actual_hash}"
            )

    failures.extend(source_hash_failures(actual_hashes))

    if failures:
        raise RuntimeError("pinned DSPy validation failed:\n- " + "\n- ".join(failures))
    return sources


def repeated_predictor_call_fixture() -> dict[str, Any]:
    from dspy.utils.hasher import Hasher

    class RepeatedCallTraceProgram(dspy.Module):
        """Provider-free program that makes fixed calls through DSPy's predictor runtime."""

        def __init__(self, calls: list[dict[str, Any]]) -> None:
            super().__init__()
            self.answerer = dspy.Predict("question -> hint")
            self.calls = calls
            self.runtime_trace: list[tuple[Any, Any, Any]] = []

        def forward(self, question: str) -> dspy.Prediction:
            del question
            for call in self.calls:
                prediction = self.answerer(**call["inputs"])
                if prediction["hint"] != call["outputs"]["hint"]:
                    raise RuntimeError("DSPy DummyLM returned an unexpected fixture output")
            self.runtime_trace = list(dspy.settings.trace)
            return dspy.Prediction(hint="fixture-complete")

    bootstrap_source = inspect.getsource(
        bootstrap_module.BootstrapFewShot._bootstrap_one_example
    )
    if REPEATED_CALL_SELECTION_EXPRESSION not in bootstrap_source:
        raise RuntimeError("pinned DSPy repeated-call selection expression drifted")
    predict_source = inspect.getsource(dspy.Predict._forward_postprocess)
    if REPEATED_CALL_TRACE_EXPRESSION not in predict_source:
        raise RuntimeError("pinned DSPy predictor trace expression drifted")

    cases = []
    for spec in REPEATED_CALL_CASE_SPECS:
        trace_set = spec["trace_set"]
        calls = [
            {
                "call_id": f"call_{index}",
                "inputs": {"question": f"fixture-{trace_set}-q-{index}"},
                "outputs": {"hint": f"fixture-{trace_set}-h-{index}"},
            }
            for index in range(4)
        ]
        program = RepeatedCallTraceProgram(calls)
        fixture_lm = dspy.utils.DummyLM([call["outputs"] for call in calls])
        bootstrap = object.__new__(bootstrap_module.BootstrapFewShot)
        bootstrap.teacher = program
        bootstrap.teacher_settings = {"lm": fixture_lm}
        bootstrap.metric = None
        bootstrap.metric_threshold = None
        bootstrap.max_errors = 10
        bootstrap.error_count = 0
        bootstrap.error_lock = threading.Lock()
        bootstrap.predictor2name = {id(program.answerer): "answerer"}
        bootstrap.name2traces = {"answerer": []}

        example = dspy.Example(question=f"fixture-{trace_set}").with_inputs("question")
        if not bootstrap._bootstrap_one_example(example, round_idx=0):
            raise RuntimeError(f"DSPy bootstrap rejected repeated-call fixture {spec['id']}")

        runtime_steps = [
            step for step in program.runtime_trace if step[0] is program.answerer
        ]
        if len(runtime_steps) != len(calls):
            raise RuntimeError(
                f"DSPy repeated-call fixture {spec['id']} executed "
                f"{len(runtime_steps)} predictor calls instead of {len(calls)}"
            )
        if len(fixture_lm.history) != len(calls):
            raise RuntimeError(
                f"DSPy repeated-call fixture {spec['id']} made "
                f"{len(fixture_lm.history)} LM calls instead of {len(calls)}"
            )
        for call, (_predictor, inputs, outputs) in zip(calls, runtime_steps, strict=True):
            if inputs != call["inputs"] or outputs["hint"] != call["outputs"]["hint"]:
                raise RuntimeError(
                    f"DSPy repeated-call fixture {spec['id']} runtime trace diverged from its calls"
                )

        demos = [
            dspy.Example(augmented=True, **inputs, **outputs)
            for _predictor, inputs, outputs in runtime_steps
        ]

        observed_demos = bootstrap.name2traces["answerer"]
        if len(observed_demos) != 1:
            raise RuntimeError(
                f"DSPy repeated-call fixture {spec['id']} selected "
                f"{len(observed_demos)} demos instead of one"
            )

        observed_demo = observed_demos[0]
        observed_index = next(
            index
            for index, call in enumerate(calls)
            if observed_demo["question"] == call["inputs"]["question"]
            and observed_demo["hint"] == call["outputs"]["hint"]
        )

        hasher_seed = Hasher.hash(tuple(demos))
        rng = random.Random(hasher_seed)
        rng_draw = rng.random()

        if rng_draw < 0.5:
            selected_demo = rng.choice(demos[:-1])
            branch = "earlier"
        else:
            selected_demo = demos[-1]
            branch = "final"

        selected_index = next(
            index for index, demo in enumerate(demos) if demo is selected_demo
        )
        if observed_index != selected_index:
            raise RuntimeError(
                f"DSPy source behavior and Hasher/RNG projection disagree for {spec['id']}: "
                f"source selected {observed_index}, projection selected {selected_index}"
            )

        outcome = {
            "hasher_seed": hasher_seed,
            "rng_draw": rng_draw,
            "branch": branch,
            "selected_index": observed_index,
            "selected_call_id": calls[observed_index]["call_id"],
            "selected_count": len(observed_demos),
            "runtime_predictor_call_count": len(runtime_steps),
            "runtime_lm_call_count": len(fixture_lm.history),
            "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
        }
        expected = EXPECTED_DSPY_REPEATED_CALL_OUTCOMES[spec["id"]]
        if outcome != expected:
            raise RuntimeError(
                f"pinned DSPy repeated-call fixture drift for {spec['id']}: "
                f"expected {expected!r}, got {outcome!r}"
            )

        cases.append(
            {
                "id": spec["id"],
                "trajectory_index": 0,
                "predictor_name": "answerer",
                "calls": calls,
                "dspy": outcome,
            }
        )

    return {
        "fixture_id": "bootstrap-repeated-predictor-calls-v3",
        "scope": (
            "seven fixed trace inputs executed through both predictor runtimes; "
            "branch and earlier-index coverage, not an empirical distribution estimate"
        ),
        "source_hashes": {
            "dspy/teleprompt/bootstrap.py": AUTHORITY["source_hashes"][
                "dspy/teleprompt/bootstrap.py"
            ],
            **{pin["path"]: pin["sha256"] for pin in REPEATED_CALL_RUNTIME_SOURCE_PINS},
        },
        "algorithm": {
            "observed_via": "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
            "runtime_call_probe": "DummyLM.history plus dspy.Predict trace identity",
            "trace_source_expression": REPEATED_CALL_TRACE_EXPRESSION,
            "source_expression": REPEATED_CALL_SELECTION_EXPRESSION,
            "rng": "Python random.Random",
            "seed": "Hasher.hash(tuple(demos))",
            "branch_draw": "rng.random()",
            "earlier_when": "branch_draw < 0.5",
            "earlier_choice": "rng.choice(demos[:-1])",
            "final_choice": "demos[-1]",
            "probability_basis": "uniform random.Random.random() variate",
            "branch_probability_model": {"earlier": 0.5, "final": 0.5},
        },
        "cases": cases,
    }


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
        "evidence_tier": CONTRACT_ID,
        "scope": "provider-free operational control-flow contract; not optimizer effectiveness evidence",
        "dspy": {
            "version": EXPECTED_VERSION,
            "commit": EXPECTED_COMMIT,
            "sources": sources,
        },
        "mipro_v2": {
            "budgets": mipro_budgets(),
            "bootstrap_repeated_predictor_calls": repeated_predictor_call_fixture(),
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
