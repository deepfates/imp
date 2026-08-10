"""Real-execution test for upstream_trial_sealing.py.

Run: tmp/dspy-parity-venv/bin/python scripts/test_upstream_trial_sealing.py

Runs an actual dspy 3.2.1 MIPROv2 compile (auto=None, num_trials=3,
zero-shot, minibatch=False) against a schema-adaptive DummyLM, then asserts
the extracted ledger carries >=2 trials with numeric scores and survives
json.dumps. Also unit-tests the GEPA extractor against a faithful
GEPAResult-shaped fixture and the graceful-absence paths.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dspy
from dspy.utils.dummies import DummyLM

from upstream_trial_sealing import (
    extract_gepa_trial_ledger,
    extract_mipro_trial_ledger,
    extract_trial_ledger,
)

FIELD_RE = re.compile(r"\[\[ ## (\w+) ## \]\]")


class SchemaAdaptiveDummyLM(DummyLM):
    """DummyLM that answers whatever output fields the prompt requests.

    MIPROv2 interleaves proposer signatures (proposed_instruction, ...) with
    the task signature (answer), so a fixed answer list cannot serve both;
    the ChatAdapter user message names the required output fields, so echo
    those. Distinct instruction text per call keeps candidates distinct.
    """

    def __init__(self):
        super().__init__([{"answer": "unused"}])
        self.calls = 0

    def forward(self, prompt=None, messages=None, **kwargs):
        self.calls += 1
        msgs = messages or [{"role": "user", "content": prompt or ""}]
        tail = msgs[-1]["content"] if isinstance(msgs[-1].get("content"), str) else ""
        fields = [f for f in FIELD_RE.findall(tail) if f != "completed"]
        if not fields:
            fields = ["answer"]
        payload = {f: f"dummy {f} v{self.calls}" for f in fields}
        content = self._format_answer_fields(payload)
        from dspy.dsp.utils.utils import dotdict

        return dotdict(
            choices=[dotdict(message=dotdict(content=content, tool_calls=None), finish_reason="stop")],
            usage=dotdict(prompt_tokens=0, completion_tokens=0, total_tokens=0),
            model="dummy",
        )


def run_mipro():
    lm = SchemaAdaptiveDummyLM()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())

    def metric(example, prediction, trace=None):
        # Deterministic, varies with output so trials are non-degenerate.
        return (len(getattr(prediction, "answer", "") or "") % 7) / 10.0

    trainset = [
        dspy.Example(question=f"q{i}", answer=f"a{i}").with_inputs("question") for i in range(6)
    ]
    optimizer = dspy.teleprompt.MIPROv2(
        metric=metric,
        auto=None,
        num_candidates=2,
        num_threads=1,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
        track_stats=True,
        seed=7,
    )
    captured = {}
    import optuna

    real_create_study = optuna.create_study

    def capturing_create_study(*args, **kwargs):
        study = real_create_study(*args, **kwargs)
        captured["study"] = study
        return study

    optuna.create_study = capturing_create_study
    try:
        compiled = optimizer.compile(
            dspy.Predict("question -> answer"),
            trainset=trainset,
            num_trials=3,
            minibatch=False,
        )
    finally:
        optuna.create_study = real_create_study
    return optimizer, compiled, captured.get("study")


def gepa_fixture():
    class FakeGEPAResult:
        candidates = [{"predict": "seed instruction"}, {"predict": "evolved instruction"}]
        parents = [[None], [0]]
        val_aggregate_scores = [0.25, 0.75]
        val_subscores = [{"0": 0.25}, {"0": 0.75}]
        per_val_instance_best_candidates = {"0": {1}}
        discovery_eval_counts = [1, 3]
        total_metric_calls = 4
        num_full_val_evals = 2
        seed = 0
        best_idx = 1

    return FakeGEPAResult()


def main() -> int:
    failures = []

    def check(cond, label):
        print(("PASS " if cond else "FAIL ") + label)
        if not cond:
            failures.append(label)

    optimizer, compiled, study = run_mipro()

    ledger = extract_trial_ledger("mipro", optimizer=optimizer, program=compiled, study=study)
    serialized = json.dumps(ledger)
    check(isinstance(serialized, str) and len(serialized) > 0, "mipro ledger json.dumps round-trip")
    check(ledger["available"] is True, "mipro ledger available")

    scored = [t for t in ledger["trials"] if isinstance(t["score"], (int, float))]
    check(len(scored) >= 2, f"mipro >=2 trials with numeric scores (got {len(scored)})")
    check(all(isinstance(t["trial_num"], int) for t in ledger["trials"]), "trial_num ints")

    param_trials = [t for t in ledger["trials"] if t["params"]]
    check(len(param_trials) >= 2, f"mipro >=2 trials expose instruction-index params (got {len(param_trials)})")
    check(
        all(
            all(k.endswith("_predictor_instruction") or k.endswith("_predictor_demos") for k in t["params"])
            for t in param_trials
        ),
        "param keys are predictor instruction/demo indices",
    )
    check(any(t["full_eval"] for t in ledger["trials"]), "at least one full_eval trial flagged")
    check(
        isinstance(ledger["candidate_programs_full_eval"], list)
        and len(ledger["candidate_programs_full_eval"]) >= 2,
        "score_data full_eval entries recovered from returned program",
    )
    check(
        isinstance(ledger["optuna_trials"], list) and len(ledger["optuna_trials"]) >= 3,
        f"optuna study trials captured when study passed",
    )

    # graceful absence: study unreachable through stock objects
    no_study = extract_mipro_trial_ledger(optimizer=optimizer, program=compiled)
    check(
        isinstance(no_study["optuna_trials"], dict) and no_study["optuna_trials"]["available"] is False,
        "optuna absence recorded with reason (stock MIPROv2 drops the study)",
    )
    json.dumps(no_study)

    # graceful absence: bare program
    bare = extract_mipro_trial_ledger(program=dspy.Predict("question -> answer"))
    check(bare["available"] is False and "reason" in bare, "mipro absence path returns available:false")

    gepa = extract_trial_ledger("gepa", result=gepa_fixture())
    json.dumps(gepa)
    check(gepa["available"] is True, "gepa ledger available")
    check(gepa["val_aggregate_scores"] == [0.25, 0.75], "gepa scores preserved")
    check(gepa["candidates"][1] == {"predict": "evolved instruction"}, "gepa candidate texts preserved")
    check(gepa["parents"] == [[None], [0]], "gepa lineage preserved")

    gepa_missing = extract_trial_ledger("gepa", program=object())
    check(gepa_missing["available"] is False, "gepa absence path returns available:false")

    unknown = extract_trial_ledger("nope")
    check(unknown["available"] is False, "unknown arm handled")

    print()
    if failures:
        print(f"{len(failures)} FAILURES: {failures}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
