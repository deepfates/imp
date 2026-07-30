#!/usr/bin/env python3
"""Provider-free reproduction of DSPy/GEPA trace-batch cardinality loss.

This intentionally exercises the public ``dspy.GEPA`` adapter selected by
DSPy 3.2.1 and the private GEPA v0.1.4 merge point that raised in the stopped
matched treatment.  It never configures an LM or touches benchmark data.
"""

from __future__ import annotations

import argparse
import inspect
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    args = parser.parse_args()

    sys.path.insert(0, str(args.gepa_root.resolve() / "src"))
    sys.path.insert(0, str(args.dspy_root.resolve()))

    import dspy
    from dspy.teleprompt.gepa.gepa_utils import DspyAdapter
    from dspy.utils.exceptions import AdapterParseError
    from gepa.core.data_loader import ListDataLoader
    from gepa.core.engine import GEPAEngine
    from gepa.strategies.eval_policy import FullEvaluationPolicy

    class DeterministicFailureProgram(dspy.Module):
        def __init__(self) -> None:
            super().__init__()
            self.stage = dspy.Predict("kind -> answer")

        def forward(self, kind: str):
            if kind == "parse_empty":
                raise AdapterParseError(
                    "deterministic",
                    self.stage.signature,
                    "not structured",
                    parsed_result=None,
                )
            if kind == "parse_partial":
                raise AdapterParseError(
                    "deterministic",
                    self.stage.signature,
                    "partly structured",
                    parsed_result={"answer": "partial"},
                )
            return dspy.Prediction(answer="ok")

    def metric(example, prediction, trace=None):
        del prediction, trace
        if example.kind == "metric_failure":
            raise ValueError("deterministic evaluator failure")
        return 1.0

    batch = [
        dspy.Example(kind="ok").with_inputs("kind"),
        dspy.Example(kind="parse_empty").with_inputs("kind"),
        dspy.Example(kind="parse_partial").with_inputs("kind"),
        dspy.Example(kind="metric_failure").with_inputs("kind"),
    ]
    program = DeterministicFailureProgram()
    adapter = DspyAdapter(
        student_module=program,
        metric_fn=metric,
        feedback_map={"stage": lambda **_kwargs: {"score": 0.0, "feedback": "failed"}},
        failure_score=0.0,
        num_threads=1,
    )
    candidate = {
        name: predictor.signature.instructions
        for name, predictor in program.named_predictors()
    }

    ordinary = adapter.evaluate(batch, candidate, capture_traces=False)
    traced = adapter.evaluate(batch, candidate, capture_traces=True)
    retained_indices = [trace["example_ind"] for trace in (traced.trajectories or [])]

    engine = object.__new__(GEPAEngine)
    engine.adapter = adapter
    engine.valset = ListDataLoader(batch)
    engine.val_evaluation_policy = FullEvaluationPolicy()
    state = SimpleNamespace(evaluation_cache=None)
    engine_error = None
    try:
        engine._evaluate_programs_on_valset([candidate], state)
    except Exception as error:  # exact owning exception is part of the output
        engine_error = f"{type(error).__name__}: {error}"

    result: dict[str, Any] = {
        "requested": len(batch),
        "ordinary_evaluate": {
            "outputs": len(ordinary.outputs),
            "scores": len(ordinary.scores),
        },
        "trace_evaluate": {
            "outputs": len(traced.outputs),
            "scores": len(traced.scores),
            "example_indices": retained_indices,
            "dropped_failure_kinds": [
                example.kind
                for index, example in enumerate(batch)
                if index not in retained_indices
            ],
        },
        "engine_error": engine_error,
        "sources": {
            "dspy_adapter": inspect.getfile(DspyAdapter),
            "gepa_engine": inspect.getfile(GEPAEngine),
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))

    assert result["ordinary_evaluate"] == {"outputs": 4, "scores": 4}
    assert result["trace_evaluate"] == {
        "outputs": 2,
        "scores": 2,
        "example_indices": [0, 1],
        "dropped_failure_kinds": ["parse_partial", "metric_failure"],
    }
    assert engine_error == "IndexError: list index out of range"


if __name__ == "__main__":
    main()
