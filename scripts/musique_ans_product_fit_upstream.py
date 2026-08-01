#!/usr/bin/env python3
"""Pinned MuSiQue scorer and DSPy 3.2.1 product-fit probes; never calls a provider."""

from __future__ import annotations

import argparse
import ast
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading

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


def program_class(dspy):
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


def request_proof(dspy_root: Path):
    authenticate(dspy_root, DSPY_COMMIT)
    sys.path.insert(0, str(dspy_root))
    import dspy

    requests = []
    responses = [
        "[[ ## ordered_paragraph_idxs ## ]]\n[2, 0, 1, 3, 4, 5, 6]\n\n[[ ## completed ## ]]",
        "[[ ## answer ## ]]\nGamma\n\n[[ ## support_positions ## ]]\n[1, 2]\n\n[[ ## completed ## ]]",
    ]

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
        with dspy.context(lm=lm, adapter=dspy.ChatAdapter()):
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--musique-root", type=Path)
    parser.add_argument("--dspy-root", type=Path)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--score-lines", action="store_true")
    parser.add_argument("--request-proof", action="store_true")
    args = parser.parse_args()
    if args.score_lines:
        score_lines(args.musique_root, args.input)
    elif args.request_proof:
        request_proof(args.dspy_root)
    else:
        parser.error("choose --score-lines or --request-proof")


if __name__ == "__main__":
    main()
