#!/usr/bin/env python3
"""Pinned DSPy provider-free lifecycle for the current HoVer GEPA candidate.

This repository-only entry proves the ordinary DSPy 3.2.1 -> GEPA 0.1.4
compile boundary, serial ordered evaluation, strict candidate selection, and
fresh program reload.  It is a compact mechanics fixture, not HoVer evidence
and never loads validation/test data or calls a provider.
"""

from __future__ import annotations

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

from dspy_gepa_version_bridge import authenticate_loaded_runtime, install_source_bridge


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def secure_write(path: Path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(canonical(value) + "\n")


def build_runtime(dspy_root: Path, gepa_root: Path):
    bridge = install_source_bridge(dspy_root, gepa_root)
    import dspy
    import gepa

    authenticate_loaded_runtime(bridge, dspy, gepa)
    return dspy, gepa


def lifecycle(dspy, output_root: Path, seed: int, dspy_root: Path, gepa_root: Path):
    class Summarize1(dspy.Signature):
        """Summarize evidence that matters to the claim."""

        claim = dspy.InputField()
        passages = dspy.InputField()
        summary = dspy.OutputField()

    class Query2(dspy.Signature):
        """Create the second retrieval query."""

        claim = dspy.InputField()
        context = dspy.InputField()
        query = dspy.OutputField()

    class Summarize2(dspy.Signature):
        """Summarize the second-hop evidence."""

        claim = dspy.InputField()
        context = dspy.InputField()
        passages = dspy.InputField()
        summary = dspy.OutputField()

    class Query3(dspy.Signature):
        """Create the final retrieval query."""

        claim = dspy.InputField()
        context = dspy.InputField()
        query = dspy.OutputField()

    class SharedDummyLM(dspy.utils.DummyLM):
        def __deepcopy__(self, memo):
            memo[id(self)] = self
            return self

    class CompactHover(dspy.Module):
        def __init__(self, lm):
            super().__init__()
            self.summarize1 = dspy.Predict(Summarize1)
            self.create_query_hop2 = dspy.Predict(Query2)
            self.summarize2 = dspy.Predict(Summarize2)
            self.create_query_hop3 = dspy.Predict(Query3)
            self.set_lm(lm)

        def forward(self, claim):
            first = self.summarize1(claim=claim, passages=["Alpha | evidence"])
            second_query = self.create_query_hop2(claim=claim, context=[first.summary])
            second = self.summarize2(
                claim=claim,
                context=[first.summary],
                passages=[f"{second_query.query} | evidence"],
            )
            third_query = self.create_query_hop3(
                claim=claim, context=[first.summary, second.summary]
            )
            instructions = [
                predictor.signature.instructions
                for _name, predictor in self.named_predictors()
            ]
            return dspy.Prediction(
                retrieved_docs=[first.summary, second_query.query, second.summary, third_query.query],
                quality=sum("Improved." in item for item in instructions) / 5.0,
            )

    answers = [
        value
        for _ in range(600)
        for value in (
            {"summary": "Gamma1"},
            {"query": "Gamma2"},
            {"summary": "Gamma3"},
            {"query": "Gamma4"},
        )
    ]
    task_lm = SharedDummyLM(answers)
    program = CompactHover(task_lm)
    rows = [
        dspy.Example(id=f"row-{index}", claim=f"Alpha relation {index}").with_inputs("claim")
        for index in range(4)
    ]
    proposals = []

    def metric(gold, pred, trace=None, pred_name=None, pred_trace=None):
        row_offset = int(str(gold.id).rsplit("-", 1)[1]) / 1000.0
        score = float(pred.quality) + row_offset
        if pred_name is not None:
            return dspy.Prediction(score=score, feedback=f"improve {pred_name}")
        return score

    def proposer(candidate, reflective_dataset, components_to_update):
        del reflective_dataset
        call = len(proposals) + 1
        proposals.append(list(components_to_update))
        suffix = "Improved." if call <= 4 else "Worse."
        return {name: candidate[name] + " " + suffix for name in components_to_update}

    optimizer = dspy.GEPA(
        metric=metric,
        max_metric_calls=50,
        reflection_minibatch_size=3,
        instruction_proposer=proposer,
        component_selector="round_robin",
        use_merge=False,
        num_threads=1,
        failure_score=0.0,
        track_stats=True,
        seed=seed,
        gepa_kwargs={"acceptance_criterion": "strict_improvement"},
    )
    selected = optimizer.compile(program, trainset=rows, valset=rows)
    detail = selected.detailed_results
    selected_state = {
        name: predictor.signature.instructions
        for name, predictor in selected.named_predictors()
    }
    baseline_state = {
        name: predictor.signature.instructions
        for name, predictor in program.named_predictors()
    }
    baseline_score = sum("Improved." in value for value in baseline_state.values()) / 5.0
    selected_score = sum("Improved." in value for value in selected_state.values()) / 5.0

    artifact = output_root / f"dspy-selected-{seed}.json"
    output_root.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output_root, 0o700)
    selected.set_lm(None)
    selected.save(artifact)
    os.chmod(artifact, 0o600)

    fresh_receipt = output_root / f"dspy-fresh-{seed}.json"
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--fresh",
        str(artifact),
        "--receipt",
        str(fresh_receipt),
        "--dspy-root",
        str(dspy_root),
        "--gepa-root",
        str(gepa_root),
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    fresh = json.loads(completed.stdout)

    result = {
        "status": "provider_disabled_lifecycle_pass",
        "seed": seed,
        "num_threads": optimizer.num_threads,
        "result_order": "source_row_order",
        "ordered_val_source_ids": [row.id for row in rows],
        "baseline_val_subscores": [detail.val_subscores[0][index] for index in range(len(rows))],
        "selected_val_subscores": [
            detail.val_subscores[detail.best_idx][index] for index in range(len(rows))
        ],
        "use_merge": optimizer.use_merge,
        "proposal_components": [items[0] for items in proposals],
        "candidate_count": len(detail.candidates),
        "total_metric_calls": detail.total_metric_calls,
        "baseline_score": baseline_score,
        "selected_score": selected_score,
        "strictly_selected": selected_score > baseline_score,
        "selected_instructions": selected_state,
        "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
        "fresh": fresh,
    }
    secure_write(output_root / f"dspy-result-{seed}.json", result)
    return result


