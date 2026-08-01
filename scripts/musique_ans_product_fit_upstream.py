#!/usr/bin/env python3
"""Pinned MuSiQue scorer and DSPy 3.2.1 product-fit probes; never calls a provider."""

from __future__ import annotations

import argparse
import ast
from collections import Counter
import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unicodedata

DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
MUSIQUE_COMMIT = "922ac98f19a201998dbdae6d7f2887a5258dbdeb"


def authenticate(root: Path, expected: str):
    actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if actual != expected:
        raise RuntimeError(f"authority drift: expected {expected}, got {actual}")
    dirty = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"], text=True
    ).strip()
    if dirty:
        raise RuntimeError("authority checkout has tracked source edits")


def score_lines(musique_root: Path, input_path: Path | None):
    authenticate(musique_root, MUSIQUE_COMMIT)
    sys.path.insert(0, str(musique_root))
    from metrics.answer import compute_exact, compute_f1
    from metrics.support import SupportMetric

    source = input_path.open() if input_path else sys.stdin
    for line in source:
        record = json.loads(line)
        answers = [record["answer"], *record.get("answer_aliases", [])]
        answer_em = max(float(compute_exact(answer, record["predicted_answer"])) for answer in answers)
        answer_f1 = max(float(compute_f1(answer, record["predicted_answer"])) for answer in answers)
        support = SupportMetric()
        support(record["predicted_support_idxs"], record["support_idxs"])
        support_f1 = float(support.get_metric()[1])
        print(json.dumps({"answer_em": answer_em, "answer_f1": answer_f1, "support_f1": support_f1}))


