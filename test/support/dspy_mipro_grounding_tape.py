#!/usr/bin/env python3
"""Emit an exact DSPy 3.3.1 grounded-proposer decision tape without an LM."""

import hashlib
import json
from pathlib import Path

import dspy
import dspy.propose.grounded_proposer as grounded


class Program(dspy.Module):
    def __init__(self):
        super().__init__()
        self.first = dspy.Predict("question -> hint")
        self.second = dspy.Predict("hint -> answer")


class DeterministicRng:
    def __init__(self):
        self.next_rollout = 100

    def randint(self, _lower, _upper):
        value = self.next_rollout
        self.next_rollout += 1
        return value


class PromptModel:
    def __init__(self, tape):
        self.tape = tape

    def copy(self, **kwargs):
        self.tape.append({"rollout_id": kwargs["rollout_id"]})
        return self


def example(example_id, predictor_index, *, augmented):
    values = (
        {"question": example_id, "hint": example_id}
        if predictor_index == 0
        else {"hint": example_id, "answer": example_id}
    )
    if augmented:
        values["augmented"] = True
    return dspy.Example(**values)


def main():
    program = Program()
    calls = []
    original_generator = grounded.GenerateModuleInstruction

    class CapturingGenerator:
        def __init__(self, **_kwargs):
            self.inner = original_generator(
                program_code_string=None,
                use_dataset_summary=False,
                program_aware=False,
                use_task_demos=True,
                use_instruct_history=False,
                use_tip=False,
            )

        def __call__(self, **kwargs):
            captured = {}

            def generate(**fields):
                captured["task_demos"] = fields["task_demos"]
                return dspy.Prediction(proposed_instruction="proposal")

            self.inner.generate_module_instruction = generate
            result = self.inner.forward(**kwargs)
            calls.append(
                {
                    "predictor_index": kwargs["pred_i"],
                    "proposal_index": kwargs["demo_set_i"],
                    "task_demos": captured["task_demos"],
                }
            )
            return result

    grounded.GenerateModuleInstruction = CapturingGenerator
    rollout_tape = []

    try:
        proposer = grounded.GroundedProposer.__new__(grounded.GroundedProposer)
        proposer.program_aware = False
        proposer.use_dataset_summary = False
        proposer.use_task_demos = True
        proposer.num_demos_in_context = 3
        proposer.use_instruct_history = False
        proposer.use_tip = False
        proposer.set_tip_randomly = False
        proposer.set_history_randomly = False
        proposer.verbose = False
        proposer.rng = DeterministicRng()
        proposer.prompt_model = PromptModel(rollout_tape)
        proposer.init_temperature = 1.0
        proposer.program_code_string = None
        proposer.data_summary = None

        demo_candidates = [
            [
                [],
                [example("P0-L", 0, augmented=False)],
                [example("P0-A1", 0, augmented=True), example("P0-A2", 0, augmented=True)],
                [example("P0-B1", 0, augmented=True), example("P0-B2", 0, augmented=True)],
            ],
            [
                [],
                [example("P1-L", 1, augmented=False)],
                [example("P1-A1", 1, augmented=True), example("P1-A2", 1, augmented=True)],
                [example("P1-B1", 1, augmented=True), example("P1-B2", 1, augmented=True)],
            ],
        ]

        instructions = proposer.propose_instructions_for_program(
            trainset=[],
            program=program,
            demo_candidates=demo_candidates,
            trial_logs={},
            N=4,
        )
    finally:
        grounded.GenerateModuleInstruction = original_generator

    for call, rollout in zip(calls, rollout_tape, strict=True):
        call["rollout_id"] = rollout["rollout_id"]

    print(
        json.dumps(
            {
                "dspy_version": dspy.__version__,
                "grounded_proposer_sha256": hashlib.sha256(
                    Path(grounded.__file__).read_bytes()
                ).hexdigest(),
                "instruction_counts": {
                    str(index): len(values) for index, values in instructions.items()
                },
                "calls": calls,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
