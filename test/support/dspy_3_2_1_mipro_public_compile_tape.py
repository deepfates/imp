#!/usr/bin/env python3
"""Capture pinned DSPy 3.2.1 public MIPRO setup through proposal."""

import json
import contextlib
import io
import random
import subprocess
import types
from pathlib import Path

import dspy
from dspy.teleprompt import MIPROv2
from dspy.utils.dummies import DummyLM


class CapturingLM(DummyLM):
    def __init__(self, answers):
        super().__init__(answers)
        self.copy_calls = []

    def copy(self, **kwargs):
        self.copy_calls.append(kwargs)
        self.kwargs = {**self.kwargs, **kwargs}
        return self


def metric(_example, _prediction, _trace=None):
    return True


def main():
    prompt_lm = CapturingLM([
        {"observations": "first observations"},
        {"observations": "second observations"},
        {"summary": "frozen dataset summary"},
        *[{"proposed_instruction": f"candidate {index}"} for index in range(6)],
    ])
    task_lm = CapturingLM([{"route": "K11"}] * 100)
    program = dspy.Predict("text -> route")
    program.signature = program.signature.with_instructions("Route the opaque request.")
    trainset = [
        dspy.Example(text=f"request-{index:02d}", route="K11").with_inputs("text")
        for index in range(20)
    ]
    valset = [dspy.Example(text="validation", route="K11").with_inputs("text")]

    optimizer = MIPROv2(
        metric=metric,
        prompt_model=prompt_lm,
        task_model=task_lm,
        auto=None,
        num_candidates=6,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        seed=9,
    )

    captured = {}

    def stop_after_setup(self, program, instruction_candidates, demo_candidates, *_args, **_kwargs):
        captured["instructions"] = instruction_candidates[0]
        captured["demos_discarded"] = demo_candidates is None
        return program

    optimizer._optimize_prompt_parameters = types.MethodType(stop_after_setup, optimizer)
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
            view_data_batch_size=10,
        )

    source_root = Path(dspy.__file__).resolve().parents[1]
    print(json.dumps({
        "commit": subprocess.check_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "task_messages": [entry["messages"] for entry in task_lm.history],
        "prompt_messages": [entry["messages"] for entry in prompt_lm.history],
        "rollout_ids": [call["rollout_id"] for call in prompt_lm.copy_calls],
        "instructions": captured["instructions"],
        "demos_discarded": captured["demos_discarded"],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
