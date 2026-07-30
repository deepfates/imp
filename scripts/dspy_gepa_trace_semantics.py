#!/usr/bin/env python3
"""Executable provider-free candidate semantics for failed DSPy GEPA traces.

The implementation is deliberately source-shaped: it exercises the public
DSPy ``DspyAdapter`` and changes only the trace bootstrap function it calls.
It is not installed into the pinned checkout and grants no provider authority.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from types import MethodType, SimpleNamespace
from unittest import mock


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    args = parser.parse_args()

    sys.path.insert(0, str(args.gepa_root.resolve() / "src"))
    sys.path.insert(0, str(args.dspy_root.resolve()))

    import dspy
    from dspy.evaluate.evaluate import Evaluate
    from dspy.teleprompt import bootstrap_trace as bootstrap_trace_module
    from dspy.teleprompt.bootstrap_trace import FailedPrediction
    from dspy.teleprompt.gepa.gepa_utils import DspyAdapter
    from dspy.utils.exceptions import AdapterParseError
    from gepa.core.data_loader import ListDataLoader
    from gepa.core.engine import GEPAEngine
    from gepa.strategies.eval_policy import FullEvaluationPolicy

    @dataclass
    class FailedExecution:
        stage: str
        error_type: str
        message: str

    class FailureScore(float):
        def __new__(cls, value, failure):
            instance = super().__new__(cls, value)
            instance.failure = failure
            return instance

    def failure(stage, error):
        return {
            "stage": stage,
            "type": type(error).__name__,
            "message": str(error),
        }

    def preserving_bootstrap_trace_data(
        program,
        dataset,
        metric=None,
        num_threads=None,
        raise_on_error=True,
        capture_failed_parses=False,
        failure_score=0,
        format_failure_score=-1,
        log_format_failures=False,
        callback_metadata=None,
    ):
        del log_format_failures
        evaluator = Evaluate(
            devset=dataset,
            num_threads=num_threads,
            display_progress=False,
            provide_traceback=False,
            max_errors=len(dataset) * 10,
            failure_score=failure_score,
        )

        def wrapped_metric(example, prediction_and_trace, trace=None):
            prediction, _captured = prediction_and_trace
            if isinstance(prediction, FailedPrediction):
                return (
                    prediction.format_reward
                    if prediction.format_reward is not None
                    else format_failure_score
                )
            if isinstance(prediction, FailedExecution):
                return failure_score
            try:
                return metric(example, prediction, trace) if metric else True
            except Exception as error:
                return FailureScore(failure_score, failure("metric", error))

        original_forward = object.__getattribute__(program, "forward")

        def patched_forward(program_to_use, **kwargs):
            with dspy.context(trace=[]):
                try:
                    return original_forward(**kwargs), dspy.settings.trace.copy()
                except AdapterParseError as error:
                    if not capture_failed_parses:
                        failed = FailedExecution(
                            "program", type(error).__name__, str(error)
                        )
                        return failed, dspy.settings.trace.copy()

                    present = list(error.parsed_result.keys()) if error.parsed_result else []
                    expected = list(error.signature.output_fields.keys())
                    predictor = next(
                        (
                            item
                            for item in program_to_use.predictors()
                            if item.signature == error.signature
                        ),
                        None,
                    )
                    if predictor is None:
                        failed = FailedExecution(
                            "program", "PredictorNotFound", str(error.signature)
                        )
                        return failed, dspy.settings.trace.copy()

                    ratio = len(present) / len(expected) if expected else 0.0
                    failed_prediction = FailedPrediction(
                        completion_text=error.lm_response,
                        format_reward=format_failure_score
                        + (failure_score - format_failure_score) * ratio,
                    )
                    failed_prediction.failure = failure("parse", error)
                    captured = dspy.settings.trace.copy()
                    captured.append((predictor, kwargs, failed_prediction))
                    return failed_prediction, captured
                except Exception as error:
                    return (
                        FailedExecution("program", type(error).__name__, str(error)),
                        dspy.settings.trace.copy(),
                    )

        program.forward = MethodType(patched_forward, program)
        try:
            results = evaluator(
                program,
                metric=wrapped_metric,
                callback_metadata=callback_metadata,
            ).results
        finally:
            program.forward = original_forward

        traces = []
        for example_ind, (example, prediction_and_trace, score) in enumerate(results):
            prediction, captured = prediction_and_trace
            failure_metadata = getattr(prediction, "failure", None) or getattr(
                score, "failure", None
            )
            if failure_metadata is not None and raise_on_error:
                raise RuntimeError(
                    f"{failure_metadata['stage']} failure: {failure_metadata['message']}"
                )
            row = {
                "example_ind": example_ind,
                "example": example,
                "prediction": prediction,
                "trace": captured,
            }
            if metric:
                row["score"] = float(score) if isinstance(score, FailureScore) else score
            if failure_metadata is not None:
                row["failure"] = failure_metadata
            traces.append(row)
        return traces

    class FailurePreservingDspyAdapter(DspyAdapter):
        def evaluate(self, batch, candidate, capture_traces=False):
            if not capture_traces:
                return super().evaluate(batch, candidate, capture_traces=False)
            with mock.patch.object(
                bootstrap_trace_module,
                "bootstrap_trace_data",
                preserving_bootstrap_trace_data,
            ):
                return super().evaluate(batch, candidate, capture_traces=True)

        def make_reflective_dataset(self, candidate, eval_batch, components_to_update):
            # Parse failures retain the existing documented, opt-in DSPy feedback
            # path. Infrastructure/program/metric failures remain visible in the
            # evaluation but are not turned into invented prompt advice.
            reflectable = [
                row
                for row in (eval_batch.trajectories or [])
                if row.get("failure", {}).get("stage") in (None, "parse")
            ]
            return super().make_reflective_dataset(
                candidate,
                replace(eval_batch, trajectories=reflectable),
                components_to_update,
            )

    class Program(dspy.Module):
        def __init__(self, lm):
            super().__init__()
            self.stage = dspy.Predict("kind -> answer")
            self.set_lm(lm)

        def forward(self, kind):
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

    def adapter(adapter_class, rows, *, format_feedback=False):
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
            failure_score=0.0,
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

    mixed = examples(["ok", "parse_empty", "parse_partial", "metric_failure"])
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

    result = {
        "ordinary_success": {
            "byte_identical": original_bytes == fixed_bytes,
            "original_sha256": hashlib.sha256(original_bytes).hexdigest(),
            "fixed_sha256": hashlib.sha256(fixed_bytes).hexdigest(),
            "rendered_messages_byte_identical": original_messages == fixed_messages,
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
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))

    assert result["ordinary_success"]["byte_identical"] is True
    assert result["ordinary_success"]["rendered_messages_byte_identical"] is True
    assert result["mixed_failures"] == {
        "requested": 4,
        "outputs": 4,
        "scores": [1.0, 0.0, 0.0, 0.0],
        "trajectory_indices": [0, 1, 2, 3],
        "failure_stages": [None, "parse", "parse", "metric"],
        "failure_types": [None, "AdapterParseError", "AdapterParseError", "ValueError"],
        "candidate_score_sum": 1.0,
        "reflection_items": 3,
        "reflection_parse_failures": 2,
        "default_reflection_items": 1,
        "default_reflection_parse_failures": 0,
    }
    assert result["gepa_merge"] == {
        "outputs": 4,
        "scores": [1.0, 0.0, 0.0, 0.0],
    }


if __name__ == "__main__":
    main()
