#!/usr/bin/env python3
"""Capture pinned DSPy 3.2.1 MIPRO setup for a two-predictor program."""

import contextlib
import io
import json
import subprocess
import types
from pathlib import Path

import dspy
from dspy.teleprompt import MIPROv2
from dspy.utils.dummies import DummyLM


class GenerateResponse(dspy.Signature):
    """Respond to the query"""

    query = dspy.InputField()
    response = dspy.OutputField()


class EnsureCorrectResponse(dspy.Signature):
    """Ensure the response is correct and adheres to the given constraints. Your response will be used as the final response."""

    query = dspy.InputField()
    response = dspy.InputField()
    final_response = dspy.OutputField()


class TwoStage(dspy.Module):
    def __init__(self):
        self.generate_response_module = dspy.ChainOfThought(GenerateResponse)
        self.ensure_correct_response_module = dspy.ChainOfThought(EnsureCorrectResponse)

    def forward(self, prompt):
        draft = self.generate_response_module(query=prompt).response
        final = self.ensure_correct_response_module(query=prompt, response=draft)
        return dspy.Prediction(response=final.final_response)


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
        *[
            {"proposed_instruction": f"predictor candidate {index}"}
            for index in range(8)
        ],
    ])
    task_answers = []
    for _index in range(100):
        task_answers.extend([
            {"reasoning": "draft reasoning", "response": "DRAFT"},
            {"reasoning": "review reasoning", "final_response": "FINAL"},
        ])
    task_lm = CapturingLM(task_answers)
    program = TwoStage()
    trainset = [
        dspy.Example(prompt=f"request-{index:02d}").with_inputs("prompt")
        for index in range(16)
    ]
    valset = [dspy.Example(prompt="validation").with_inputs("prompt")]

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

    def stop_after_setup(self, program, instruction_candidates, demo_candidates, *_args, **_kwargs):
        captured["instructions"] = instruction_candidates
        captured["demos_discarded"] = demo_candidates is None
        return program

    optimizer._optimize_prompt_parameters = types.MethodType(stop_after_setup, optimizer)
    with contextlib.redirect_stdout(io.StringIO()):
        optimizer.compile(
            program,
            trainset=trainset,
            valset=valset,
            num_trials=8,
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
