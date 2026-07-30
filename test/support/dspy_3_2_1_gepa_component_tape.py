#!/usr/bin/env python3
"""Capture two-component DSPy/GEPA feedback, reflection, and stopper behavior."""

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import dspy
import gepa
from gepa import EvaluationBatch
from gepa.strategies.component_selector import RoundRobinReflectionComponentSelector
from gepa.strategies.instruction_proposal import InstructionProposalSignature
from gepa.utils.stop_condition import MaxMetricCallsStopper

from dspy.teleprompt.gepa.gepa_utils import DspyAdapter


DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
GEPA_COMMIT = "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"


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


def git_commit(module, levels):
    root = Path(module.__file__).resolve().parents[levels]
    return subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()


def feedback(label):
    def callback(*, predictor_output, **_kwargs):
        value = predictor_output.get("response") or predictor_output.get("final_response")
        return dspy.Prediction(score=0.25, feedback=f"{label}:{value}")

    return callback


def main():
    dspy_commit = git_commit(dspy, 1)
    gepa_commit = git_commit(gepa, 2)
    if dspy_commit != DSPY_COMMIT or gepa_commit != GEPA_COMMIT:
        raise RuntimeError(
            f"source drift: DSPy={dspy_commit}, GEPA={gepa_commit}"
        )

    program = TwoStage()
    named = dict(program.named_predictors())
    names = list(named)
    candidate = {name: predictor.signature.instructions for name, predictor in named.items()}
    example = dspy.Example(prompt="Route request R17").with_inputs("prompt")
    draft = dspy.Prediction(reasoning="draft reasoning", response="DRAFT")
    final = dspy.Prediction(reasoning="review reasoning", final_response="FINAL")
    program_output = dspy.Prediction(response="FINAL")
    trace = [
        (named[names[0]], {"query": example.prompt}, draft),
        (
            named[names[1]],
            {"query": example.prompt, "response": draft.response},
            final,
        ),
    ]
    batch = EvaluationBatch(
        outputs=[program_output],
        scores=[0.25],
        trajectories=[
            {
                "trace": trace,
                "example": example,
                "prediction": program_output,
                "score": 0.25,
            }
        ],
    )
    adapter = DspyAdapter(
        student_module=program,
        metric_fn=lambda *_args, **_kwargs: 0.25,
        feedback_map={names[0]: feedback("draft-feedback"), names[1]: feedback("review-feedback")},
        rng=__import__("random").Random(9),
    )
    dataset = adapter.make_reflective_dataset(candidate, batch, names)
    prompts = {
        name: InstructionProposalSignature.prompt_renderer(
            {
                "current_instruction_doc": candidate[name],
                "dataset_with_feedback": dataset[name],
            }
        )
        for name in names
    }

    state = SimpleNamespace(
        list_of_named_predictors=names,
        named_predictor_id_to_update_next_for_program_candidate={0: 0},
    )
    selector = RoundRobinReflectionComponentSelector()
    selected = [selector(state, [], [], 0, candidate)[0] for _ in range(5)]

    stopper = MaxMetricCallsStopper(80)
    stops = {
        str(count): stopper(SimpleNamespace(total_num_evals=count))
        for count in (79, 80, 120)
    }

    print(
        json.dumps(
            {
                "dspy_commit": dspy_commit,
                "gepa_commit": gepa_commit,
                "names": names,
                "candidate": candidate,
                "reflective_dataset": dataset,
                "reflection_prompts": prompts,
                "round_robin": selected,
                "next_cursor": state.named_predictor_id_to_update_next_for_program_candidate[0],
                "max_metric_calls_stops": stops,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
