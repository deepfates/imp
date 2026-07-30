#!/usr/bin/env python3
"""Executable provider-free candidate semantics for failed DSPy GEPA traces.

The implementation is deliberately source-shaped: it exercises the public
DSPy ``DspyAdapter`` and changes only the trace bootstrap function it calls.
It is not installed into the pinned checkout and grants no provider authority.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import sys
from pathlib import Path
from types import SimpleNamespace


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    sys.path.insert(0, str(args.gepa_root.resolve() / "src"))
    sys.path.insert(0, str(args.dspy_root.resolve()))

    import dspy
    from dspy.teleprompt.bootstrap_trace import FailedPrediction
    from dspy.teleprompt.gepa.gepa_utils import DspyAdapter
    from dspy.utils.exceptions import AdapterParseError
    from gepa.core.data_loader import ListDataLoader
    from gepa.core.engine import GEPAEngine
    from gepa.strategies.eval_policy import FullEvaluationPolicy
    from dspy_gepa_failure_compat import (
        FailedExecution,
        FailurePreservingDspyAdapter,
        patched_dspy_gepa,
    )
    from dspy.teleprompt.gepa import gepa as dspy_gepa_module
    from dspy.teleprompt.gepa import gepa_utils as dspy_gepa_utils

    class Program(dspy.Module):
        def __init__(self, lm):
            super().__init__()
            self.stage = dspy.Predict("kind -> answer")
            self.set_lm(lm)

        def forward(self, kind):
            if kind == "program_failure":
                raise RuntimeError("deterministic program failure")
            if kind == "parse_empty":
                raise AdapterParseError(
                    "deterministic", self.stage.signature, "not structured"
                )
            if kind == "parse_partial":
                raise AdapterParseError(
                    "deterministic",
                    self.stage.signature,
                    "partly structured",
                    parsed_result={"answer": "partial"},
                )
            return self.stage(kind=kind)

    class SharedHistoryDummyLM(dspy.utils.DummyLM):
        def __deepcopy__(self, memo):
            # Each comparison arm owns its own LM. Within an arm, DSPy's program
            # deepcopy must retain the one history so rendered requests remain
            # observable rather than disappearing into an unreferenced LM copy.
            memo[id(self)] = self
            return self

    def metric(example, prediction, trace=None):
        del prediction, trace
        if example.kind == "metric_failure":
            raise ValueError("deterministic evaluator failure")
        return 1.0

    def adapter(adapter_class, rows, *, format_feedback=False, failure_score=0.0):
        lm = SharedHistoryDummyLM([{"answer": "ok"}] * len(rows))
        program = Program(lm)
        instance = adapter_class(
            student_module=program,
            metric_fn=metric,
            feedback_map={
                "stage": lambda **_kwargs: {
                    "score": 1.0,
                    "feedback": "ordinary success",
                }
            },
            failure_score=failure_score,
            num_threads=1,
            add_format_failure_as_feedback=format_feedback,
        )
        candidate = {
            name: predictor.signature.instructions
            for name, predictor in program.named_predictors()
        }
        return instance, candidate, lm

    def examples(kinds):
        return [dspy.Example(kind=kind).with_inputs("kind") for kind in kinds]

    def transcript_bytes(traces):
        def prediction_value(value):
            if isinstance(value, FailedPrediction):
                return {
                    "type": "FailedPrediction",
                    "completion_text": value.completion_text,
                    "format_reward": value.format_reward,
                }
            if isinstance(value, FailedExecution):
                return {
                    "type": "FailedExecution",
                    "stage": value.stage,
                    "error_type": value.error_type,
                    "message": value.message,
                }
            return {"type": type(value).__name__, "fields": dict(value)}

        normalized = []
        for row in traces:
            normalized.append(
                {
                    "example_ind": row["example_ind"],
                    "example": dict(row["example"]),
                    "prediction": prediction_value(row["prediction"]),
                    "score": row.get("score"),
                    "failure": row.get("failure"),
                    "trace": [
                        {
                            "signature": str(item[0].signature),
                            "inputs": item[1],
                            "prediction": prediction_value(item[2]),
                        }
                        for item in row["trace"]
                    ],
                }
            )
        return json.dumps(normalized, sort_keys=True, separators=(",", ":")).encode()

    success = examples(["ok_a", "ok_b"])
    original_adapter, original_candidate, original_lm = adapter(DspyAdapter, success)
    original = original_adapter.evaluate(success, original_candidate, capture_traces=True)
    fixed_adapter, fixed_candidate, fixed_lm = adapter(
        FailurePreservingDspyAdapter, success
    )
    fixed = fixed_adapter.evaluate(success, fixed_candidate, capture_traces=True)
    original_bytes = transcript_bytes(original.trajectories)
    fixed_bytes = transcript_bytes(fixed.trajectories)
    original_reflection = original_adapter.make_reflective_dataset(
        original_candidate, original, ["stage"]
    )
    fixed_reflection = fixed_adapter.make_reflective_dataset(
        fixed_candidate, fixed, ["stage"]
    )
    original_reflection_bytes = json.dumps(
        original_reflection, sort_keys=True, separators=(",", ":")
    ).encode()
    fixed_reflection_bytes = json.dumps(
        fixed_reflection, sort_keys=True, separators=(",", ":")
    ).encode()

    def history_bytes(lm):
        stable = [
            {
                key: value
                for key, value in row.items()
                if key not in ("timestamp", "uuid")
            }
            for row in lm.history
        ]
        return json.dumps(stable, sort_keys=True, separators=(",", ":")).encode()

    original_messages = history_bytes(original_lm)
    fixed_messages = history_bytes(fixed_lm)

    mixed = examples(
        ["ok", "parse_empty", "parse_partial", "program_failure", "metric_failure"]
    )
    mixed_adapter, mixed_candidate, _mixed_lm = adapter(
        FailurePreservingDspyAdapter, mixed, format_feedback=True
    )
    mixed_eval = mixed_adapter.evaluate(mixed, mixed_candidate, capture_traces=True)
    reflection = mixed_adapter.make_reflective_dataset(
        mixed_candidate, mixed_eval, ["stage"]
    )
    default_adapter, default_candidate, _default_lm = adapter(
        FailurePreservingDspyAdapter, mixed
    )
    default_eval = default_adapter.evaluate(mixed, default_candidate, capture_traces=True)
    default_reflection = default_adapter.make_reflective_dataset(
        default_candidate, default_eval, ["stage"]
    )

    engine = object.__new__(GEPAEngine)
    engine.adapter = mixed_adapter
    engine.valset = ListDataLoader(mixed)
    engine.val_evaluation_policy = FullEvaluationPolicy()
    merged = engine._evaluate_programs_on_valset(
        [mixed_candidate], SimpleNamespace(evaluation_cache=None)
    )[0][0]

    # Every ordering of all five outcomes must retain its own aligned slot.
    # One evaluation keeps the proof fast while covering all 120 permutations.
    outcome_kinds = [
        "ok",
        "parse_empty",
        "parse_partial",
        "program_failure",
        "metric_failure",
    ]
    permutations = list(itertools.permutations(outcome_kinds))
    exhaustive_kinds = [kind for permutation in permutations for kind in permutation]
    exhaustive_rows = examples(exhaustive_kinds)
    exhaustive_adapter, exhaustive_candidate, _exhaustive_lm = adapter(
        FailurePreservingDspyAdapter, exhaustive_rows, format_feedback=True
    )
    exhaustive = exhaustive_adapter.evaluate(
        exhaustive_rows, exhaustive_candidate, capture_traces=True
    )
    expected_stage = {
        "ok": None,
        "parse_empty": "parse",
        "parse_partial": "parse",
        "program_failure": "program",
        "metric_failure": "metric",
    }
    for index, (kind, row, score) in enumerate(
        zip(exhaustive_kinds, exhaustive.trajectories, exhaustive.scores, strict=True)
    ):
        assert row["example_ind"] == index
        assert row.get("failure", {}).get("stage") == expected_stage[kind], (
            index,
            kind,
            row.get("failure"),
        )
        assert score == (1.0 if kind == "ok" else 0.0)

    configured_rows = examples(["program_failure", "metric_failure"])
    configured_adapter, configured_candidate, _configured_lm = adapter(
        FailurePreservingDspyAdapter, configured_rows, failure_score=-0.25
    )
    configured = configured_adapter.evaluate(
        configured_rows, configured_candidate, capture_traces=True
    )

    stock_adapter_class = dspy_gepa_module.DspyAdapter
    stock_utils_adapter_class = dspy_gepa_utils.DspyAdapter
    with patched_dspy_gepa():
        scoped_adapter_installed = (
            dspy_gepa_module.DspyAdapter is FailurePreservingDspyAdapter
            and dspy_gepa_utils.DspyAdapter is FailurePreservingDspyAdapter
        )
    scoped_adapter_restored = (
        dspy_gepa_module.DspyAdapter is stock_adapter_class
        and dspy_gepa_utils.DspyAdapter is stock_utils_adapter_class
    )

    class ConstructionProbeAdapter(FailurePreservingDspyAdapter):
        constructed = 0

        def __init__(self, *args, **kwargs):
            type(self).constructed += 1
            super().__init__(*args, **kwargs)

    def compile_success(adapter_class=None):
        lm = SharedHistoryDummyLM([{"answer": "ok"}] * 100)
        rows = examples(["compile_a", "compile_b", "compile_c", "compile_d"])
        proposal_calls = []

        def compile_metric(_gold, _pred, _trace=None, pred_name=None, _pred_trace=None):
            if pred_name is not None:
                return dspy.Prediction(score=0.5, feedback="stable success")
            return 0.5

        def proposer(candidate, reflective_dataset, components_to_update):
            proposal_calls.append(
                {
                    "components": list(components_to_update),
                    "record_counts": {
                        name: len(reflective_dataset[name])
                        for name in components_to_update
                    },
                }
            )
            return {
                name: candidate[name] + " next" for name in components_to_update
            }

        optimizer = dspy.GEPA(
            metric=compile_metric,
            max_metric_calls=16,
            reflection_minibatch_size=2,
            instruction_proposer=proposer,
            component_selector="round_robin",
            use_merge=False,
            num_threads=1,
            track_stats=True,
            seed=7,
            gepa_kwargs={"acceptance_criterion": "strict_improvement"},
        )
        program = Program(lm)
        if adapter_class is None:
            compiled = optimizer.compile(
                program, trainset=rows[:2], valset=rows[2:]
            )
        else:
            with patched_dspy_gepa(adapter_class):
                compiled = optimizer.compile(
                    program, trainset=rows[:2], valset=rows[2:]
                )
        detailed = compiled.detailed_results
        return {
            "messages_sha256": hashlib.sha256(history_bytes(lm)).hexdigest(),
            "message_calls": len(lm.history),
            "metric_calls": detailed.total_metric_calls,
            "candidate_count": len(detailed.candidates),
            "discovery_eval_counts": detailed.discovery_eval_counts,
            "proposal_calls": proposal_calls,
        }

    stock_compile = compile_success()
    fixed_compile = compile_success(ConstructionProbeAdapter)

    result = {
        "status": "pass",
        "ordinary_success": {
            "byte_identical": original_bytes == fixed_bytes,
            "original_sha256": hashlib.sha256(original_bytes).hexdigest(),
            "fixed_sha256": hashlib.sha256(fixed_bytes).hexdigest(),
            "rendered_messages_byte_identical": original_messages == fixed_messages,
            "reflection_byte_identical": original_reflection_bytes
            == fixed_reflection_bytes,
            "reflection_opportunities": len(fixed_reflection["stage"]),
            "original_messages_sha256": hashlib.sha256(original_messages).hexdigest(),
            "fixed_messages_sha256": hashlib.sha256(fixed_messages).hexdigest(),
        },
        "mixed_failures": {
            "requested": len(mixed),
            "outputs": len(mixed_eval.outputs),
            "scores": mixed_eval.scores,
            "trajectory_indices": [row["example_ind"] for row in mixed_eval.trajectories],
            "failure_stages": [
                row.get("failure", {}).get("stage") for row in mixed_eval.trajectories
            ],
            "failure_types": [
                row.get("failure", {}).get("type") for row in mixed_eval.trajectories
            ],
            "failures": [row.get("failure") for row in mixed_eval.trajectories],
            "candidate_score_sum": sum(mixed_eval.scores),
            "reflection_items": len(reflection["stage"]),
            "reflection_parse_failures": sum(
                "failed to parse" in str(item["Feedback"]).lower()
                for item in reflection["stage"]
            ),
            "default_reflection_items": len(default_reflection["stage"]),
            "default_reflection_parse_failures": sum(
                "failed to parse" in str(item["Feedback"]).lower()
                for item in default_reflection["stage"]
            ),
            "all_failure_orderings_checked": len(permutations),
            "configured_failure_scores": configured.scores,
        },
        "gepa_merge": {
            "outputs": len(merged.outputs_by_val_id),
            "scores": [merged.scores_by_val_id[index] for index in range(len(mixed))],
        },
        "semantic_boundary": {
            "candidate_failure_score": 0.0,
            "parse_failure_reflection": "existing add_format_failure_as_feedback opt-in",
            "program_or_metric_failure_reflection": "diagnostic only; no invented feedback",
            "adapted_program_required_to_reproduce": False,
            "scoped_adapter_installed": scoped_adapter_installed,
            "scoped_adapter_restored": scoped_adapter_restored,
            "public_compile_constructed_fixed_adapter": ConstructionProbeAdapter.constructed
            == 1,
            "public_compile_success_opportunity_identical": stock_compile
            == fixed_compile,
            "public_compile": fixed_compile,
        },
    }
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    else:
        print(encoded, end="")

    assert result["ordinary_success"]["byte_identical"] is True
    assert result["ordinary_success"]["rendered_messages_byte_identical"] is True
    assert result["ordinary_success"]["reflection_byte_identical"] is True
    assert result["semantic_boundary"]["scoped_adapter_installed"] is True
    assert result["semantic_boundary"]["scoped_adapter_restored"] is True
    assert result["semantic_boundary"]["public_compile_constructed_fixed_adapter"] is True
    assert result["semantic_boundary"]["public_compile_success_opportunity_identical"] is True
    failures = result["mixed_failures"]["failures"]
    assert failures[0] is None
    assert [failure["stage"] for failure in failures[1:]] == [
        "parse",
        "parse",
        "program",
        "metric",
    ]
    assert failures[3]["message"] == "deterministic program failure"
    assert failures[4]["message"] == "deterministic evaluator failure"

    assert {
        key: value
        for key, value in result["mixed_failures"].items()
        if key != "failures"
    } == {
        "requested": 5,
        "outputs": 5,
        "scores": [1.0, 0.0, 0.0, 0.0, 0.0],
        "trajectory_indices": [0, 1, 2, 3, 4],
        "failure_stages": [None, "parse", "parse", "program", "metric"],
        "failure_types": [
            None,
            "AdapterParseError",
            "AdapterParseError",
            "RuntimeError",
            "ValueError",
        ],
        "candidate_score_sum": 1.0,
        "reflection_items": 3,
        "reflection_parse_failures": 2,
        "default_reflection_items": 1,
        "default_reflection_parse_failures": 0,
        "all_failure_orderings_checked": 120,
        "configured_failure_scores": [-0.25, -0.25],
    }
    assert result["gepa_merge"] == {
        "outputs": 5,
        "scores": [1.0, 0.0, 0.0, 0.0, 0.0],
    }


if __name__ == "__main__":
    main()
