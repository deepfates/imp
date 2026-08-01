#!/usr/bin/env python3
"""Capture pinned DSPy 3.2.1 MIPRO minibatch/Optuna behavior."""

import contextlib
import io
import json
import subprocess
from pathlib import Path

import dspy
import dspy.teleprompt.utils as teleprompt_utils
from dspy.teleprompt import MIPROv2
from dspy.utils.dummies import DummyLM


class CapturingLM(DummyLM):
    def copy(self, **kwargs):
        self.kwargs = {**self.kwargs, **kwargs}
        return self


def metric(example, prediction, _trace=None):
    return example.route == prediction.route


def main():
    prompt_lm = CapturingLM([
        {"observations": "first observations"},
        {"observations": "second observations"},
        {"summary": "frozen dataset summary"},
        *[{"proposed_instruction": f"candidate {index}"} for index in range(4)],
    ])
    task_lm = CapturingLM([{"route": "K11"}] * 1000)
    program = dspy.Predict("text -> route")
    program.signature = program.signature.with_instructions("Route the opaque request.")
    trainset = [
        dspy.Example(text=f"train-{index:02d}", route="K11").with_inputs("text")
        for index in range(20)
    ]
    valset = [
        dspy.Example(
            text=f"validation-{index:02d}",
            route="K11" if index in {0, 3, 4, 7} else "OTHER",
        ).with_inputs("text")
        for index in range(8)
    ]

    sampled_indices = []
    original_create_minibatch = teleprompt_utils.create_minibatch

    def capture_minibatch(values, batch_size=50, rng=None):
        minibatch = original_create_minibatch(values, batch_size, rng)
        if values is valset:
            sampled_indices.append([valset.index(example) for example in minibatch])
        return minibatch

    teleprompt_utils.create_minibatch = capture_minibatch
    try:
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

        with contextlib.redirect_stdout(io.StringIO()):
            best = optimizer.compile(
                program,
                trainset=trainset,
                valset=valset,
                num_trials=12,
                minibatch=True,
                minibatch_size=3,
                minibatch_full_eval_steps=5,
                program_aware_proposer=False,
                data_aware_proposer=True,
                tip_aware_proposer=True,
                fewshot_aware_proposer=False,
                view_data_batch_size=10,
            )
    finally:
        teleprompt_utils.create_minibatch = original_create_minibatch

    instruction_index = {
        instruction: index
        for index, instruction in enumerate([
            "Route the opaque request.", "candidate 1", "candidate 2", "candidate 3"
        ])
    }
    trials = []
    full_evaluations = []
    for trial_num, log in best.trial_logs.items():
        if "mb_score" in log:
            trials.append({
                "upstream_trial_num": trial_num,
                "instruction": log["0_predictor_instruction"],
                "score": log["mb_score"],
            })
        if "full_eval_score" in log:
            evaluated_program = log["full_eval_program"]
            full_evaluations.append({
                "trial": trial_num,
                "instruction": instruction_index[
                    evaluated_program.predictors()[0].signature.instructions
                ],
                "score": log["full_eval_score"],
            })

    source_root = Path(dspy.__file__).resolve().parents[1]
    print(json.dumps({
        "commit": subprocess.check_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True
        ).strip(),
        "optuna": __import__("optuna").__version__,
        "sampled_indices": sampled_indices,
        "trials": trials,
        "full_evaluations": full_evaluations,
        "best_score": best.score,
        "best_instruction": best.predictors()[0].signature.instructions,
        "half_even_scores": {
            "positive": round(100 * sum([1.0, *([0.0] * 31)]) / 32, 2) / 100,
            "negative": round(100 * sum([-1.0, *([0.0] * 31)]) / 32, 2) / 100,
        },
    }, sort_keys=True))


if __name__ == "__main__":
    main()
