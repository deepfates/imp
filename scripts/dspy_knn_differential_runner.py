#!/usr/bin/env python3
"""Run real DSPy 3.2.1 KNN / KNNFewShot over a deterministic embedder and print
the selection/demo projections the Elixir side (test/knn_dspy_differential_test.exs)
compares against. Provider-free: the LM is a canned fixture, and the embedder is
a marker-count function both languages implement identically."""

from __future__ import annotations

import contextlib
import json
import sys
from dataclasses import dataclass
from types import SimpleNamespace

import dspy

MARKERS = ["alpha", "beta", "gamma", "delta"]

TRAINSET = [
    ("alpha alpha alpha", "4"),
    ("beta beta", "5"),
    ("gamma", "4"),
]

QUERIES = ["alpha beta", "gamma beta"]


def embed(texts):
    return [[float(text.count(marker)) for marker in MARKERS] for text in texts]


@dataclass
class FakeResponse:
    choices: list
    usage: dict
    model: str
    _hidden_params: dict


class CannedLM(dspy.BaseLM):
    """Always answers `4` in chat-adapter form; records history like any LM."""

    def __init__(self) -> None:
        super().__init__(model="fake/knn-differential", cache=False)

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        content = "[[ ## answer ## ]]\n4\n\n[[ ## completed ## ]]"
        return FakeResponse(
            choices=[SimpleNamespace(message=SimpleNamespace(content=content))],
            usage={},
            model=self.model,
            _hidden_params={},
        )


def build_trainset():
    return [
        dspy.Example(question=question, answer=answer).with_inputs("question")
        for question, answer in TRAINSET
    ]


def metric(example, prediction, trace=None):  # noqa: ANN001
    return prediction.answer == example.answer


def knn_selections(trainset):
    knn = dspy.KNN(k=2, trainset=trainset, vectorizer=dspy.Embedder(embed))
    return {query: [ex.question for ex in knn(question=query)] for query in QUERIES}


def knn_few_shot_demo_presence(trainset):
    lm = CannedLM()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter())

    optimizer = dspy.KNNFewShot(
        k=2,
        trainset=trainset,
        vectorizer=dspy.Embedder(embed),
        metric=metric,
        max_bootstrapped_demos=2,
        max_labeled_demos=0,
    )
    compiled = optimizer.compile(dspy.Predict("question -> answer"))

    presence = {}
    for query in QUERIES:
        history_start = len(lm.history)
        compiled(question=query)
        final_messages = lm.history[-1]["messages"]
        # Which trainset questions appear as DEMO turns: user messages other
        # than the final (main-request) one.
        demo_user_contents = [
            message["content"]
            for message in final_messages[:-1]
            if message["role"] == "user"
        ]
        presence[query] = {
            question: any(question in content for content in demo_user_contents)
            for question, _answer in TRAINSET
        }
        assert len(lm.history) > history_start, "expected LM calls per forward"
    return presence


def main() -> int:
    # Keep stdout pure JSON: DSPy's bootstrap prints progress ("Bootstrapped N
    # full traces ...") straight to stdout, which would corrupt the
    # machine-read report — run the computation with stdout redirected.
    dspy.disable_logging()
    trainset = build_trainset()
    with contextlib.redirect_stdout(sys.stderr):
        report = {
            "dspy_version": getattr(dspy, "__version__", "unknown"),
            "knn_selections": knn_selections(trainset),
            "knn_few_shot_demo_presence": knn_few_shot_demo_presence(trainset),
        }
    print(json.dumps(report, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
