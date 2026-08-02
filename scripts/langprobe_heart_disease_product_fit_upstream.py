#!/usr/bin/env python3
"""Pinned DSPy 3.2.1 product-fit proof for the LangProBe Heart Disease program."""

from __future__ import annotations

import argparse
import contextlib
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
DATASET_SOURCE_SHA256 = "3369f450e6fdbad6019755437f0228109cb457e62b8cf7c4b29799ba1f8fc884"
SPLIT_RECEIPT_SHA256 = "dff17d456635c520d5d92057c868be4293de07c355a21ae183464e3abefa90ba"
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


def configure_matched_chat_adapter(dspy):
    dspy.configure(adapter=dspy.ChatAdapter(use_json_adapter_fallback=False))


def program_class(dspy):
    class Opinion(dspy.Signature):
        """Given patient information, predict the presence of heart disease."""

        age: str = dspy.InputField(desc="Age in years")
        sex: str = dspy.InputField(desc="Sex (male or female)")
        cp: str = dspy.InputField(
            desc="Chest pain type (typical angina, atypical angina, non-anginal pain, asymptomatic)"
        )
        trestbps: str = dspy.InputField(desc="Resting blood pressure (in mm Hg on admission to the hospital)")
        chol: str = dspy.InputField(desc="Serum cholestoral in mg/dl")
        fbs: str = dspy.InputField(desc="Fasting blood sugar > 120 mg/dl (true or false)")
        restecg: str = dspy.InputField(
            desc="Resting electrocardiographic results (normal, ST-T wave abnormality, left ventricular hypertrophy)"
        )
        thalach: str = dspy.InputField(desc="Maximum heart rate achieved")
        exang: str = dspy.InputField(desc="Exercise induced angina (yes or no)")
        oldpeak: str = dspy.InputField(desc="ST depression induced by exercise relative to rest")
        slope: str = dspy.InputField(
            desc="The slope of the peak exercise ST segment (upsloping, flat, downsloping)"
        )
        ca: str = dspy.InputField(desc="Number of major vessels (0-3) colored by flourosopy")
        thal: str = dspy.InputField(desc="Thalassemia (normal, fixed defect, reversible defect)")
        answer: str = dspy.OutputField(desc="Does this patient have heart disease? Just yes or no.")

    class Vote(Opinion):
        """Given patient information, predict the presence of heart disease. I can critically assess the provided trainee opinions."""

        context: list[str] = dspy.InputField(desc="A list of opinions from trainee doctors.")

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
                f"I'm a trainee doctor, trying to {item.reasoning.strip('.')}. "
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


def canonical_messages(messages) -> bytes:
    return json.dumps(messages, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, int(len(ordered) * fraction + 0.999999) - 1)]


def load_frozen_data(dspy, dataset_path: Path, split_path: Path):
    mappings = {
        "sex": {"0": "female", "1": "male"},
        "cp": {"1": "typical angina", "2": "atypical angina", "3": "non-anginal pain", "4": "asymptomatic"},
        "restecg": {"0": "normal", "1": "ST-T wave abnormality", "2": "left ventricular hypertrophy"},
        "exang": {"0": "no", "1": "yes"},
        "slope": {"1": "upsloping", "2": "flat", "3": "downsloping"},
        "thal": {"3": "normal", "6": "fixed defect", "7": "reversible defect"},
        "target": {"0": "no", "1": "yes"},
    }
    dataset_bytes = dataset_path.read_bytes()
    source_bytes = dataset_bytes[:-1] if dataset_bytes.endswith(b"\n") else dataset_bytes
    if hashlib.sha256(source_bytes).hexdigest() != DATASET_SOURCE_SHA256:
        raise RuntimeError("LangProBe Heart Disease dataset authority drift")
    if hashlib.sha256(split_path.read_bytes()).hexdigest() != SPLIT_RECEIPT_SHA256:
        raise RuntimeError("LangProBe Heart Disease split receipt drift")

    with dataset_path.open(newline="") as handle:
        source = list(csv.DictReader(handle))
    examples_by_index = {}
    for index, row in enumerate(source):
        normalized = {key: mappings.get(key, {}).get(value, value) for key, value in row.items()}
        answer = normalized.pop("target")
        examples_by_index[index] = dspy.Example(
            id=f"heart-source-{index}", answer=answer, **normalized
        ).with_inputs(*FIELDS)
    receipt = json.loads(split_path.read_text())
    return {
        name: [examples_by_index[index] for index in receipt["splits"][name]["source_indices"]]
        for name in ("train", "selection", "test")
    }


