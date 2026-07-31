#!/usr/bin/env python3
"""Capture pinned DSPy 3.2.1 zero-demo MIPRO bootstrap failure semantics."""

import contextlib
import io
import json
import subprocess
import types
from pathlib import Path

import dspy
from dspy.teleprompt import MIPROv2
from dspy.utils.dummies import DummyLM


class ProgramFailure(dspy.Module):
    def __init__(self):
        self.route = dspy.Predict("prompt -> response")

    def forward(self, prompt):
        raise ValueError(f"program failed for {prompt}")


def nested_example(index):
    return dspy.Example(
        prompt=f"request-{index:02d}",
        instruction_id_list=["format:quoted", "length:exact"],
        kwargs=[{
            "phrase": "can't say \"BLUE\"\nwithout\\escaping",
            "count": index,
            "enabled": index % 2 == 0,
            "missing": None,
            "ordered": {"z": [1, False, None], "a": {"line": "café\u2028end"}},
        }],
    ).with_inputs("prompt")


def run_case(kind):
    prompt_lm = DummyLM([{"proposed_instruction": "unused"}] * 20)

    if kind == "program":
        program = ProgramFailure()
        task_lm = DummyLM([{"response": "unused"}] * 20)

        def metric(_example, _prediction, _trace=None):
            return True
    elif kind == "parse":
        program = dspy.Predict("prompt -> response")
        task_lm = DummyLM([{}] * 20)

        def metric(_example, _prediction, _trace=None):
            return True
    elif kind == "metric":
        program = dspy.Predict("prompt -> response")
        task_lm = DummyLM([{"response": "ok"}] * 20)

        def metric(_example, _prediction, _trace=None):
            raise RuntimeError("metric failed deliberately")
    else:
        raise AssertionError(kind)

    optimizer = MIPROv2(
        metric=metric,
        prompt_model=prompt_lm,
        task_model=task_lm,
        auto=None,
        num_candidates=4,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        max_errors=0,
        seed=9,
    )

    try:
        with contextlib.redirect_stdout(io.StringIO()):
            optimizer.compile(
                program,
                trainset=[nested_example(index) for index in range(4)],
                valset=[nested_example(9)],
                num_trials=1,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=False,
                tip_aware_proposer=False,
                fewshot_aware_proposer=False,
            )
    except Exception as error:
        return {
            "exception_type": type(error).__name__,
            "message": str(error),
            "task_calls": len(task_lm.history),
            "prompt_calls": len(prompt_lm.history),
        }

    raise AssertionError(f"{kind} unexpectedly completed")


def run_default_budget(mode):
    metric_calls = 0

    def metric(_example, _prediction, _trace=None):
        nonlocal metric_calls
        metric_calls += 1
        if mode == "one_failure" and metric_calls == 1:
            raise RuntimeError("first metric failure")
        if mode == "exhausted":
            raise RuntimeError(f"metric failure {metric_calls}")
        return True

    prompt_lm = DummyLM([{"proposed_instruction": "unused"}] * 20)
    task_lm = DummyLM([{"response": "ok"}] * 100)
    program = dspy.Predict("prompt -> response")
    optimizer = MIPROv2(
        metric=metric,
        prompt_model=prompt_lm,
        task_model=task_lm,
        auto=None,
        num_candidates=4,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        seed=9,
    )
    captured = {}

    def proposals(self, _program, _trainset, demo_candidates, *_args, **_kwargs):
        captured["bootstrap_candidate_sets"] = len(demo_candidates[0])
        return {0: ["base", "candidate-1", "candidate-2", "candidate-3"]}

    def stop(self, program, _instructions, demo_candidates, *_args, **_kwargs):
        captured["demos_discarded"] = demo_candidates is None
        return program

    optimizer._propose_instructions = types.MethodType(proposals, optimizer)
    optimizer._optimize_prompt_parameters = types.MethodType(stop, optimizer)

    try:
        with contextlib.redirect_stdout(io.StringIO()):
            optimizer.compile(
                program,
                trainset=[nested_example(index) for index in range(16)],
                valset=[nested_example(99)],
                num_trials=1,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=True,
                tip_aware_proposer=True,
                fewshot_aware_proposer=False,
            )
    except Exception as error:
        return {
            "completed": False,
            "exception_type": type(error).__name__,
            "message": str(error),
            "metric_calls": metric_calls,
            "task_calls": len(task_lm.history),
            "prompt_calls": len(prompt_lm.history),
        }

    return {
        "completed": True,
        "metric_calls": metric_calls,
        "task_calls": len(task_lm.history),
        "prompt_calls": len(prompt_lm.history),
        **captured,
    }


def main():
    source_root = Path(dspy.__file__).resolve().parents[1]
    print(json.dumps({
        "commit": subprocess.check_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "default_max_errors": dspy.settings.max_errors,
        "default_budget": {
            mode: run_default_budget(mode) for mode in ("one_failure", "exhausted")
        },
        "failures": {kind: run_case(kind) for kind in ("program", "parse", "metric")},
    }, sort_keys=True))


if __name__ == "__main__":
    main()
