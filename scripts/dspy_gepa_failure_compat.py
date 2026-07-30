"""Failure-preserving DSPy 3.2.1 GEPA compatibility layer.

DSPy's trace bootstrap currently loses rows when ``Evaluate`` catches a
program or metric exception. GEPA v0.1.4 requires one ordered output and score
for every requested example. This module repairs that adapter boundary without
turning arbitrary exceptions into reflection advice. DSPy's existing
``add_format_failure_as_feedback`` parse-error behavior remains unchanged.

The layer is deliberately explicit and scoped. ``patched_dspy_gepa`` changes
the adapter class referenced by one stock ``dspy.GEPA.compile`` call and
restores it afterwards; it does not patch an installed checkout on disk.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, replace
import logging
from types import MethodType
from typing import Any, Iterator

import dspy
from dspy.evaluate.evaluate import Evaluate
from dspy.teleprompt.bootstrap_trace import FailedPrediction
from dspy.teleprompt.gepa.gepa_utils import DspyAdapter
from dspy.utils.exceptions import AdapterParseError
from gepa import EvaluationBatch


@dataclass(frozen=True)
class FailedExecution:
    """Diagnostic output occupying the ordered slot of a failed program call."""

    stage: str
    error_type: str
    message: str

    @property
    def failure(self) -> dict[str, str]:
        return {
            "stage": self.stage,
            "type": self.error_type,
            "message": self.message,
        }


class FailureScore(float):
    """Numeric failure score carrying diagnostic metric-error evidence."""

    failure: dict[str, str]

    def __new__(cls, value: float, failure: dict[str, str]):
        instance = super().__new__(cls, value)
        instance.failure = failure
        return instance


def failure_evidence(stage: str, error: BaseException) -> dict[str, str]:
    return {
        "stage": stage,
        "type": type(error).__name__,
        "message": str(error),
    }


def bootstrap_trace_data(
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
    """Source-shaped bootstrap with failure-preserving ordered cardinality.

    Successful execution follows DSPy 3.2.1's implementation. Parse failures
    retain ``FailedPrediction`` and its format reward. Other program and metric
    failures receive the caller's failure score and structured diagnostics.
    """

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
            return prediction.format_reward or format_failure_score
        if isinstance(prediction, FailedExecution):
            return failure_score
        try:
            return metric(example, prediction, trace) if metric else True
        except Exception as error:  # noqa: BLE001 - diagnostic boundary
            return FailureScore(failure_score, failure_evidence("metric", error))

    original_forward = object.__getattribute__(program, "forward")

    def patched_forward(program_to_use, **kwargs):
        with dspy.context(trace=[]):
            try:
                return original_forward(**kwargs), dspy.settings.trace.copy()
            except AdapterParseError as error:
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
                failed_prediction.failure = failure_evidence("parse", error)
                captured = dspy.settings.trace.copy()
                captured.append((predictor, kwargs, failed_prediction))
                if log_format_failures:
                    logging.warning(
                        "Failed to parse output for example. This is likely due "
                        "to the LLM response not following the adapter's formatting."
                    )
                return failed_prediction, captured
            except Exception as error:  # noqa: BLE001 - diagnostic boundary
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
        failure = getattr(prediction, "failure", None) or getattr(
            score, "failure", None
        )
        if failure is not None and raise_on_error:
            raise RuntimeError(f"{failure['stage']} failure: {failure['message']}")

        row = {
            "example_ind": example_ind,
            "example": example,
            "prediction": prediction,
            "trace": captured,
        }
        if metric:
            row["score"] = float(score) if isinstance(score, FailureScore) else score
        if failure is not None:
            row["failure"] = failure
        traces.append(row)

    return traces


class FailurePreservingDspyAdapter(DspyAdapter):
    """Stock DSPy GEPA adapter with only the failed-trace boundary repaired."""

    def evaluate(self, batch, candidate, capture_traces=False):
        if not capture_traces:
            return super().evaluate(batch, candidate, capture_traces=False)

        program = self.build_program(candidate)
        callback_metadata = (
            {"metric_key": "eval_full"}
            if self.reflection_minibatch_size is None
            or len(batch) > self.reflection_minibatch_size
            else {"disable_logging": True}
        )
        trajectories = bootstrap_trace_data(
            program=program,
            dataset=batch,
            metric=self.metric_fn,
            num_threads=self.num_threads,
            raise_on_error=False,
            capture_failed_parses=True,
            failure_score=self.failure_score,
            format_failure_score=self.failure_score,
            callback_metadata=callback_metadata,
        )
        outputs = [row["prediction"] for row in trajectories]
        scores = []
        for row in trajectories:
            score = row.get("score")
            if score is None:
                scores.append(self.failure_score)
            elif hasattr(score, "score"):
                scores.append(score["score"])
            else:
                scores.append(score)
        return EvaluationBatch(
            outputs=outputs,
            scores=scores,
            trajectories=trajectories,
        )

    def make_reflective_dataset(self, candidate, eval_batch, components_to_update):
        # Parse failures keep stock DSPy's existing explicit opt-in. Arbitrary
        # program/metric failures stay in evaluation diagnostics only.
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


@contextmanager
def patched_dspy_gepa() -> Iterator[None]:
    """Scope the compatibility adapter to one stock DSPy GEPA compile."""

    from dspy.teleprompt.gepa import gepa as gepa_module

    original = gepa_module.DspyAdapter
    gepa_module.DspyAdapter = FailurePreservingDspyAdapter
    try:
        yield
    finally:
        gepa_module.DspyAdapter = original
