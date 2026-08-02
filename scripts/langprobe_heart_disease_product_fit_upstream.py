#!/usr/bin/env python3
"""Pinned DSPy 3.2.1 product-fit proof for the LangProBe Heart Disease program."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
FIELDS = (
    "age",
    "sex",
    "cp",
    "trestbps",
    "chol",
    "fbs",
    "restecg",
    "thalach",
    "exang",
    "oldpeak",
    "slope",
    "ca",
    "thal",
)


def authenticate(root: Path):
    actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if actual != DSPY_COMMIT:
        raise RuntimeError(f"DSPy authority drift: expected {DSPY_COMMIT}, got {actual}")
    dirty = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"], text=True
    ).strip()
    if dirty:
        raise RuntimeError("pinned DSPy checkout has tracked source edits")


def load_dspy(root: Path):
    authenticate(root)
    sys.path.insert(0, str(root))
    import dspy

    return dspy


def program_class(dspy):
    class Opinion(dspy.Signature):
        """Given patient information, predict the presence of heart disease. Answer yes or no."""

        age: str = dspy.InputField()
        sex: str = dspy.InputField()
        cp: str = dspy.InputField()
        trestbps: str = dspy.InputField()
        chol: str = dspy.InputField()
        fbs: str = dspy.InputField()
        restecg: str = dspy.InputField()
        thalach: str = dspy.InputField()
        exang: str = dspy.InputField()
        oldpeak: str = dspy.InputField()
        slope: str = dspy.InputField()
        ca: str = dspy.InputField()
        thal: str = dspy.InputField()
        answer: str = dspy.OutputField()

    class Vote(Opinion):
        """Critically assess the trainee opinions and answer yes or no."""

        context: list[str] = dspy.InputField()

    class Program(dspy.Module):
        def __init__(self):
            super().__init__()
            self.opinion_1 = dspy.ChainOfThought(Opinion, temperature=0.70)
            self.opinion_2 = dspy.ChainOfThought(Opinion, temperature=0.71)
            self.opinion_3 = dspy.ChainOfThought(Opinion, temperature=0.72)
            self.vote = dspy.ChainOfThought(Vote)

        def forward(self, **kwargs):
            opinions = [self.opinion_1(**kwargs), self.opinion_2(**kwargs), self.opinion_3(**kwargs)]
            context = [
                f"I'm a trainee doctor, reasoning that {item.reasoning.strip('.')}. "
                f"Hence, my answer is {item.answer.strip('.')}."
                for item in opinions
            ]
            return self.vote(context=context, **kwargs)

    return Program


def row():
    return {
        "age": "63",
        "sex": "male",
        "cp": "typical angina",
        "trestbps": "145",
        "chol": "233",
        "fbs": "true",
        "restecg": "left ventricular hypertrophy",
        "thalach": "150",
        "exang": "no",
        "oldpeak": "2.3",
        "slope": "downsloping",
        "ca": "0",
        "thal": "fixed defect",
    }


def examples(dspy):
    return [
        dspy.Example(id=f"heart-{split}", answer="yes", **row()).with_inputs(*FIELDS)
        for split in ("train", "selection", "test")
    ]


def task_lm(dspy):
    from dspy.dsp.utils.utils import dotdict

    class PlantedTaskLM(dspy.BaseLM):
        def __init__(self):
            super().__init__("provider-disabled-heart", "chat", 0.0, 1000, True)

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

        def __deepcopy__(self, _memo):
            return self

        def forward(self, prompt=None, messages=None, **_kwargs):
            rendered = json.dumps(messages or [{"role": "user", "content": prompt}])
            answer = "yes" if "Diagnose consistently." in rendered else "no"
            content = (
                "[[ ## reasoning ## ]]\nprovider-free reasoning\n"
                f"[[ ## answer ## ]]\n{answer}\n[[ ## completed ## ]]"
            )
            return dotdict(
                choices=[
                    dotdict(
                        message=dotdict(content=content, tool_calls=None),
                        finish_reason="stop",
                    )
                ],
                usage=dotdict(prompt_tokens=0, completion_tokens=0, total_tokens=0),
                model="provider-disabled-heart",
            )

    return PlantedTaskLM()


def bind_lm(program, lm):
    for _name, predictor in program.named_predictors():
        predictor.lm = lm


def metric(gold, prediction, _trace=None):
    return prediction.answer.strip().strip(".").lower() == gold.answer


def fresh(dspy_root: Path, state_path: Path):
    dspy = load_dspy(dspy_root)
    program = program_class(dspy)()
    program.load(state_path, allow_pickle=False, allow_unsafe_lm_state=False)
    bind_lm(program, task_lm(dspy))
    predictions = [program(**row()).answer for _ in range(4)]
    print(json.dumps({"fresh_predictions": predictions}, sort_keys=True))


def readiness(dspy_root: Path):
    dspy = load_dspy(dspy_root)
    from dspy.utils.dummies import DummyLM

    class SharedDummyLM(DummyLM):
        def __deepcopy__(self, _memo):
            return self

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

    prompt_lm = SharedDummyLM(
        [{"proposed_instruction": "Diagnose consistently."} for _ in range(8)]
    )
    task = task_lm(dspy)
    rows = examples(dspy)
    baseline = program_class(dspy)()
    candidate_source = program_class(dspy)()
    optimizer = dspy.MIPROv2(
        metric=metric,
        prompt_model=prompt_lm,
        task_model=task,
        auto=None,
        num_candidates=2,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        num_threads=1,
        max_errors=10,
        seed=17,
    )

    with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink):
        candidate = optimizer.compile(
            candidate_source,
            trainset=rows[:1],
            valset=rows[1:2],
            num_trials=2,
            max_bootstrapped_demos=0,
            max_labeled_demos=0,
            minibatch=False,
            program_aware_proposer=False,
            data_aware_proposer=False,
            tip_aware_proposer=False,
            fewshot_aware_proposer=False,
        )

    def score(program):
        bind_lm(program, task_lm(dspy))
        return float(metric(rows[1], program(**rows[1].inputs())))

    baseline_score = score(baseline)
    candidate_score = score(candidate)
    selected = candidate if candidate_score > baseline_score else baseline
    selected_kind = "optimized" if selected is candidate else "baseline"
    instructions = {
        name: predictor.signature.instructions for name, predictor in selected.named_predictors()
    }

    with tempfile.TemporaryDirectory(prefix="heart-upstream-fit-") as temp:
        state_path = Path(temp) / "selected.json"
        for _name, predictor in selected.named_predictors():
            predictor.lm = None
        selected.save(state_path, save_program=False)
        state_sha = hashlib.sha256(state_path.read_bytes()).hexdigest()
        output = subprocess.check_output(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--fresh",
                "--dspy-root",
                str(dspy_root),
                "--state",
                str(state_path),
            ],
            text=True,
            env={**os.environ, "PYTHONPATH": str(dspy_root)},
        )
        fresh_result = json.loads(output.splitlines()[-1])

    print(
        json.dumps(
            {
                "dspy_commit": DSPY_COMMIT,
                "program": "LangProBe/MIPRO four-call Heart Disease clinical-opinion ensemble",
                "full_opportunity_claimed": False,
                "predictors": list(instructions),
                "selected_instructions": instructions,
                "baseline_selection": baseline_score,
                "optimized_selection": candidate_score,
                "selected": selected_kind,
                "changed_instruction_count": sum(
                    value == "Diagnose consistently." for value in instructions.values()
                ),
                "state_sha256": state_sha,
                **fresh_result,
            },
            sort_keys=True,
        )
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", required=True, type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--fresh", action="store_true")
    args = parser.parse_args()
    if args.fresh:
        fresh(args.dspy_root, args.state)
    else:
        readiness(args.dspy_root)


if __name__ == "__main__":
    main()