def prereg_census(dspy_root: Path, dataset_path: Path, split_path: Path):
    dspy = load_dspy(dspy_root)
    configure_matched_chat_adapter(dspy)
    from dspy.dsp.utils.utils import dotdict
    from dspy.utils.dummies import DummyLM

    class CapturingTaskLM(dspy.BaseLM):
        def __init__(self):
            super().__init__("provider-disabled-heart-task", "chat", 0.0, 1000, True)
            self.calls = []

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

        def __deepcopy__(self, _memo):
            return self

        def forward(self, prompt=None, messages=None, **_kwargs):
            messages = messages or [{"role": "user", "content": prompt}]
            self.calls.append(messages)
            content = (
                "[[ ## reasoning ## ]]\nprovider-free clinical reasoning\n"
                "[[ ## answer ## ]]\nno\n[[ ## completed ## ]]"
            )
            return dotdict(
                choices=[dotdict(message=dotdict(content=content, tool_calls=None), finish_reason="stop")],
                usage=dotdict(prompt_tokens=0, completion_tokens=0, total_tokens=0),
                model="provider-disabled-heart-task",
            )

    class CapturingPromptLM(DummyLM):
        def __init__(self, answers):
            super().__init__(answers)
            self.calls = []

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

        def __deepcopy__(self, _memo):
            return self

        def forward(self, prompt=None, messages=None, **kwargs):
            self.calls.append(messages or [{"role": "user", "content": prompt}])
            return super().forward(prompt=prompt, messages=messages, **kwargs)

    prompt_answers = [
        {"observations": "provider-free Heart Disease observations"},
        {"observations": "provider-free Heart Disease observations"},
        {"summary": "provider-free Heart Disease summary"},
    ]
    for _predictor in range(4):
        for _candidate in range(12):
            prompt_answers.extend(
                [
                    {"program_description": "three opinions followed by one vote"},
                    {"module_description": "one named stage in the four-call program"},
                    {"proposed_instruction": "provider-free candidate instruction"},
                ]
            )

    task = CapturingTaskLM()
    prompt = CapturingPromptLM(prompt_answers)
    program = program_class(dspy)()
    data = load_frozen_data(dspy, dataset_path, split_path)
    optimizer = dspy.MIPROv2(
        metric=metric,
        prompt_model=prompt,
        task_model=task,
        auto=None,
        num_candidates=12,
        max_bootstrapped_demos=4,
        max_labeled_demos=2,
        num_threads=1,
        max_errors=10,
        seed=2026080201,
    )
    optimizer._set_random_seeds(2026080201)
    with dspy.context(lm=task):
        demos = optimizer._bootstrap_fewshot_examples(
            program,
            data["train"],
            2026080201,
            None,
            num_fewshot_candidates=12,
            max_bootstrapped_demos=4,
            max_labeled_demos=2,
            max_errors=10,
            metric_threshold=None,
        )
    instructions = optimizer._propose_instructions(
        program,
        data["train"],
        demos,
        10,
        True,
        True,
        True,
        True,
        num_instruct_candidates=12,
    )
    assert all(len(values) == 12 for values in instructions.values())

    prompt_bytes = [canonical_messages(messages) for messages in prompt.calls]
    task.calls = []
    all_rows = data["train"] + data["selection"] + data["test"]
    for arm in range(12):
        candidate = program_class(dspy)()
        bind_lm(candidate, task)
        for index, (_name, predictor) in enumerate(candidate.named_predictors()):
            predictor.demos = demos[index][arm]
        for example in all_rows:
            candidate(**example.inputs())
    task_bytes = [canonical_messages(messages) for messages in task.calls]

    print(
        json.dumps(
            {
                "dspy_commit": DSPY_COMMIT,
                "full_opportunity_claimed": False,
                "proposer": {
                    "calls": len(prompt_bytes),
                    "min_bytes": min(map(len, prompt_bytes)),
                    "p95_bytes": percentile(list(map(len, prompt_bytes)), 0.95),
                    "max_bytes": max(map(len, prompt_bytes)),
                    "ordered_sha256": hashlib.sha256(b"".join(prompt_bytes)).hexdigest(),
                },
                "task": {
                    "calls": len(task_bytes),
                    "min_bytes": min(map(len, task_bytes)),
                    "p95_bytes": percentile(list(map(len, task_bytes)), 0.95),
                    "max_bytes": max(map(len, task_bytes)),
                    "ordered_sha256": hashlib.sha256(b"".join(task_bytes)).hexdigest(),
                    "demo_arm_sizes": {
                        str(index): [len(arm) for arm in demos[index]] for index in range(4)
                    },
                },
            },
            sort_keys=True,
        )
    )


def fresh(dspy_root: Path, state_path: Path):
    dspy = load_dspy(dspy_root)
    configure_matched_chat_adapter(dspy)
    program = program_class(dspy)()
    program.load(state_path, allow_pickle=False, allow_unsafe_lm_state=False)
    bind_lm(program, task_lm(dspy))
    predictions = [program(**row()).answer for _ in range(4)]
    print(json.dumps({"fresh_predictions": predictions}, sort_keys=True))


def readiness(dspy_root: Path):
    dspy = load_dspy(dspy_root)
    configure_matched_chat_adapter(dspy)
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
    parser.add_argument("--prereg-census", action="store_true")
    parser.add_argument("--dataset", type=Path)
    parser.add_argument("--split", type=Path)
    args = parser.parse_args()
    if args.fresh:
        fresh(args.dspy_root, args.state)
    elif args.prereg_census:
        prereg_census(args.dspy_root, args.dataset, args.split)
    else:
        readiness(args.dspy_root)


if __name__ == "__main__":
    main()
