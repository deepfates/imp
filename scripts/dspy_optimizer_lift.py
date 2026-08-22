#!/usr/bin/env python3
"""Provider-free DSPy optimizer lift sidecar for scoped parity checks."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional

import dspy


COPRO_SETUP = """git clone https://github.com/stanfordnlp/dspy.git tmp/dspy-3.2.1
git -C tmp/dspy-3.2.1 checkout --detach 29448ae12756abdd14bd8796c819247ebb83673c
IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh"""


class QASignature(dspy.Signature):
    """Answer the question."""

    question = dspy.InputField()
    answer = dspy.OutputField()


class DemoSensitiveLM(dspy.BaseLM):
    def __init__(self) -> None:
        super().__init__(model="fake/optimizer-lift", cache=False)
        self.calls = 0
        self.simba_sampling_enabled = False

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        self.calls += 1
        content = "\n".join(
            [str(prompt or "")]
            + [str(message.get("content", "")) for message in (messages or [])]
        )
        response = optimizer_response(content)
        if response is not None:
            return SimpleNamespace(
                choices=[SimpleNamespace(message=SimpleNamespace(content=response))],
                usage={},
                model=self.model,
                _hidden_params={},
            )

        answer = "Paris" if self.should_answer_paris(content) else "unknown"
        return SimpleNamespace(
            choices=[SimpleNamespace(message=SimpleNamespace(content=f"[[ ## answer ## ]]\n{answer}"))],
            usage={},
            model=self.model,
            _hidden_params={},
        )

    def should_answer_paris(self, content: str) -> bool:
        if should_answer_paris(content):
            return True

        if (
            self.simba_sampling_enabled
            and "Capital of France?" in content
            and "[[ ## answer ## ]]\nParis" not in content
        ):
            rollout_id = int(self.kwargs.get("rollout_id", 0) or 0)
            return rollout_id % 2 == 1

        return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out")
    args = parser.parse_args()

    lm = DemoSensitiveLM()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())

    rows = [
        run_optimizer("LabeledFewShot", lm, lambda student, trainset: dspy.LabeledFewShot(k=1).compile(student, trainset=trainset, sample=False)),
        run_optimizer(
            "BootstrapFewShot",
            lm,
            lambda student, trainset: dspy.BootstrapFewShot(metric=metric, max_bootstrapped_demos=1, max_labeled_demos=1).compile(
                student, trainset=trainset
            ),
        ),
        run_optimizer(
            "RandomSearch",
            lm,
            lambda student, trainset: dspy.BootstrapFewShotWithRandomSearch(
                metric=metric,
                max_bootstrapped_demos=1,
                max_labeled_demos=1,
                num_candidate_programs=2,
                num_threads=1,
                max_errors=2,
            ).compile(student, trainset=trainset, valset=datasets()[1]),
        ),
        copro_row(lm),
        run_optimizer(
            "MIPROv2",
            lm,
            lambda student, trainset: dspy.MIPROv2(
                metric=metric,
                auto=None,
                num_candidates=2,
                num_threads=1,
                max_errors=2,
            ).compile(
                student,
                trainset=trainset,
                valset=datasets()[1],
                num_trials=2,
                max_bootstrapped_demos=1,
                max_labeled_demos=1,
                minibatch=False,
                program_aware_proposer=False,
                data_aware_proposer=False,
                tip_aware_proposer=False,
                fewshot_aware_proposer=False,
                requires_permission_to_run=False,
            ),
        ),
    ]

    if hasattr(dspy, "SIMBA"):
        rows.append(
            run_optimizer(
                "SIMBA",
                lm,
                lambda student, trainset: compile_simba(student, trainset, lm),
            )
        )

    if hasattr(dspy, "GEPA"):
        from dspy.teleprompt.gepa.gepa_utils import ScoreWithFeedback

        def gepa_metric(example, prediction, trace=None, pred_name=None, pred_trace=None):  # noqa: ANN001
            score = 1.0 if metric(example, prediction) else 0.0
            if pred_name is not None:
                return ScoreWithFeedback(score=score, feedback="Always answer Paris when asked about France.")
            return score

        rows.append(
            run_optimizer(
                "GEPA",
                lm,
                lambda student, trainset: dspy.GEPA(
                    metric=gepa_metric,
                    max_metric_calls=4,
                    reflection_lm=lm,
                    reflection_minibatch_size=1,
                    skip_perfect_score=False,
                    use_merge=False,
                    num_threads=1,
                ).compile(student, trainset=trainset, valset=datasets()[1]),
            )
        )

    report = {
        "schema_version": 1,
        "runner": "python-dspy-optimizer-lift",
        "generated_at": timestamp(),
        "git_sha": git_sha(),
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "python_packages": {
            "dspy": package_version("dspy"),
            "dspy-ai": package_version("dspy-ai"),
        },
        "capabilities": optimizer_capabilities(),
        "task": task_metadata(),
        "rows": rows,
    }

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.out)
    else:
        print(json.dumps(report, indent=2, sort_keys=True))

    return 0


def run_optimizer(name: str, lm: DemoSensitiveLM, compile_fn) -> Dict[str, Any]:  # noqa: ANN001
    trainset, devset = datasets()
    baseline_program = dspy.Predict(QASignature)
    baseline_calls = lm.calls
    baseline_score = evaluate(baseline_program, devset)
    calls_after_baseline = lm.calls

    started = time.perf_counter()
    compiled = compile_fn(dspy.Predict(QASignature), trainset)
    compile_ms = (time.perf_counter() - started) * 1000
    optimized_score = evaluate(compiled, devset)
    calls_after_optimized = lm.calls

    return {
        "optimizer": name,
        "comparison_status": "direct",
        "baseline_score": baseline_score,
        "optimized_score": optimized_score,
        "lift": optimized_score - baseline_score,
        "lm_calls": calls_after_optimized - baseline_calls,
        "compile_lm_calls": calls_after_optimized - calls_after_baseline - len(devset),
        "compile_duration_ms": round(compile_ms, 3),
        "candidate_count": candidate_count(compiled),
        "trace": {
            "demos": demos(compiled),
            "instructions": instructions(compiled),
            "notes": "Provider-free deterministic LM answers train question or demo/instruction-conditioned prompts."
        },
    }


def copro_row(lm: DemoSensitiveLM) -> Dict[str, Any]:
    row = run_optimizer(
        "COPRO",
        lm,
        lambda student, trainset: dspy.COPRO(metric=metric, breadth=2, depth=1).compile(
            student, trainset=trainset, eval_kwargs={}
        ),
    )
    row["c1_differential"] = run_copro_isolation_differential()
    return row


def run_copro_isolation_differential() -> Dict[str, Any]:
    fixture = Path(__file__).resolve().with_name("dspy_copro_isolation_differential.py")
    config = Path(__file__).resolve().parents[1] / "test/fixtures/dspy_copro_isolation_differential.json"
    target = Path(os.environ.get("IMP_DSPY_COPRO_SOURCE", "tmp/dspy-3.2.1"))
    if not target.is_absolute():
        target = Path.cwd() / target

    if not (target / ".git").is_dir():
        raise RuntimeError(
            f"pinned DSPy 3.2.1 COPRO source checkout is missing: {target}\n"
            f"Exact setup:\n{COPRO_SETUP}"
        )

    env = os.environ.copy()
    env["PYTHONPATH"] = os.pathsep.join(
        [str(target)] + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else [])
    )
    completed = subprocess.run(
        [sys.executable, str(fixture), "--config", str(config)],
        capture_output=True,
        text=True,
        env=env,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"pinned DSPy 3.2.1 COPRO differential failed:\n{detail}")
    return json.loads(completed.stdout)


def compile_simba(student: Any, trainset: List[dspy.Example], lm: DemoSensitiveLM) -> Any:
    lm.simba_sampling_enabled = True
    try:
        return dspy.SIMBA(
            metric=numeric_metric,
            bsize=1,
            num_candidates=2,
            max_steps=2,
            max_demos=1,
            prompt_model=lm,
            num_threads=1,
            temperature_for_sampling=0.01,
            temperature_for_candidates=0.01,
        ).compile(student, trainset=trainset, seed=0)
    finally:
        lm.simba_sampling_enabled = False


def evaluate(program: Any, devset: List[dspy.Example]) -> float:
    scores = []
    for example in devset:
        prediction = program(question=example.question)
        scores.append(1.0 if metric(example, prediction) else 0.0)
    return sum(scores) / len(scores)


def metric(example: dspy.Example, prediction: Any, trace=None) -> bool:  # noqa: ANN001
    return str(getattr(prediction, "answer", "")).strip() == str(example.answer).strip()


def numeric_metric(example: dspy.Example, prediction: Any, trace=None) -> float:  # noqa: ANN001
    return 1.0 if metric(example, prediction, trace=trace) else 0.0


def datasets():
    trainset = [
        dspy.Example(question="What is the capital of France?", answer="Paris").with_inputs("question"),
        dspy.Example(question="Capital of France?", answer="Paris").with_inputs("question"),
    ]
    devset = [dspy.Example(question="Capital of France?", answer="Paris").with_inputs("question")]
    return trainset, devset


def package_version(name: str) -> Optional[str]:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def optimizer_capabilities() -> Dict[str, bool]:
    names = [
        "LabeledFewShot",
        "BootstrapFewShot",
        "BootstrapFewShotWithRandomSearch",
        "COPRO",
        "MIPROv2",
        "SIMBA",
        "GEPA",
        "BootstrapFinetune",
        "GRPO",
        "ReAct",
        "ReActV2",
    ]
    return {name: hasattr(dspy, name) for name in names}


def should_answer_paris(content: str) -> bool:
    return (
        "What is the capital of France?" in content
        or "answer ## ]]\nParis" in content
        or "answer: Paris" in content
        or "Always answer Paris" in content
    )


def optimizer_response(content: str) -> Optional[str]:
    instruction = "Always answer Paris when asked about France."

    if "Your task is to write a new instruction for the assistant" in content:
        return f"```\n{instruction}\n```"

    if "proposed_instruction" in content and "proposed_prefix_for_output_field" in content:
        return (
            "[[ ## proposed_instruction ## ]]\n"
            f"{instruction}\n"
            "[[ ## proposed_prefix_for_output_field ## ]]\n"
            "Answer:"
        )

    if "proposed_instruction" in content:
        return f"[[ ## proposed_instruction ## ]]\n{instruction}"

    if "observations" in content:
        return "[[ ## observations ## ]]\nThe task asks about France; a useful instruction is to answer Paris."

    if "discussion" in content and "module_advice" in content:
        if "better_program_trajectory" in content and "worse_program_trajectory" in content:
            return json.dumps(
                {
                    "discussion": "The weaker trajectory misses the abbreviated capital question.",
                    "module_advice": {"self": instruction},
                }
            )

        return (
            "[[ ## discussion ## ]]\n"
            "The baseline misses the abbreviated capital question.\n"
            "[[ ## module_advice ## ]]\n"
            f"{instruction}"
        )

    return None


def candidate_count(program: Any) -> int:
    return sum(len(getattr(predictor, "demos", []) or []) for predictor in program.predictors())


def demos(program: Any) -> List[Dict[str, Any]]:
    values = []
    for predictor in program.predictors():
        for demo in getattr(predictor, "demos", []) or []:
            values.append({"question": getattr(demo, "question", None), "answer": getattr(demo, "answer", None)})
    return values


def instructions(program: Any) -> List[str]:
    values = []
    for predictor in program.predictors():
        signature = getattr(predictor, "signature", None)
        instruction = getattr(signature, "instructions", None)
        if instruction is not None:
            values.append(str(instruction))
    return values


def task_metadata() -> Dict[str, Any]:
    return {
        "id": "demo_sensitive_capital",
        "train_examples": 1,
        "dev_examples": 1,
        "known_baseline": 0.0,
        "known_optimum": 1.0,
    }


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


def timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


if __name__ == "__main__":
    raise SystemExit(main())