def fresh(dspy, artifact: Path, receipt: Path):
    # Reconstruct the trusted program vocabulary before loading untrusted state.
    class Stage(dspy.Signature):
        """Placeholder overwritten by the selected artifact."""

        claim = dspy.InputField()
        answer = dspy.OutputField()

    class Program(dspy.Module):
        def __init__(self):
            super().__init__()
            # DSPy load requires the exact predictor paths. Signatures are replaced.
            self.summarize1 = dspy.Predict(Stage)
            self.create_query_hop2 = dspy.Predict(Stage)
            self.summarize2 = dspy.Predict(Stage)
            self.create_query_hop3 = dspy.Predict(Stage)

    program = Program()
    program.load(artifact)
    state = {
        name: predictor.signature.instructions
        for name, predictor in program.named_predictors()
    }
    value = {
        "loaded": True,
        "predictor_order": [name for name, _predictor in program.named_predictors()],
        "selected_instructions": state,
    }
    secure_write(receipt, value)
    print(canonical(value))


def serializer_proof(dspy):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *_args):
            return

        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            body = json.loads(self.rfile.read(length))
            requests.append(
                {
                    "path": self.path,
                    "headers": {key.lower(): value for key, value in self.headers.items()},
                    "body": body,
                }
            )
            response = {
                "id": f"provider-disabled-{len(requests)}",
                "object": "chat.completion",
                "model": body["model"],
                "provider": "provider-disabled",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "provider-disabled"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 1,
                    "completion_tokens": 1,
                    "total_tokens": 2,
                },
            }
            encoded = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    routes = {
        "task": {
            "model": "deepseek/deepseek-v4-flash-0731",
            "endpoint": "siliconflow/fp8",
            "max_tokens": 2048,
            "max_input_bytes": 131072,
            "max_price": {"prompt": 0.14, "completion": 0.28},
            "options": {"temperature": 1.0, "top_p": 1.0},
            "reasoning": {"effort": "none"},
        },
        "reflection": {
            "model": "anthropic/claude-sonnet-5",
            "endpoint": "google-vertex/global",
            "max_tokens": 8192,
            "max_input_bytes": 655360,
            "max_price": {"prompt": 2.0, "completion": 10.0},
            "options": {},
            "reasoning": {"effort": "high"},
        },
    }
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base_url = f"http://127.0.0.1:{server.server_port}/api/v1"
        for role, route in routes.items():
            provider = {
                "only": [route["endpoint"]],
                "order": [route["endpoint"]],
                "allow_fallbacks": False,
                "require_parameters": True,
                "data_collection": "deny",
                "zdr": True,
                "max_price": route["max_price"],
            }
            lm = dspy.LM(
                "openrouter/" + route["model"],
                api_key="provider-disabled",
                api_base=base_url,
                cache=False,
                num_retries=0,
                max_tokens=route["max_tokens"],
                extra_body={
                    "provider": provider,
                    "usage": {"include": True},
                    "reasoning": route["reasoning"],
                },
                extra_headers={
                    "X-OpenRouter-Metadata": "enabled",
                    "X-OpenRouter-Cache": "false",
                },
                **route["options"],
            )
            lm(messages=[{"role": "user", "content": f"provider-disabled {role} serializer assertion"}])
    finally:
        server.shutdown()
        thread.join(timeout=2)

    if len(requests) != 2:
        raise RuntimeError("DSPy serializer proof did not produce exactly two requests")

    result = {}
    for request, (role, route) in zip(requests, routes.items(), strict=True):
        body = request["body"]
        headers = request["headers"]
        messages = canonical(body["messages"]).encode()
        expected_provider = {
            "only": [route["endpoint"]],
            "order": [route["endpoint"]],
            "allow_fallbacks": False,
            "require_parameters": True,
            "data_collection": "deny",
            "zdr": True,
            "max_price": route["max_price"],
        }
        if (
            request["path"] != "/api/v1/chat/completions"
            or body.get("model") != route["model"]
            or body.get("max_tokens") != route["max_tokens"]
            or body.get("provider") != expected_provider
            or body.get("usage") != {"include": True}
            or headers.get("x-openrouter-metadata") != "enabled"
            or headers.get("x-openrouter-cache") != "false"
            or len(messages) > route["max_input_bytes"]
        ):
            raise RuntimeError(f"DSPy {role} serialized route/guard drift")
        if role == "task":
            if (
                body.get("temperature") != 1.0
                or body.get("top_p") != 1.0
                or body.get("reasoning") != {"effort": "none"}
                or "reasoning_effort" in body
            ):
                raise RuntimeError("DSPy task generation policy drift")
        elif (
            body.get("reasoning") != {"effort": "high"}
            or "reasoning_effort" in body
            or "temperature" in body
            or "verbosity" in body
            or "top_p" in body
        ):
            raise RuntimeError("DSPy reflection generation policy drift")
        result[role] = {
            "body": body,
            "headers": {
                "x-openrouter-metadata": headers["x-openrouter-metadata"],
                "x-openrouter-cache": headers["x-openrouter-cache"],
            },
            "rendered_messages_bytes": len(messages),
            "rendered_messages_sha256": hashlib.sha256(messages).hexdigest(),
            "max_input_bytes": route["max_input_bytes"],
        }
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--seed", type=int, default=2026080201)
    parser.add_argument("--fresh", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--serializer-proof", action="store_true")
    args = parser.parse_args()
    dspy, _gepa = build_runtime(args.dspy_root.resolve(), args.gepa_root.resolve())
    if args.fresh:
        if args.receipt is None:
            raise RuntimeError("--fresh requires --receipt")
        fresh(dspy, args.fresh.resolve(), args.receipt.resolve())
        return
    if args.serializer_proof:
        print(canonical(serializer_proof(dspy)))
        return
    if args.output_root is None:
        raise RuntimeError("--output-root is required")
    print(
        canonical(
            lifecycle(
                dspy,
                args.output_root.resolve(),
                args.seed,
                args.dspy_root.resolve(),
                args.gepa_root.resolve(),
            )
        )
    )


if __name__ == "__main__":
    main()