def verify_receipt(data_root: Path, receipt_path: Path):
    receipt_bytes = receipt_path.read_bytes()
    receipt = json.loads(receipt_bytes)
    train_bytes = (data_root / "musique_ans_v1.0_train.jsonl").read_bytes()
    dev_bytes = (data_root / "musique_ans_v1.0_dev.jsonl").read_bytes()
    source = receipt["source"]
    assert hashlib.sha256(train_bytes).hexdigest() == source["train_sha256"]
    assert hashlib.sha256(dev_bytes).hexdigest() == source["dev_sha256"]
    rows = [json.loads(line) for line in train_bytes.splitlines()]
    assert len(rows) == source["train_rows"]

    def normalize(question):
        return " ".join(unicodedata.normalize("NFKC", question).casefold().split())

    normalized = [normalize(row["question"]) for row in rows]
    frequencies = Counter(normalized)
    assert sum(count > 1 for count in frequencies.values()) == receipt["derivation"]["duplicate_groups_excluded"]
    assert sum(count for count in frequencies.values() if count > 1) == receipt["derivation"]["duplicate_rows_excluded"]
    salt = receipt["derivation"]["salt"]
    by_hop = {2: [], 3: [], 4: []}
    for source_index, (row, question) in enumerate(zip(rows, normalized)):
        if frequencies[question] > 1:
            continue
        hop = len(row["question_decomposition"])
        ordering = hashlib.sha256(f"{salt}\0{question}\0{row['id']}".encode()).hexdigest()
        by_hop[hop].append((ordering, source_index, row, question))
    for candidates in by_hop.values():
        candidates.sort()

    train_quotas = {2: 505, 3: 154, 4: 41}
    selection_quotas = {2: 216, 3: 66, 4: 18}
    replay = {"train": [], "selection": []}
    for hop in (2, 3, 4):
        train_end = train_quotas[hop]
        selected = {
            "train": by_hop[hop][:train_end],
            "selection": by_hop[hop][train_end:train_end + selection_quotas[hop]],
        }
        for split, candidates in selected.items():
            for _ordering, source_index, row, question in candidates:
                replay[split].append({
                    "hop": hop,
                    "id": row["id"],
                    "question_group_sha256": hashlib.sha256(question.encode()).hexdigest(),
                    "row_sha256": hashlib.sha256(json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest(),
                    "source_index": source_index,
                })
    assert replay == receipt["splits"]
    print(json.dumps({
        "receipt_sha256": hashlib.sha256(receipt_bytes).hexdigest(),
        "train_sha256": hashlib.sha256(train_bytes).hexdigest(),
        "dev_sha256": hashlib.sha256(dev_bytes).hexdigest(),
        "ordered_split_sha256": receipt["ordered_split_sha256"],
        "derivation_replayed": True,
    }, sort_keys=True))


def program_class(dspy, task_json=False):
    class Select(dspy.Signature):
        """Return exactly seven unique original paragraph indices, ranked by relevance."""

        question: str = dspy.InputField()
        paragraphs: list[dict] = dspy.InputField()
        ordered_paragraph_idxs: list[int] = dspy.OutputField()

    class Answer(dspy.Signature):
        """Answer and identify supporting positions within the selected paragraph list."""

        question: str = dspy.InputField()
        selected_paragraphs: list[dict] = dspy.InputField()
        answer: str = dspy.OutputField()
        support_positions: list[int] = dspy.OutputField()

    class Program(dspy.Module):
        def __init__(self):
            super().__init__()
            self.selector = dspy.Predict(Select)
            self.answerer = dspy.Predict(Answer)

        def forward(self, question, paragraphs):
            adapter_context = dspy.context(adapter=dspy.JSONAdapter()) if task_json else contextlib.nullcontext()
            with adapter_context:
                ranked = self.selector(question=question, paragraphs=paragraphs)
                by_idx = {paragraph["idx"]: paragraph for paragraph in paragraphs}
                indices = ranked.ordered_paragraph_idxs
                if len(indices) != 7 or len(set(indices)) != 7 or any(index not in by_idx for index in indices):
                    raise ValueError("selector must return exactly seven unique known paragraph indices")
                if any(type(index) is not int for index in indices):
                    raise ValueError("selector indices must be exact integers")
                selected_paragraphs = [by_idx[index] for index in indices]
                answered = self.answerer(question=question, selected_paragraphs=selected_paragraphs)
            if any(type(position) is not int for position in answered.support_positions):
                raise ValueError("support positions must be exact integers")
            if len(set(answered.support_positions)) != len(answered.support_positions) or any(
                position < 0 or position >= 7 for position in answered.support_positions
            ):
                raise ValueError("support positions must be unique values from 0 through 6")
            support_idxs = [selected_paragraphs[position]["idx"] for position in answered.support_positions]
            return dspy.Prediction(answer=answered.answer, support_idxs=support_idxs)

    return Program


def request_proof(dspy_root: Path, json_adapter=False):
    authenticate(dspy_root, DSPY_COMMIT)
    sys.path.insert(0, str(dspy_root))
    import dspy

    requests = []
    responses = [
        "[[ ## ordered_paragraph_idxs ## ]]\n[2, 0, 1, 3, 4, 5, 6]\n\n[[ ## completed ## ]]",
        "[[ ## answer ## ]]\nGamma\n\n[[ ## support_positions ## ]]\n[1, 2]\n\n[[ ## completed ## ]]",
    ]
    if json_adapter:
        responses = [json.dumps({"ordered_paragraph_idxs": [2, 0, 1, 3, 4, 5, 6]}),
                     json.dumps({"answer": "Gamma", "support_positions": [1, 2]})]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            requests.append({"path": self.path, "body": body})
            content = responses[len(requests) - 1]
            payload = {
                "id": f"musique-{len(requests)}",
                "object": "chat.completion",
                "model": body["model"],
                "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
            encoded = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        lm = dspy.LM(
            "openai/provider-disabled",
            api_key="provider-disabled",
            api_base=f"http://127.0.0.1:{server.server_port}/v1",
            cache=False,
            num_retries=0,
        )
        paragraphs = [
            {"idx": 0, "title": "Bridge", "text": "The winner was Gamma."},
            {"idx": 1, "title": "Final", "text": "Gamma received the prize."},
            {"idx": 2, "title": "Noise", "text": "Delta attended."},
        ] + [{"idx": index, "title": f"Noise {index}", "text": "Noise."} for index in range(3, 8)]
        with dspy.context(lm=lm, adapter=dspy.JSONAdapter() if json_adapter else dspy.ChatAdapter()):
            prediction = program_class(dspy)()(question="Who won?", paragraphs=paragraphs)
        for indices, positions in [([0, 0, 1, 2, 3, 4, 5], [0]), (list(range(7)), [0, 0])]:
            invalid = program_class(dspy)()
            invalid.selector.forward = lambda indices=indices, **_: dspy.Prediction(ordered_paragraph_idxs=indices)
            def invalid_answerer(**_):
                if len(set(indices)) != 7: raise RuntimeError("answerer invoked after invalid selector")
                return dspy.Prediction(answer="Gamma", support_positions=positions)
            invalid.answerer.forward = invalid_answerer
            try: invalid(question="Who won?", paragraphs=paragraphs)
            except ValueError: continue
            raise RuntimeError("invalid selector/support output accepted")
    finally:
        server.shutdown()
        thread.join(timeout=2)

    forbidden = ("answer_aliases", "is_supporting", "decomposition")
    rendered = json.dumps(requests)
    if len(requests) != 2 or any(value in rendered for value in forbidden):
        raise RuntimeError("DSPy MuSiQue request topology or information boundary drift")

    answerer_text = requests[1]["body"]["messages"][-1]["content"]
    answerer_input = ast.literal_eval(
        answerer_text.split("[[ ## selected_paragraphs ## ]]\n", 1)[1].split("\n\nRespond", 1)[0]
    )
    result = {
        "predictors": [name for name, _predictor in program_class(dspy)().named_predictors()],
        "prediction": {"answer": prediction.answer, "support_idxs": prediction.support_idxs},
        "answerer_input": answerer_input,
        "requests": requests,
    }
    print(json.dumps(result, sort_keys=True))


def reduced_rows(dspy):
    paragraphs = [
        {"idx": 0, "title": "Bridge", "text": "The winner was Gamma."},
        {"idx": 1, "title": "Final", "text": "Gamma received the prize."},
        {"idx": 2, "title": "Noise", "text": "Delta attended."},
        *[{"idx": index, "title": f"Noise {index}", "text": "Noise."} for index in range(3, 8)],
    ]
    return [
        dspy.Example(
            id=f"reduced-{index}", question=f"Who won reduced row {index}?",
            paragraphs=paragraphs, answer="Gamma", support_idxs=[0, 1]
        ).with_inputs("question", "paragraphs")
        for index in range(8)
    ]


def planted_task_lm(dspy):
    from dspy.dsp.utils.utils import dotdict

    class PlantedTaskLM(dspy.BaseLM):
        def __init__(self):
            super().__init__("provider-disabled-planted", "chat", 0.0, 1000, True)

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

        def __deepcopy__(self, _memo):
            return self

        def forward(self, prompt=None, messages=None, **_kwargs):
            rendered = json.dumps(messages or [{"role": "user", "content": prompt}])
            candidate = "candidate instruction" in rendered
            if "ordered_paragraph_idxs" in rendered:
                output = {
                    "ordered_paragraph_idxs":
                        [2, 0, 1, 3, 4, 5, 6] if candidate else [2, 3, 4, 5, 6, 7, 0]
                }
            else:
                output = (
                    {"answer": "Gamma", "support_positions": [1, 2]}
                    if candidate else {"answer": "Delta", "support_positions": []}
                )
            return dotdict(
                choices=[dotdict(
                    message=dotdict(content=json.dumps(output), tool_calls=None),
                    finish_reason="stop",
                )],
                usage=dotdict(prompt_tokens=0, completion_tokens=0, total_tokens=0),
                model="provider-disabled-planted",
            )

    return PlantedTaskLM()


def reduced_mipro_fresh(dspy_root: Path, state_path: Path):
    authenticate(dspy_root, DSPY_COMMIT)
    sys.path.insert(0, str(dspy_root))
    import dspy

    selected = program_class(dspy, task_json=True)()
    selected.load(state_path, allow_pickle=False, allow_unsafe_lm_state=False)
    lm = planted_task_lm(dspy)
    for _name, predictor in selected.named_predictors():
        predictor.lm = lm
    rows = reduced_rows(dspy)
    predictions = [selected(**rows[index].inputs()) for index in range(4)]
    print(json.dumps({
        "fresh_predictions": [
            {"answer": prediction.answer, "support_idxs": prediction.support_idxs}
            for prediction in predictions
        ]
    }, sort_keys=True))


def reduced_mipro_readiness(dspy_root: Path):
    authenticate(dspy_root, DSPY_COMMIT)
    sys.path.insert(0, str(dspy_root))
    import dspy
    from dspy.utils.dummies import DummyLM

    class SharedDummyLM(DummyLM):
        def __deepcopy__(self, _memo):
            return self

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

    rows = reduced_rows(dspy)
    prompt_lm = SharedDummyLM([
        {"observations": "Every row asks for Gamma and supporting paragraphs."},
        {"summary": "Find Gamma and its support."},
        *[{"proposed_instruction": "candidate instruction"} for _ in range(6)],
    ])
    task_lm = planted_task_lm(dspy)

    def metric(gold, prediction, _trace=None):
        answer = 1.0 if prediction.answer == gold.answer else 0.0
        support = 1.0 if prediction.support_idxs == gold.support_idxs else 0.0
        return (answer + support) / 2

    optimizer = dspy.MIPROv2(
        metric=metric, prompt_model=prompt_lm, task_model=task_lm, auto=None,
        num_candidates=3, max_bootstrapped_demos=0, max_labeled_demos=0,
        num_threads=1, max_errors=10, seed=9, track_stats=True,
    )
    with open('/dev/null', 'w') as sink:
        import contextlib
        with contextlib.redirect_stdout(sink):
            candidate = optimizer.compile(
                program_class(dspy, task_json=True)(), trainset=rows[:4], valset=rows[4:6],
                num_trials=11, max_bootstrapped_demos=0, max_labeled_demos=0,
                seed=9, minibatch=True, minibatch_size=1,
                minibatch_full_eval_steps=5, program_aware_proposer=False,
                data_aware_proposer=True, tip_aware_proposer=True,
                fewshot_aware_proposer=False, view_data_batch_size=10,
            )

    baseline = program_class(dspy, task_json=True)()

    def outer_score(program):
        lm = planted_task_lm(dspy)
        for _name, predictor in program.named_predictors():
            predictor.lm = lm
        return sum(metric(row, program(**row.inputs())) for row in rows[4:6]) / 2

    baseline_score = outer_score(baseline)
    candidate_score = outer_score(candidate)
    selected = candidate if candidate_score > baseline_score else baseline
    selected_kind = "optimized" if selected is candidate else "baseline"

    with tempfile.TemporaryDirectory(prefix="musique-upstream-reduced-") as temp:
        state_path = Path(temp) / "selected.json"
        selected_instructions = {
            name: predictor.signature.instructions
            for name, predictor in selected.named_predictors()
        }
        for _name, predictor in selected.named_predictors():
            predictor.lm = None
        selected.save(state_path, save_program=False)
        state_sha = hashlib.sha256(state_path.read_bytes()).hexdigest()
        fresh = subprocess.check_output([
            sys.executable, str(Path(__file__).resolve()), "--mipro-fresh",
            "--dspy-root", str(dspy_root), "--state", str(state_path),
        ], text=True, env={**dict(__import__('os').environ), "PYTHONPATH": str(dspy_root)})
        fresh_result = json.loads(fresh.splitlines()[-1])

    print(json.dumps({
        "dspy_commit": DSPY_COMMIT,
        "reduced_execution": True,
        "full_opportunity_claimed": False,
        "requested_objective_trials": 11,
        "adjusted_log_slots": 15,
        "inserted_full_evaluations": 3,
        "minibatch_size": 1,
        "baseline_selection": baseline_score,
        "optimized_selection": candidate_score,
        "selected": selected_kind,
        "selected_instructions": selected_instructions,
        "strict_baseline_on_tie": True,
        "state_sha256": state_sha,
        **fresh_result,
    }, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--musique-root", type=Path)
    parser.add_argument("--dspy-root", type=Path)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--data-root", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--state", type=Path)
    parser.add_argument("--score-lines", action="store_true")
    parser.add_argument("--request-proof", action="store_true")
    parser.add_argument("--json-request-proof", action="store_true")
    parser.add_argument("--verify-receipt", action="store_true")
    parser.add_argument("--mipro-readiness", action="store_true")
    parser.add_argument("--mipro-fresh", action="store_true")
    args = parser.parse_args()
    if args.score_lines:
        score_lines(args.musique_root, args.input)
    elif args.request_proof:
        request_proof(args.dspy_root)
    elif args.json_request_proof:
        request_proof(args.dspy_root, json_adapter=True)
    elif args.verify_receipt:
        verify_receipt(args.data_root, args.receipt)
    elif args.mipro_readiness:
        reduced_mipro_readiness(args.dspy_root)
    elif args.mipro_fresh:
        reduced_mipro_fresh(args.dspy_root, args.state)
    else:
        parser.error("choose a provider-free probe")


if __name__ == "__main__":
    main()
