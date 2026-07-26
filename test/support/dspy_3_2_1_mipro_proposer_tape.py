#!/usr/bin/env python3
"""Capture the pinned DSPy 3.2.1 data-aware MIPRO proposer transcript."""

import json
import random
import subprocess
from pathlib import Path

import dspy
from dspy.propose.grounded_proposer import GroundedProposer
from dspy.utils.dummies import DummyLM


class CapturingLM(DummyLM):
    def __init__(self, answers):
        super().__init__(answers)
        self.copy_calls = []

    def copy(self, **kwargs):
        self.copy_calls.append(kwargs)
        self.kwargs = {**self.kwargs, **kwargs}
        return self


def main():
    answers = [
        {"observations": "first observations"},
        {"observations": "second observations"},
        {"summary": "frozen dataset summary"},
        {"proposed_instruction": "candidate zero"},
        {"proposed_instruction": "candidate one"},
    ]
    lm = CapturingLM(answers)
    program = dspy.Predict("text -> route")
    program.signature = program.signature.with_instructions("Route the opaque request.")
    trainset = [
        dspy.Example(text=f"request-{index:02d}", route="K11" if index % 2 == 0 else "K47").with_inputs("text")
        for index in range(20)
    ]

    proposer = GroundedProposer(
        prompt_model=lm,
        program=program,
        trainset=trainset,
        view_data_batch_size=10,
        program_aware=False,
        use_dataset_summary=True,
        use_task_demos=False,
        use_instruct_history=False,
        use_tip=True,
        set_tip_randomly=True,
        set_history_randomly=False,
        rng=random.Random(9),
        init_temperature=1.0,
    )
    proposed = proposer.propose_instructions_for_program(
        trainset=trainset,
        program=program,
        demo_candidates=None,
        trial_logs={},
        N=2,
    )
    proposed[0][0] = program.signature.instructions

    print(json.dumps({
        "version": dspy.__version__,
        "commit": subprocess.check_output(
            ["git", "-C", str(Path(dspy.__file__).resolve().parents[1]), "rev-parse", "HEAD"],
            text=True,
        ).strip(),
        "messages": [entry["messages"] for entry in lm.history],
        "rollout_ids": [call["rollout_id"] for call in lm.copy_calls],
        "temperatures": [entry["kwargs"].get("temperature") for entry in lm.history],
        "proposed": proposed[0],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
