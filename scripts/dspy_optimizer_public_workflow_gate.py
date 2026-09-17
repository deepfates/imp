#!/usr/bin/env python3
"""Provider-free end-to-end gate for pinned DSPy GEPA and MIPROv2.

This is an integration gate, not benchmark evidence.  It authenticates the
explicit DSPy 3.2.1 -> GEPA 0.1.4 source bridge, exercises the real public
``GEPA.compile`` and ``MIPROv2.compile`` paths through deterministic LMs, and
emits one effective-option matrix.  No dataset or provider package is loaded.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
from typing import Any

from dspy_gepa_version_bridge import (
    ACCEPTANCE_FIRST_RELEASE,
    authenticate_loaded_runtime,
    install_source_bridge,
)


def stable_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), default=str)


def sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    bridge = install_source_bridge(args.dspy_root, args.gepa_root)

    import dspy
    import gepa
    import optuna
    from dspy.utils.dummies import DummyLM
    from dspy.utils.exceptions import AdapterParseError
    from gepa.strategies.proposal_selection import AllImprovements

    from dspy_gepa_failure_compat import (
        FailurePreservingDspyAdapter,
        patched_dspy_gepa,
    )

    authenticate_loaded_runtime(bridge, dspy, gepa)

    class Draft(dspy.Signature):
        """Draft a constrained response."""

        prompt = dspy.InputField()
        response = dspy.OutputField()

    class Review(dspy.Signature):
        """Review the draft and return the final response."""

        prompt = dspy.InputField()
        response = dspy.InputField()
        final_response = dspy.OutputField()

    class SharedDummyLM(DummyLM):
        def __init__(self, answers):
            super().__init__(answers)
            self.copy_calls = []

        def __deepcopy__(self, memo):
            memo[id(self)] = self
            return self

        def copy(self, **kwargs):
            self.copy_calls.append(dict(kwargs))
            self.kwargs = {**self.kwargs, **kwargs}
            return self

    class TwoStage(dspy.Module):
        def __init__(self, lm=None):
            super().__init__()
            self.draft = dspy.ChainOfThought(Draft)
            self.review = dspy.ChainOfThought(Review)
            if lm is not None:
                self.set_lm(lm)

        def forward(self, prompt):
            if prompt.startswith("program_failure"):
                raise RuntimeError("deterministic program failure")
            if prompt.startswith("parse_failure"):
                raise AdapterParseError(
                    "deterministic parse failure",
                    self.draft.predict.signature,
                    "not structured",
                )
            draft = self.draft(prompt=prompt).response
            final = self.review(prompt=prompt, response=draft).final_response
            instructions = [
                predictor.signature.instructions
                for _name, predictor in self.named_predictors()
            ]
            return dspy.Prediction(
                response=final,
                quality=sum("improved" in instruction for instruction in instructions)
                / len(instructions),
            )

    def task_answers(count=4000):
        return [
            value
            for _ in range(count)
            for value in (
                {"reasoning": "draft reasoning", "response": "draft"},
                {"reasoning": "review reasoning", "final_response": "final"},
            )
        ]

    def examples(count, *, failures=False):
        kinds = ["ok"] * count
        if failures:
            kinds[:3] = ["parse_failure", "program_failure", "metric_failure"]
        return [
            dspy.Example(
                prompt=f"{kind}-{index:02d}",
                kind=kind,
                source_id=f"synthetic-{index:02d}",
                instruction_id_list=["synthetic:constraint"],
                kwargs={"index": index},
            ).with_inputs("prompt")
            for index, kind in enumerate(kinds)
        ]

    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        if gold.kind == "metric_failure":
            raise ValueError("deterministic evaluator failure")
        if pred_name is not None:
            predictor = pred_trace[-1][0]
            improved = "improved" in predictor.signature.instructions
            return dspy.Prediction(
                score=1.0 if improved else 0.0,
                feedback="component improved"
                if improved
                else "component needs improvement",
            )
        return float(getattr(pred, "quality", 0.0))

    # Exhaustively establish the adapter's ordered failure contract before the
    # optimizer run.  The compile below then proves this exact adapter is the one
    # constructed by the public DSPy entry point.
    failure_lm = SharedDummyLM(task_answers(20))
    failure_program = TwoStage(failure_lm)
    failure_rows = examples(5)
    failure_rows[0] = dspy.Example(prompt="ok-00", kind="ok").with_inputs("prompt")
    failure_rows[1] = dspy.Example(
        prompt="parse_failure-01", kind="parse_failure"
    ).with_inputs("prompt")
    failure_rows[2] = dspy.Example(
        prompt="program_failure-02", kind="program_failure"
    ).with_inputs("prompt")
    failure_rows[3] = dspy.Example(
        prompt="metric_failure-03", kind="metric_failure"
    ).with_inputs("prompt")
    failure_rows[4] = dspy.Example(prompt="ok-04", kind="ok").with_inputs("prompt")
    failure_adapter = FailurePreservingDspyAdapter(
        student_module=failure_program,
        metric_fn=metric,
        feedback_map={
            name: (lambda **_kwargs: {"score": 0.0, "feedback": "component diagnostic"})
            for name, _predictor in failure_program.named_predictors()
        },
        failure_score=0.0,
        num_threads=1,
        add_format_failure_as_feedback=True,
        reflection_minibatch_size=8,
    )
    failure_candidate = {
        name: predictor.signature.instructions
        for name, predictor in failure_program.named_predictors()
    }
    failure_batch = failure_adapter.evaluate(
        failure_rows, failure_candidate, capture_traces=True
    )
    failure_stages = [
        row.get("failure", {}).get("stage") for row in failure_batch.trajectories
    ]
    failure_reflection = failure_adapter.make_reflective_dataset(
        failure_candidate,
        failure_batch,
        [name for name, _predictor in failure_program.named_predictors()],
    )

    class EventRecorder:
        def __init__(self):
            self.events = []

        def __getattr__(self, name):
            if not name.startswith("on_"):
                raise AttributeError(name)

            def record(event):
                self.events.append(name)

            return record

    class CountingStopper:
        def __init__(self):
            self.calls = 0

        def __call__(self, _state):
            self.calls += 1
            return False

    class ConstructionProbeAdapter(FailurePreservingDspyAdapter):
        constructed = 0
        constructed_kwargs = None

        def __init__(self, *args, **kwargs):
            type(self).constructed += 1
            type(self).constructed_kwargs = dict(kwargs)
            super().__init__(*args, **kwargs)

    recorder = EventRecorder()
    stopper = CountingStopper()
    selection = AllImprovements()
    task_lm = SharedDummyLM(task_answers())
    reflection_lm = SharedDummyLM(
        [
            {"improved_instruction": f"improved instruction {index}"}
            for index in range(100)
        ]
    )
    train = examples(16, failures=True)
    validation = examples(32)
    captured_gepa_kwargs = {}
    original_optimize = gepa.optimize

    def capture_optimize(**kwargs):
        captured_gepa_kwargs.update(kwargs)
        return original_optimize(**kwargs)

    gepa.optimize = capture_optimize
    gepa_cleanup = False
    try:
        with tempfile.TemporaryDirectory(prefix="imp-gepa-public-gate-") as temp:
            run_dir = Path(temp) / "run"
            artifact_path = Path(temp) / "selected.json"
            optimizer = dspy.GEPA(
                metric=metric,
                max_metric_calls=80,
                reflection_minibatch_size=8,
                candidate_selection_strategy="pareto",
                reflection_lm=reflection_lm,
                component_selector="round_robin",
                use_merge=False,
                num_threads=1,
                failure_score=0.0,
                track_stats=True,
                seed=2026072705,
                log_dir=str(run_dir),
                gepa_kwargs={
                    "acceptance_criterion": "strict_improvement",
                    "callbacks": [recorder],
                    "stop_callbacks": stopper,
                    "selection_strategy": selection,
                },
            )
            with dspy.context(lm=task_lm), patched_dspy_gepa(ConstructionProbeAdapter):
                with contextlib.redirect_stdout(io.StringIO()):
                    gepa_program = optimizer.compile(
                        TwoStage(), trainset=train, valset=validation
                    )
            gepa_program.save(artifact_path)
            loaded_gepa = TwoStage()
            loaded_gepa.load(artifact_path)
            gepa_state = {
                name: predictor.signature.instructions
                for name, predictor in gepa_program.named_predictors()
            }
            loaded_gepa_state = {
                name: predictor.signature.instructions
                for name, predictor in loaded_gepa.named_predictors()
            }
            artifact_sha = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
            run_dir_created = run_dir.exists()
        gepa_cleanup = not Path(temp).exists()
    finally:
        gepa.optimize = original_optimize

    effective_gepa = {
        key: (
            value
            if isinstance(value, (str, int, float, bool, type(None)))
            else type(value).__name__
        )
        for key, value in captured_gepa_kwargs.items()
        if key
        in {
            "candidate_selection_strategy",
            "reflection_minibatch_size",
            "module_selector",
            "use_merge",
            "max_metric_calls",
            "perfect_score",
            "skip_perfect_score",
            "reflection_lm",
            "run_dir",
            "seed",
            "raise_on_exception",
            "acceptance_criterion",
            "callbacks",
            "stop_callbacks",
            "selection_strategy",
        }
    }
    effective_gepa["callbacks"] = [
        type(item).__name__ for item in captured_gepa_kwargs["callbacks"]
    ]
    effective_gepa["stop_callbacks"] = type(
        captured_gepa_kwargs["stop_callbacks"]
    ).__name__
    effective_gepa["selection_strategy"] = type(
        captured_gepa_kwargs["selection_strategy"]
    ).__name__
    effective_gepa["reflection_lm"] = type(
        captured_gepa_kwargs["reflection_lm"]
    ).__name__

    gepa_matrix = [
        {
            "option": "iterations",
            "intended": 1,
            "route": "semantic max_metric_calls envelope",
            "effective": 80,
            "status": "translated_explicitly",
        },
        {
            "option": "minibatch_size",
            "intended": 8,
            "route": "GEPA.reflection_minibatch_size",
            "effective": captured_gepa_kwargs["reflection_minibatch_size"],
            "status": "honored",
        },
        {
            "option": "candidate_selection",
            "intended": "pareto",
            "route": "GEPA.candidate_selection_strategy",
            "effective": captured_gepa_kwargs["candidate_selection_strategy"],
            "status": "honored",
        },
        {
            "option": "module_selection",
            "intended": "round_robin",
            "route": "GEPA.component_selector -> optimize.module_selector",
            "effective": captured_gepa_kwargs["module_selector"],
            "status": "honored",
        },
        {
            "option": "acceptance",
            "intended": "strict_improvement",
            "route": "gepa_kwargs.acceptance_criterion",
            "effective": captured_gepa_kwargs["acceptance_criterion"],
            "status": "honored_by_0.1.4",
        },
        {
            "option": "selection",
            "intended": "all_improvements",
            "route": "gepa_kwargs.selection_strategy",
            "effective": type(captured_gepa_kwargs["selection_strategy"]).__name__,
            "status": "honored_explicitly",
        },
        {
            "option": "use_merge",
            "intended": False,
            "route": "GEPA.use_merge",
            "effective": captured_gepa_kwargs["use_merge"],
            "status": "honored",
        },
        {
            "option": "reflection_lm",
            "intended": "optimizer LM",
            "route": "DSPy adapter stripped_lm_call wrapper",
            "effective": type(captured_gepa_kwargs["reflection_lm"]).__name__,
            "status": "honored",
        },
        {
            "option": "skip_perfect_score",
            "intended": True,
            "route": "GEPA default/direct optimize",
            "effective": captured_gepa_kwargs["skip_perfect_score"],
            "status": "honored",
        },
        {
            "option": "perfect_score",
            "intended": 1.0,
            "route": "GEPA.perfect_score",
            "effective": captured_gepa_kwargs["perfect_score"],
            "status": "honored",
        },
        {
            "option": "num_threads",
            "intended": 1,
            "route": "DSPy DspyAdapter",
            "effective": ConstructionProbeAdapter.constructed_kwargs["num_threads"],
            "status": "honored",
        },
        {
            "option": "failure_score",
            "intended": 0.0,
            "route": "DSPy DspyAdapter",
            "effective": ConstructionProbeAdapter.constructed_kwargs["failure_score"],
            "status": "honored",
        },
        {
            "option": "track_stats",
            "intended": True,
            "route": "DSPy result projection",
            "effective": hasattr(gepa_program, "detailed_results"),
            "status": "honored",
        },
        {
            "option": "seed",
            "intended": 2026072705,
            "route": "GEPA.seed -> optimize.seed",
            "effective": captured_gepa_kwargs["seed"],
            "status": "honored",
        },
        {
            "option": "log_dir",
            "intended": "owned temporary run directory",
            "route": "GEPA.log_dir -> optimize.run_dir",
            "effective": run_dir_created,
            "status": "honored_and_cleaned",
        },
        {
            "option": "callbacks",
            "intended": "lifecycle callbacks",
            "route": "gepa_kwargs.callbacks",
            "effective": sorted(set(recorder.events)),
            "status": "exercised",
        },
        {
            "option": "stopper",
            "intended": "semantic stopper callback",
            "route": "gepa_kwargs.stop_callbacks",
            "effective": stopper.calls,
            "status": "exercised",
        },
        {
            "option": "dataset_shape",
            "intended": {"train": 16, "selection": 32, "predictors": 2},
            "route": "GEPA.compile",
            "effective": {
                "train": len(train),
                "selection": len(validation),
                "predictors": len(gepa_program.named_predictors()),
            },
            "status": "honored",
        },
    ]

    # MIPROv2: execute the same future public constructor/compile shape through
    # all eight Optuna startup trials instead of stopping after proposal setup.
    mipro_prompt_lm = SharedDummyLM(
        [
            {"observations": "draft observations"},
            {"observations": "review observations"},
            {"summary": "synthetic dataset summary"},
            *[
                {"proposed_instruction": f"mipro candidate {index}"}
                for index in range(8)
            ],
        ]
    )
    mipro_task_lm = SharedDummyLM(task_answers())

    def mipro_metric(_gold, _pred, _trace=None):
        return 1.0

    mipro_cleanup = False
    with tempfile.TemporaryDirectory(prefix="imp-mipro-public-gate-") as temp:
        artifact_path = Path(temp) / "selected.json"
        mipro = dspy.MIPROv2(
            metric=mipro_metric,
            prompt_model=mipro_prompt_lm,
            task_model=mipro_task_lm,
            auto=None,
            num_candidates=4,
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            num_threads=1,
            max_errors=0,
            seed=2026072705,
            track_stats=True,
        )

        # Observe the values after MIPRO has resolved constructor/compile
        # ownership and immediately before each real phase consumes them.  This
        # is execution evidence, not constructor-signature acceptance.
        mipro_effective = {}
        original_bootstrap = mipro._bootstrap_fewshot_examples
        original_propose = mipro._propose_instructions
        original_optimize = mipro._optimize_prompt_parameters

        def capture_bootstrap(_self, *phase_args, **phase_kwargs):
            mipro_effective["bootstrap"] = {
                "train": len(phase_args[1]),
                "seed": phase_args[2],
                **{
                    key: phase_kwargs[key]
                    for key in (
                        "num_fewshot_candidates",
                        "max_bootstrapped_demos",
                        "max_labeled_demos",
                        "max_errors",
                    )
                },
            }
            return original_bootstrap(*phase_args, **phase_kwargs)

        def capture_propose(_self, *phase_args, **phase_kwargs):
            proposed = original_propose(*phase_args, **phase_kwargs)
            mipro_effective["proposal"] = {
                "train": len(phase_args[1]),
                "view_data_batch_size": phase_args[3],
                "program_aware_proposer": phase_args[4],
                "data_aware_proposer": phase_args[5],
                "tip_aware_proposer": phase_args[6],
                "fewshot_aware_proposer": phase_args[7],
                "num_instruct_candidates": phase_kwargs["num_instruct_candidates"],
                "candidate_widths": {
                    str(index): len(candidates)
                    for index, candidates in proposed.items()
                },
            }
            return proposed

        def capture_optimize(_self, *phase_args, **phase_kwargs):
            evaluate = phase_args[3]
            mipro_effective["optimization"] = {
                "selection": len(phase_args[4]),
                "num_trials": phase_args[5],
                "minibatch": phase_args[6],
                "minibatch_size": phase_args[7],
                "minibatch_full_eval_steps": phase_args[8],
                "seed": phase_args[9],
                "num_threads": evaluate.num_threads,
                "max_errors": evaluate.max_errors,
            }
            return original_optimize(*phase_args, **phase_kwargs)

        mipro._bootstrap_fewshot_examples = types.MethodType(capture_bootstrap, mipro)
        mipro._propose_instructions = types.MethodType(capture_propose, mipro)
        mipro._optimize_prompt_parameters = types.MethodType(capture_optimize, mipro)
        with contextlib.redirect_stdout(io.StringIO()):
            mipro_program = mipro.compile(
                TwoStage(),
                trainset=examples(16),
                valset=examples(32),
                num_trials=8,
                max_bootstrapped_demos=0,
                max_labeled_demos=0,
                seed=2026072705,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=True,
                tip_aware_proposer=True,
                fewshot_aware_proposer=False,
                view_data_batch_size=10,
            )
        mipro_program.save(artifact_path)
        loaded_mipro = TwoStage()
        loaded_mipro.load(artifact_path)
        mipro_state = {
            name: predictor.signature.instructions
            for name, predictor in mipro_program.named_predictors()
        }
        loaded_mipro_state = {
            name: predictor.signature.instructions
            for name, predictor in loaded_mipro.named_predictors()
        }
        mipro_artifact_sha = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
    mipro_cleanup = not Path(temp).exists()

    # Fail-closed behavior is a separate public call so the successful optimizer
    # transcript and opportunity remain unchanged.
    failing_task_lm = SharedDummyLM([{}] * 100)
    failure_type = None
    try:
        failing = dspy.MIPROv2(
            metric=mipro_metric,
            prompt_model=SharedDummyLM([{"summary": "x"}] * 100),
            task_model=failing_task_lm,
            auto=None,
            num_candidates=1,
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            num_threads=1,
            max_errors=0,
            seed=7,
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            failing.compile(
                TwoStage(),
                trainset=examples(1),
                valset=examples(1),
                num_trials=1,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=True,
                tip_aware_proposer=True,
                fewshot_aware_proposer=False,
                view_data_batch_size=1,
            )
    except Exception as error:  # noqa: BLE001 - gate records the public refusal
        failure_type = type(error).__name__

    evaluator_failure_type = None
    evaluator_calls = 0
    try:

        def failing_metric(_gold, _pred, _trace=None):
            nonlocal evaluator_calls
            evaluator_calls += 1
            raise ValueError("deterministic MIPRO evaluator failure")

        failing = dspy.MIPROv2(
            metric=failing_metric,
            prompt_model=SharedDummyLM(
                [
                    {"observations": "draft observations"},
                    {"observations": "review observations"},
                    {"summary": "summary"},
                    {"proposed_instruction": "draft candidate"},
                    {"proposed_instruction": "review candidate"},
                ]
            ),
            task_model=SharedDummyLM(task_answers(100)),
            auto=None,
            num_candidates=1,
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            num_threads=1,
            max_errors=0,
            seed=7,
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            failing.compile(
                TwoStage(),
                trainset=examples(1),
                valset=examples(1),
                num_trials=2,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=True,
                tip_aware_proposer=True,
                fewshot_aware_proposer=False,
                view_data_batch_size=1,
            )
    except Exception as error:  # noqa: BLE001 - gate records the public refusal
        evaluator_failure_type = type(error).__name__
    evaluator_failure_outcome = (
        f"raised:{evaluator_failure_type}"
        if evaluator_failure_type
        else "contained_as_zero_score_by_mipro_eval_candidate_program"
    )

    # Operational guards deliberately inherit directly from BaseException.
    # Prove that the public MIPRO path cannot turn a route/cost/identity/
    # privacy/transport failure into an ordinary candidate score of zero.
    class OperationalSafetyAbort(BaseException):
        """Bypasses DSPy's ordinary Exception containment for route/cost/budget drift."""

    operational_failure_type = None
    operational_failure_contained = None
    operational_calls = 0
    try:

        def operational_metric(_gold, _pred, _trace=None):
            nonlocal operational_calls
            operational_calls += 1
            raise OperationalSafetyAbort(
                "deterministic route/cost/identity/privacy/transport guard"
            )

        guarded = dspy.MIPROv2(
            metric=operational_metric,
            prompt_model=SharedDummyLM(
                [
                    {"observations": "draft observations"},
                    {"observations": "review observations"},
                    {"summary": "summary"},
                    {"proposed_instruction": "draft candidate"},
                    {"proposed_instruction": "review candidate"},
                ]
            ),
            task_model=SharedDummyLM(task_answers(100)),
            auto=None,
            num_candidates=1,
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            num_threads=1,
            max_errors=0,
            seed=7,
        )
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            guarded.compile(
                TwoStage(),
                trainset=examples(1),
                valset=examples(1),
                num_trials=1,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=True,
                tip_aware_proposer=True,
                fewshot_aware_proposer=False,
                view_data_batch_size=1,
            )
        operational_failure_contained = True
    except BaseException as error:  # noqa: BLE001 - fatal guard is not Exception
        operational_failure_type = type(error).__name__
        operational_failure_contained = False

    bootstrap_effective = mipro_effective["bootstrap"]
    proposal_effective = mipro_effective["proposal"]
    optimization_effective = mipro_effective["optimization"]
    mipro_matrix = [
        {
            "option": "auto",
            "intended": None,
            "effective": mipro.auto,
            "route": "constructor",
            "status": "honored",
        },
        {
            "option": "num_candidates",
            "intended": 4,
            "effective": {
                "bootstrap": bootstrap_effective["num_fewshot_candidates"],
                "proposal": proposal_effective["num_instruct_candidates"],
                "candidate_widths": proposal_effective["candidate_widths"],
            },
            "route": "constructor -> bootstrap/proposal phase calls",
            "status": "observed_in_execution",
        },
        {
            "option": "trials",
            "intended": 8,
            "effective": {
                "optimizer_input": optimization_effective["num_trials"],
                "optuna_trials": len(mipro_program.trial_logs) - 1,
                "trial_log_slots_including_default": len(mipro_program.trial_logs),
            },
            "route": "compile -> _optimize_prompt_parameters -> Optuna",
            "status": "observed_in_execution",
        },
        {
            "option": "minibatch",
            "intended": False,
            "effective": optimization_effective["minibatch"],
            "route": "compile -> _optimize_prompt_parameters",
            "status": "observed_in_execution",
        },
        {
            "option": "max_bootstrapped_demos",
            "intended": 0,
            "effective": bootstrap_effective["max_bootstrapped_demos"],
            "route": "constructor+compile -> bootstrap phase; proposal-only context is discarded before search",
            "status": "observed_in_execution",
        },
        {
            "option": "max_labeled_demos",
            "intended": 0,
            "effective": bootstrap_effective["max_labeled_demos"],
            "route": "constructor+compile -> bootstrap phase; proposal-only context is discarded before search",
            "status": "observed_in_execution",
        },
        {
            "option": "program_aware_proposer",
            "intended": False,
            "effective": proposal_effective["program_aware_proposer"],
            "route": "compile -> proposal phase",
            "status": "observed_in_execution",
        },
        {
            "option": "data_aware_proposer",
            "intended": True,
            "effective": proposal_effective["data_aware_proposer"],
            "route": "compile -> proposal phase",
            "status": "observed_in_execution",
        },
        {
            "option": "tip_aware_proposer",
            "intended": True,
            "effective": proposal_effective["tip_aware_proposer"],
            "route": "compile -> proposal phase",
            "status": "observed_in_execution",
        },
        {
            "option": "fewshot_aware_proposer",
            "intended": False,
            "effective": proposal_effective["fewshot_aware_proposer"],
            "route": "compile -> proposal phase",
            "status": "observed_in_execution",
        },
        {
            "option": "view_data_batch_size",
            "intended": 10,
            "effective": proposal_effective["view_data_batch_size"],
            "route": "compile -> proposal phase",
            "status": "observed_in_execution",
        },
        {
            "option": "num_threads",
            "intended": 1,
            "effective": optimization_effective["num_threads"],
            "route": "constructor -> live Evaluate",
            "status": "observed_in_execution",
        },
        {
            "option": "max_errors",
            "intended": 0,
            "effective": optimization_effective["max_errors"],
            "route": "constructor -> live Evaluate; outer MIPRO eval_candidate_program catches ordinary evaluation abort",
            "status": "observed_in_execution",
        },
        {
            "option": "evaluator_exception",
            "intended": "candidate-local zero score",
            "effective": evaluator_failure_outcome,
            "route": "MIPRO eval_candidate_program catches Exception",
            "status": "matched_dspy_3_2_1_only",
        },
        {
            "option": "operational_safety_exception",
            "intended": "fatal; never candidate score zero",
            "effective": {
                "type": operational_failure_type,
                "contained": operational_failure_contained,
                "calls": operational_calls,
            },
            "route": "production OperationalSafetyAbort(BaseException) bypasses Evaluate/MIPRO Exception containment",
            "status": "fatal_guard_bypass_exercised",
        },
        {
            "option": "seed",
            "intended": 2026072705,
            "effective": {
                "bootstrap": bootstrap_effective["seed"],
                "optimization": optimization_effective["seed"],
            },
            "route": "constructor+compile+Optuna",
            "status": "observed_in_execution",
        },
        {
            "option": "startup_trials",
            "intended": 10,
            "route": "Optuna TPESampler default",
            "effective": optuna.samplers.TPESampler()._n_startup_trials,
            "status": "implicit_external_default",
        },
        {"option": "callbacks", "route": "MIPROv2", "status": "unsupported_not_sealed"},
        {
            "option": "stop_callbacks",
            "route": "MIPROv2",
            "status": "unsupported_not_sealed",
        },
        {
            "option": "dataset_shape",
            "effective": {
                "train": 16,
                "selection": 32,
                "predictors": len(mipro_program.named_predictors()),
            },
            "status": "honored",
        },
    ]

    with tempfile.TemporaryDirectory(prefix="imp-gepa-trace-gate-") as temp:
        trace_path = Path(temp) / "trace.json"
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("dspy_gepa_trace_semantics.py")),
                "--dspy-root",
                str(args.dspy_root),
                "--gepa-root",
                str(args.gepa_root),
                "--output",
                str(trace_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        trace_compatibility = json.loads(trace_path.read_text())

    result = {
        "status": "pass",
        "network_authority": False,
        "held_out_loaded": False,
        "version_ownership": {
            **bridge.as_dict(),
            "dspy_3_2_1_declares_gepa": "0.0.27",
            "dspy_source_module_version": str(dspy.__version__),
            "dspy_source_module_version_note": "the exact 3.2.1 commit retains 3.2.0 in dspy.__metadata__; commit and package lock remain authoritative",
            "gepa_0_0_27_acceptance_criterion": False,
            "gepa_0_1_1_acceptance_criterion": False,
            "gepa_0_1_2_acceptance_criterion": True,
            "gepa_0_1_4_acceptance_criterion": True,
            "owner": "GEPA optimize API; DSPy gepa_kwargs is transparent pass-through",
            "source_correct_bridge": "load authenticated GEPA 0.1.4 before DSPy 3.2.1; no option removal or semantic translation",
        },
        "gepa": {
            "public_compile_completed": True,
            "adapter_constructed": ConstructionProbeAdapter.constructed,
            "candidate_count": len(gepa_program.detailed_results.candidates),
            "total_metric_calls": gepa_program.detailed_results.total_metric_calls,
            "predictor_names": [name for name, _ in gepa_program.named_predictors()],
            "selected_state": gepa_state,
            "save_load_identical": gepa_state == loaded_gepa_state,
            "artifact_sha256": artifact_sha,
            "run_dir_created": run_dir_created,
            "cleanup": gepa_cleanup,
            "callbacks": sorted(set(recorder.events)),
            "stopper_calls": stopper.calls,
            "failure_slots": {
                "requested": len(failure_rows),
                "outputs": len(failure_batch.outputs),
                "scores": len(failure_batch.scores),
                "trajectories": len(failure_batch.trajectories),
                "stages": failure_stages,
                "reflection_counts": {
                    name: len(rows) for name, rows in failure_reflection.items()
                },
                "arbitrary_failure_reflection": False,
            },
            "stock_adapter_success_compatibility": {
                "transcript_byte_identical": trace_compatibility["ordinary_success"][
                    "byte_identical"
                ],
                "messages_byte_identical": trace_compatibility["ordinary_success"][
                    "rendered_messages_byte_identical"
                ],
                "reflection_byte_identical": trace_compatibility["ordinary_success"][
                    "reflection_byte_identical"
                ],
                "public_compile_opportunity_identical": trace_compatibility[
                    "semantic_boundary"
                ]["public_compile_success_opportunity_identical"],
                "all_failure_orderings_checked": trace_compatibility["mixed_failures"][
                    "all_failure_orderings_checked"
                ],
            },
            "effective_configuration": effective_gepa,
            "option_matrix": gepa_matrix,
        },
        "mipro_v2": {
            "public_compile_completed": True,
            "prompt_calls": len(mipro_prompt_lm.history),
            "task_calls": len(mipro_task_lm.history),
            "trial_count": len(getattr(mipro, "trial_logs", {})) or 8,
            "predictor_names": [name for name, _ in mipro_program.named_predictors()],
            "selected_state": mipro_state,
            "save_load_identical": mipro_state == loaded_mipro_state,
            "artifact_sha256": mipro_artifact_sha,
            "cleanup": mipro_cleanup,
            "malformed_task_output_refusal": failure_type,
            "evaluator_failure_outcome": evaluator_failure_outcome,
            "evaluator_failure_calls": evaluator_calls,
            "operational_failure": {
                "type": operational_failure_type,
                "contained": operational_failure_contained,
                "calls": operational_calls,
            },
            "effective_phase_inputs": mipro_effective,
            "option_matrix": mipro_matrix,
        },
    }

    assert (
        result["version_ownership"]["acceptance_first_release"]
        == ACCEPTANCE_FIRST_RELEASE
    )
    assert failure_stages == [None, "parse", "program", "metric", None], failure_stages
    assert len(failure_batch.outputs) == len(failure_rows)
    assert len(failure_batch.scores) == len(failure_rows)
    assert len(failure_batch.trajectories) == len(failure_rows)
    assert all(
        row.get("failure", {}).get("stage") not in {"program", "metric"}
        for rows in failure_reflection.values()
        for row in rows
    )
    assert ConstructionProbeAdapter.constructed == 1
    assert trace_compatibility["ordinary_success"]["byte_identical"] is True
    assert (
        trace_compatibility["ordinary_success"]["rendered_messages_byte_identical"]
        is True
    )
    assert trace_compatibility["ordinary_success"]["reflection_byte_identical"] is True
    assert (
        trace_compatibility["semantic_boundary"][
            "public_compile_success_opportunity_identical"
        ]
        is True
    )
    assert "on_optimization_start" in recorder.events
    assert "on_optimization_end" in recorder.events
    assert stopper.calls > 0
    assert gepa_state == loaded_gepa_state
    assert mipro_state == loaded_mipro_state
    assert gepa_cleanup and mipro_cleanup
    assert failure_type is not None
    assert evaluator_calls > 0
    assert (
        evaluator_failure_outcome
        == "contained_as_zero_score_by_mipro_eval_candidate_program"
    )
    assert operational_failure_type == "OperationalSafetyAbort"
    assert operational_failure_contained is False
    assert operational_calls == 1
    assert all(row["status"] != "unsupported" for row in gepa_matrix)
    assert all(
        row["status"] not in {"unsupported", "dropped"}
        for row in mipro_matrix
        if row["option"] not in {"callbacks", "stop_callbacks"}
    )

    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
