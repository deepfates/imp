#!/usr/bin/env python3
"""Capture DSPy 3.2.1 MIPRO's retained few-shot arms through public compile."""

import contextlib
import io
import json
import subprocess
import types
from pathlib import Path

import dspy
from dspy.teleprompt import MIPROv2
from dspy.utils.dummies import DummyLM


def metric(_example, _prediction, _trace=None):
    return True


def demo_json(demo):
    values = dict(demo)
    augmented = bool(values.pop("augmented", False))
    return {
        "values": values,
        "augmented": augmented,
    }


def main():
    task_lm = DummyLM([{"route": "K11"}] * 100)
    prompt_lm = DummyLM([{"proposed_instruction": f"candidate {index}"} for index in range(4)])
    program = dspy.Predict("text -> route")
    program.signature = program.signature.with_instructions("Route the request.")
    trainset = [
        dspy.Example(text=f"request-{index}", route="K11").with_inputs("text")
        for index in range(4)
    ]
    valset = [dspy.Example(text="validation", route="K11").with_inputs("text")]

    optimizer = MIPROv2(
        metric=metric,
        prompt_model=prompt_lm,
        task_model=task_lm,
        auto=None,
        num_candidates=4,
        max_bootstrapped_demos=2,
        max_labeled_demos=1,
        seed=9,
    )

    captured = {}

    def proposals(self, _program, _trainset, demo_candidates, *_args, **_kwargs):
        captured["demos"] = [
            [demo_json(demo) for demo in candidate] for candidate in demo_candidates[0]
        ]
        return {0: ["Route the request."] * 4}

    def stop(self, program, *_args, **_kwargs):
        return program

    optimizer._propose_instructions = types.MethodType(proposals, optimizer)
    optimizer._optimize_prompt_parameters = types.MethodType(stop, optimizer)

    with contextlib.redirect_stdout(io.StringIO()):
        optimizer.compile(
            program,
            trainset=trainset,
            valset=valset,
            num_trials=1,
            minibatch=False,
            program_aware_proposer=False,
            data_aware_proposer=True,
            tip_aware_proposer=True,
            fewshot_aware_proposer=False,
        )

    source_root = Path(dspy.__file__).resolve().parents[1]
    print(json.dumps({
        "commit": subprocess.check_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "demos": captured["demos"],
        "task_messages": [entry["messages"] for entry in task_lm.history],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
