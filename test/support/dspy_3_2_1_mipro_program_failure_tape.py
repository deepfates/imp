#!/usr/bin/env python3
"""Capture DSPy 3.2.1 program-aware degradation after description failures."""

import contextlib
import io
import json
import subprocess
import types
from pathlib import Path

import dspy
from dspy.propose.utils import get_dspy_source_code
from dspy.teleprompt import MIPROv2
from dspy.utils.dummies import DummyLM


class FailingDescribeLM(DummyLM):
    def __init__(self, answers):
        super().__init__(answers)
        self.attempted_messages = []
        self.copy_calls = []

    def copy(self, **kwargs):
        self.copy_calls.append(kwargs)
        self.kwargs = {**self.kwargs, **kwargs}
        return self

    def forward(self, prompt=None, messages=None, **kwargs):
        messages = messages or [{"role": "user", "content": prompt}]
        self.attempted_messages.append(messages)
        if any("Please describe what type of task this program appears" in message["content"] for message in messages):
            raise RuntimeError("description unavailable")
        return super().forward(prompt=prompt, messages=messages, **kwargs)


def metric(_example, _prediction, _trace=None):
    return True


def main():
    prompt_lm = FailingDescribeLM([
        {"observations": "dataset observations"},
        {"summary": "dataset summary"},
        *[{"proposed_instruction": f"candidate {index}"} for index in range(20)],
    ])
    task_lm = DummyLM([{"route": "K11"}] * 100)
    program = dspy.Predict("text -> route")
    program.signature = program.signature.with_instructions("Route the request.")
    trainset = [
        dspy.Example(text=f"request-{index}", route="K11").with_inputs("text")
        for index in range(4)
    ]
    valset = [dspy.Example(text="validation", route="K11").with_inputs("text")]
    program_code = get_dspy_source_code(program)

    optimizer = MIPROv2(
        metric=metric,
        prompt_model=prompt_lm,
        task_model=task_lm,
        auto=None,
        num_candidates=2,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        seed=9,
    )

    def stop(self, compiled, *_args, **_kwargs):
        return compiled

    optimizer._optimize_prompt_parameters = types.MethodType(stop, optimizer)

    with contextlib.redirect_stdout(io.StringIO()):
        optimizer.compile(
            program,
            trainset=trainset,
            valset=valset,
            num_trials=1,
            minibatch=False,
            program_aware_proposer=True,
            data_aware_proposer=True,
            tip_aware_proposer=True,
            fewshot_aware_proposer=False,
        )

    source_root = Path(dspy.__file__).resolve().parents[1]
    print(json.dumps({
        "commit": subprocess.check_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "program_code": program_code,
        "attempted_messages": prompt_lm.attempted_messages,
        "rollout_ids": [call["rollout_id"] for call in prompt_lm.copy_calls],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
