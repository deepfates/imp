#!/usr/bin/env python3
"""Provider-free equivalence gate for the stock-DSPy IFBench translation."""

from __future__ import annotations

import argparse
import copy
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import random
import subprocess
import sys
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
IMP_ROOT = HERE.parents[1]
SYNTHETIC_PROMPT = "Return exactly the token BLUE."
ANSWERS = [
    {"reasoning": "draft rationale", "response": "DRAFT"},
    {"reasoning": "review rationale", "final_response": "FINAL"},
]


def canonical(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def git_head(path: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def git_clean(path: Path) -> bool:
    return (
        subprocess.check_output(
            ["git", "-C", str(path), "status", "--porcelain", "--untracked-files=all"],
            text=True,
        ).strip()
        == ""
    )


def install_runtime(args: argparse.Namespace):
    sys.path.insert(0, str(IMP_ROOT / "scripts"))
    from dspy_gepa_version_bridge import (
        authenticate_loaded_runtime,
        install_source_bridge,
    )

    bridge = install_source_bridge(args.dspy_root, args.gepa_root)
    sys.path.insert(0, str(args.ifbench_site_packages))
    from ifbench_upstream_eval import (
        install_optional_import_stubs,
        install_spacy_stub_if_needed,
    )

    install_spacy_stub_if_needed()
    install_optional_import_stubs()
    sys.path.insert(0, str(args.gepa_artifact_root))
    sys.path.insert(0, str(HERE))

    import dspy
    import gepa
    import numpy as np
    from dspy.utils.dummies import DummyLM
    from gepa_artifact.benchmarks.IFBench.ifbench_program import IFBenchCoT2StageProgram
    from ifbench_stock_module import IFBenchCoT2StageModule

    authenticate_loaded_runtime(bridge, dspy, gepa)

    class ProbeDummyLM(DummyLM):
        """Deterministic in-process adapter fixture; never dispatches a transport."""

        def __init__(self):
            super().__init__(copy.deepcopy(ANSWERS))
            self.caller_stacks: list[list[str]] = []

        def forward(self, prompt=None, messages=None, **kwargs):
            self.caller_stacks.append(
                [
                    f"{module.__class__.__module__}.{module.__class__.__qualname__}"
                    for module in (dspy.settings.caller_modules or [])
                ]
            )
            return super().forward(prompt=prompt, messages=messages, **kwargs)

    return dspy, np, ProbeDummyLM, IFBenchCoT2StageProgram, IFBenchCoT2StageModule


def field_surface(field: Any) -> dict[str, Any]:
    return {
        "annotation": str(field.annotation),
        "default": repr(field.default),
        "json_schema_extra": copy.deepcopy(field.json_schema_extra),
    }


def predictor_surface(program: Any) -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "predictor_class": f"{predictor.__class__.__module__}.{predictor.__class__.__qualname__}",
            "signature_name": predictor.signature.__name__,
            "instructions": predictor.signature.instructions,
            "input_fields": list(predictor.signature.input_fields),
            "output_fields": list(predictor.signature.output_fields),
            "fields": [
                {"name": field_name, **field_surface(field)}
                for field_name, field in predictor.signature.fields.items()
            ],
            "demos": [example.toDict() for example in predictor.demos],
            "config": copy.deepcopy(predictor.config),
            "lm": None if predictor.lm is None else repr(predictor.lm),
        }
        for name, predictor in program.named_predictors()
    ]


def trace_surface(program: Any, trace: list[Any]) -> list[dict[str, Any]]:
    names = {id(predictor): name for name, predictor in program.named_predictors()}
    return [
        {
            "predictor": names[id(predictor)],
            "inputs": copy.deepcopy(inputs),
            "output": output.toDict(),
        }
        for predictor, inputs, output in trace
    ]


def run_program(
    dspy: Any,
    np: Any,
    dummy_cls: Any,
    program: Any,
    prompt: str,
    *,
    callbacks: list[Any] | None = None,
    track_usage: bool = False,
) -> dict[str, Any]:
    lm = dummy_cls()
    dspy.configure(
        lm=lm,
        adapter=dspy.ChatAdapter(),
        callbacks=callbacks or [],
        track_usage=track_usage,
    )
    program.set_lm(lm)
    python_rng_before = random.getstate()
    numpy_rng_before = np.random.get_state()
    with dspy.context(trace=[]):
        prediction = program(prompt=prompt)
        trace = dspy.settings.trace.copy()
    python_rng_after = random.getstate()
    numpy_rng_after = np.random.get_state()
    return {
        "output": prediction.toDict(),
        "messages": [copy.deepcopy(entry["messages"]) for entry in lm.history],
        "trace": trace_surface(program, trace),
        "caller_stacks": lm.caller_stacks,
        "python_rng_unchanged": python_rng_before == python_rng_after,
        "numpy_rng_unchanged": all(
            (left == right).all() if hasattr(left, "all") else left == right
            for left, right in zip(numpy_rng_before, numpy_rng_after, strict=True)
        ),
        "dummy_calls": len(lm.history),
        "lm_usage": prediction.get_lm_usage(),
    }


def load_rows(contract: dict[str, Any]) -> list[dict[str, Any]]:
    rows = [{"source_id": "synthetic", "prompt": SYNTHETIC_PROMPT}]
    for key in ("train_path", "selection_path"):
        path = (HERE / contract["dataset"][key]).resolve()
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                row = json.loads(line)
                rows.append({"source_id": row["source_id"], "prompt": row["prompt"]})
    return rows


def mutate_instruction(program: Any, target: str, instruction: str) -> None:
    matched = False
    for name, predictor in program.named_predictors():
        if name == target:
            predictor.signature = predictor.signature.with_instructions(instruction)
            matched = True
    require(matched, f"missing mutation target {target}")


def mutation_gate(
    dspy: Any, np: Any, dummy_cls: Any, exact_cls: Any, translated_cls: Any
) -> list[dict[str, Any]]:
    results = []
    names = [name for name, _ in exact_cls().named_predictors()]
    for index, target in enumerate(names):
        exact_original = exact_cls()
        translated_original = translated_cls()
        exact_copy = exact_original.deepcopy()
        translated_copy = translated_original.deepcopy()
        original_exact_state = exact_original.dump_state()
        original_translated_state = translated_original.dump_state()
        before = predictor_surface(exact_copy)
        instruction = f"Mutation locality probe for {target}."
        mutate_instruction(exact_copy, target, instruction)
        mutate_instruction(translated_copy, target, instruction)
        after_exact = predictor_surface(exact_copy)
        after_translated = predictor_surface(translated_copy)
        require(
            after_exact == after_translated,
            f"translated mutation state drift for {target}",
        )
        require(
            exact_original.dump_state() == original_exact_state,
            f"exact deepcopy aliased original for {target}",
        )
        require(
            translated_original.dump_state() == original_translated_state,
            f"translated deepcopy aliased original for {target}",
        )
        changed = [
            surface["name"]
            for surface, prior in zip(after_exact, before, strict=True)
            if surface != prior
        ]
        require(changed == [target], f"mutation escaped target {target}: {changed!r}")

        exact_run = run_program(dspy, np, dummy_cls, exact_copy, SYNTHETIC_PROMPT)
        translated_run = run_program(
            dspy, np, dummy_cls, translated_copy, SYNTHETIC_PROMPT
        )
        require(
            exact_run["messages"] == translated_run["messages"],
            f"mutated messages drift for {target}",
        )
        require(
            exact_run["output"] == translated_run["output"],
            f"mutated output drift for {target}",
        )
        baseline = run_program(dspy, np, dummy_cls, exact_cls(), SYNTHETIC_PROMPT)
        changed_stages = [
            stage
            for stage, (current, original) in enumerate(
                zip(exact_run["messages"], baseline["messages"], strict=True)
            )
            if current != original
        ]
        require(
            changed_stages == [index],
            f"mutation changed wrong message stages for {target}: {changed_stages!r}",
        )
        results.append(
            {
                "target": target,
                "changed_predictors": changed,
                "changed_message_stages": changed_stages,
            }
        )
    return results


def bootstrap_gate(dspy: Any, dummy_cls: Any, translated_cls: Any) -> dict[str, Any]:
    from dspy.teleprompt.bootstrap_trace import bootstrap_trace_data

    metric_inputs: list[dict[str, Any]] = []

    def metric(example, prediction, trace=None):
        metric_inputs.append(
            {
                "example": example.toDict(),
                "prediction": prediction.toDict(),
                "trace": trace,
            }
        )
        return 1.0

    lm = dummy_cls()
    dspy.configure(lm=lm, adapter=dspy.ChatAdapter(), track_usage=False)
    program = translated_cls()
    program.set_lm(lm)
    example = dspy.Example(prompt=SYNTHETIC_PROMPT).with_inputs("prompt")
    with contextlib.redirect_stdout(io.StringIO()):
        rows = bootstrap_trace_data(program, [example], metric=metric, num_threads=1)
    require(len(rows) == 1, "stock bootstrap did not return one row")
    trace = trace_surface(program, rows[0]["trace"])
    require(
        [entry["predictor"] for entry in trace]
        == [
            "generate_response_module.predict",
            "ensure_correct_response_module.predict",
        ],
        "stock bootstrap trace order drift",
    )
    require(len(metric_inputs) == 1, "metric did not receive exactly one invocation")
    require(
        metric_inputs[0]["example"] == example.toDict(),
        "top-level instrumentation changed metric example",
    )
    require(
        metric_inputs[0]["prediction"] == {"response": "FINAL"},
        "top-level instrumentation changed metric prediction",
    )
    require(
        metric_inputs[0]["trace"] is None,
        "top-level instrumentation injected metric trace metadata",
    )
    return {
        "rows": len(rows),
        "trace": trace,
        "metric_inputs": metric_inputs,
        "dummy_calls": len(lm.history),
    }


def instrumentation_gate(
    dspy: Any, np: Any, dummy_cls: Any, exact_cls: Any, translated_cls: Any
) -> dict[str, Any]:
    from dspy.utils.callback import BaseCallback

    class Observer(BaseCallback):
        def __init__(self):
            self.starts: list[dict[str, Any]] = []
            self.ends = 0

        def on_module_start(self, call_id, instance, inputs):
            self.starts.append(
                {
                    "class": f"{instance.__class__.__module__}.{instance.__class__.__qualname__}",
                    "inputs": copy.deepcopy(inputs),
                }
            )

        def on_module_end(self, call_id, outputs, exception):
            self.ends += 1

    exact_observer = Observer()
    translated_observer = Observer()
    exact = run_program(
        dspy,
        np,
        dummy_cls,
        exact_cls(),
        SYNTHETIC_PROMPT,
        callbacks=[exact_observer],
        track_usage=True,
    )
    translated = run_program(
        dspy,
        np,
        dummy_cls,
        translated_cls(),
        SYNTHETIC_PROMPT,
        callbacks=[translated_observer],
        track_usage=True,
    )
    require(
        exact["messages"] == translated["messages"],
        "callback/usage instrumentation changed task messages",
    )
    require(
        exact["output"] == translated["output"],
        "callback/usage instrumentation changed task output",
    )
    require(
        exact["dummy_calls"] == translated["dummy_calls"] == 2,
        "instrumentation changed call opportunity",
    )
    translated_top = [
        event
        for event in translated_observer.starts
        if event["class"].endswith("ifbench_stock_module.IFBenchCoT2StageModule")
    ]
    require(len(translated_top) == 1, "translated top-level callback count drift")
    require(
        translated_top[0]["inputs"]
        == {"args": (), "kwargs": {"prompt": SYNTHETIC_PROMPT}},
        f"top-level callback input differs from public task input: {translated_top[0]['inputs']!r}",
    )
    require(
        len(translated_observer.starts) == len(exact_observer.starts) + 1,
        "stock top-level callback was not the sole callback delta",
    )
    require(
        translated_observer.ends == exact_observer.ends + 1,
        "stock top-level callback end was not the sole callback delta",
    )
    return {
        "messages_unchanged": True,
        "outputs_unchanged": True,
        "call_opportunity_unchanged": True,
        "exact_module_callbacks": len(exact_observer.starts),
        "translated_module_callbacks": len(translated_observer.starts),
        "callback_delta": 1,
        "exact_lm_usage": exact["lm_usage"],
        "translated_lm_usage": translated["lm_usage"],
    }


def source_gate(args: argparse.Namespace, contract: dict[str, Any]) -> dict[str, Any]:
    sources = contract["compatibility_translation"]["sources"]
    require(
        git_head(args.gepa_artifact_root) == sources["artifact_commit"],
        "artifact commit drift",
    )
    require(
        git_head(args.dspy_root) == sources["stock_dspy_commit"],
        "stock DSPy commit drift",
    )
    require(
        git_head(args.gepa_root) == contract["authorities"]["gepa"]["commit"],
        "GEPA 0.1.4 commit drift",
    )
    artifact_program = args.gepa_artifact_root / sources["artifact_program_path"]
    require(
        sha256_file(artifact_program) == sources["artifact_program_sha256"],
        "artifact program source drift",
    )
    setup = args.gepa_artifact_root / sources["artifact_setup_path"]
    require(
        sha256_file(setup) == sources["artifact_setup_sha256"],
        "artifact setup source drift",
    )
    scorer = args.gepa_artifact_root / sources["artifact_scorer_path"]
    require(
        sha256_file(scorer) == sources["artifact_scorer_sha256"],
        "artifact scorer source drift",
    )
    translation = HERE / contract["compatibility_translation"]["translation_path"]
    require(
        sha256_file(translation)
        == contract["compatibility_translation"]["translation_sha256"],
        "translation source drift",
    )
    runner = HERE / contract["compatibility_translation"]["runner_path"]
    require(
        sha256_file(runner) == contract["compatibility_translation"]["runner_sha256"],
        "successor runner source drift",
    )
    require(
        git_head(args.modified_dspy_root) == sources["modified_dspy_fork_commit"],
        "modified DSPy fork commit drift",
    )
    fork_trace = args.modified_dspy_root / sources["modified_dspy_trace_path"]
    require(
        sha256_file(fork_trace) == sources["modified_dspy_trace_sha256"],
        "modified DSPy fork GEPA trace source drift",
    )
    return {
        "artifact_commit": sources["artifact_commit"],
        "stock_dspy_commit": sources["stock_dspy_commit"],
        "modified_dspy_fork_commit": sources["modified_dspy_fork_commit"],
        "modified_dspy_verified_locally": True,
        "translation_sha256": contract["compatibility_translation"][
            "translation_sha256"
        ],
        "scorer_sha256": sources["artifact_scorer_sha256"],
    }


def data_gate(contract: dict[str, Any]) -> dict[str, Any]:
    result = {}
    for name in ("receipt", "train", "selection"):
        path = (HERE / contract["dataset"][f"{name}_path"]).resolve()
        actual = sha256_file(path)
        expected = contract["dataset"][f"{name}_sha256"]
        require(actual == expected, f"{name} data digest drift")
        result[name] = actual
    result["held_out"] = {
        "status": "sealed_digest_retained_not_read_preselection",
        "sha256": contract["dataset"]["held_out_sha256"],
    }
    return result


def treatment_preservation_gate(contract: dict[str, Any]) -> dict[str, Any]:
    predecessor = contract["immutable_predecessors"]["v3"]
    v3_path = (HERE / predecessor["contract_path"]).resolve()
    require(
        sha256_file(v3_path) == predecessor["contract_sha256"],
        "terminal v3 contract drift",
    )
    execution_base = (HERE / contract["execution_base"]["runner_path"]).resolve()
    require(
        sha256_file(execution_base) == contract["execution_base"]["runner_sha256"],
        "content-bound execution base drift",
    )
    v3 = json.loads(v3_path.read_text(encoding="utf-8"))
    for key in (
        "dataset",
        "models",
        "seeds",
        "arms",
        "optimizer",
        "execution",
        "output_contract",
        "metrics",
        "accounting",
        "capture",
    ):
        require(
            contract[key] == v3[key],
            f"successor changed preserved treatment field {key}",
        )
    require(
        contract["runtime_dependencies"]["ifbench"]
        == v3["runtime_dependencies"]["ifbench"],
        "successor changed IFBench runtime dependencies",
    )
    require(
        contract["runtime_dependencies"]["imp"] == v3["runtime_dependencies"]["imp"],
        "successor changed Imp runtime dependencies",
    )
    successor_upstream = dict(contract["runtime_dependencies"]["upstream"])
    successor_upstream.pop("source_roots")
    successor_upstream.pop("effective_gepa")
    require(
        successor_upstream == v3["runtime_dependencies"]["upstream"],
        "successor changed the locked upstream environment",
    )
    require(
        contract["launch_status"]
        in (
            "draft_unsealed_pending_surface_review",
            "blocked_live_preflight",
            "sealed",
        ),
        "successor launch state drift",
    )
    return {
        "terminal_v3_contract_sha256": predecessor["contract_sha256"],
        "preserved_fields": 10,
        "semantic_deltas": [
            "authenticated GEPA 0.1.4 source bridge",
            "previously sealed failure-cardinality compatibility layer",
        ],
    }


def runner_gate(
    dspy: Any, dummy_cls: Any, translated_cls: Any, contract: dict[str, Any]
) -> dict[str, Any]:
    spec = importlib.util.spec_from_file_location(
        "matched_ifbench_gepa014_upstream", HERE / "run_upstream.py"
    )
    require(
        spec is not None and spec.loader is not None,
        "cannot load GEPA 0.1.4 successor upstream runner",
    )
    runner = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = runner
    spec.loader.exec_module(runner)
    runtime = runner.load_authenticated_runtime()
    require(
        runtime.build_program is runner.build_program,
        "successor did not replace the sole v1 program factory",
    )
    require(
        runtime.compile_arm is runner.compile_arm,
        "successor did not replace the sole compile dispatcher",
    )
    require(
        runtime.MANIFEST_PATH == HERE / "contract.json",
        "successor runner still points at stopped manifest",
    )
    require(
        "matched_gepa_mipro_ifbench_gepa014" in str(runtime.OUTPUT),
        "successor output aliases stopped treatment",
    )
    classes = {}
    for arm in contract["arms"]:
        lm = dummy_cls()
        program = runner.build_program(dspy, lm)
        require(
            isinstance(program, translated_cls),
            f"{arm} factory did not return translated program",
        )
        classes[arm] = (
            f"{program.__class__.__module__}.{program.__class__.__qualname__}"
        )
    return {
        "program_factory_rebound": True,
        "authenticated_optional_import": True,
        "manifest": runtime.MANIFEST_PATH.relative_to(HERE).as_posix(),
        "output_isolated": True,
        "arm_program_classes": classes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dspy-root", type=Path, required=True)
    parser.add_argument("--gepa-root", type=Path, required=True)
    parser.add_argument("--gepa-artifact-root", type=Path, required=True)
    parser.add_argument("--modified-dspy-root", type=Path, required=True)
    parser.add_argument("--ifbench-site-packages", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    for name in (
        "dspy_root",
        "gepa_root",
        "gepa_artifact_root",
        "ifbench_site_packages",
    ):
        setattr(args, name, getattr(args, name).resolve())
    args.modified_dspy_root = args.modified_dspy_root.resolve()

    contract = json.loads((HERE / "contract.json").read_text(encoding="utf-8"))
    clean_tree = git_clean(IMP_ROOT)
    require(not args.require_clean or clean_tree, "Imp worktree is not clean")
    source_result = source_gate(args, contract)
    preservation_result = treatment_preservation_gate(contract)
    data_result = data_gate(contract)
    dspy, np, dummy_cls, exact_cls, translated_cls = install_runtime(args)

    exact_surface = predictor_surface(exact_cls())
    translated_surface = predictor_surface(translated_cls())
    require(exact_surface == translated_surface, "initial predictor surface drift")
    require(
        exact_cls().dump_state() == translated_cls().dump_state(),
        "serialized parameter state drift",
    )
    require(
        f"{exact_cls.__module__}.{exact_cls.__qualname__}"
        != f"{translated_cls.__module__}.{translated_cls.__qualname__}",
        "translation failed to expose distinct class identity",
    )

    rows = load_rows(contract)
    require(
        len(rows) == 49,
        f"expected synthetic plus 48 optimization rows, got {len(rows)}",
    )
    exact_transcripts = []
    translated_transcripts = []
    mechanical_caller_differences = []
    for row in rows:
        exact = run_program(dspy, np, dummy_cls, exact_cls(), row["prompt"])
        translated = run_program(dspy, np, dummy_cls, translated_cls(), row["prompt"])
        for key in ("output", "messages", "trace", "dummy_calls"):
            require(
                exact[key] == translated[key], f"{key} drift for {row['source_id']}"
            )
        require(
            exact["python_rng_unchanged"] and translated["python_rng_unchanged"],
            "Python RNG consumption",
        )
        require(
            exact["numpy_rng_unchanged"] and translated["numpy_rng_unchanged"],
            "NumPy RNG consumption",
        )
        exact_transcripts.append(exact["messages"])
        translated_transcripts.append(translated["messages"])
        if exact["caller_stacks"] != translated["caller_stacks"]:
            mechanical_caller_differences.append(row["source_id"])
    require(
        canonical(exact_transcripts) == canonical(translated_transcripts),
        "aggregate message bytes drift",
    )

    mutations = mutation_gate(dspy, np, dummy_cls, exact_cls, translated_cls)
    bootstrap = bootstrap_gate(dspy, dummy_cls, translated_cls)
    instrumentation = instrumentation_gate(
        dspy, np, dummy_cls, exact_cls, translated_cls
    )
    os.environ["MATCHED_IFBENCH_GEPA014_COMPATIBILITY_GATE"] = "1"
    try:
        runner = runner_gate(dspy, dummy_cls, translated_cls, contract)
    finally:
        os.environ.pop("MATCHED_IFBENCH_GEPA014_COMPATIBILITY_GATE", None)
    result = {
        "status": "pass",
        "claim_boundary": "stock-DSPy-adapted IFBench task graph; not unmodified artifact or paper reproduction",
        "clean_tree_gate": {"required": args.require_clean, "passed": clean_tree},
        "source": source_result,
        "predecessor": preservation_result,
        "data": data_result,
        "rows": {"synthetic": 1, "train": 16, "selection": 32, "total": len(rows)},
        "predictors": exact_surface,
        "messages": {
            "byte_identical": True,
            "sha256": sha256_bytes(canonical(exact_transcripts)),
            "stage_calls": sum(len(item) for item in exact_transcripts),
        },
        "outputs_and_ordered_traces_identical": True,
        "mutation_locality": mutations,
        "stock_bootstrap": bootstrap,
        "top_level_instrumentation": instrumentation,
        "upstream_runner": runner,
        "mechanical_variables": {
            "class_and_serialization_identity": "different top-level class identity; parameter dump_state identical",
            "top_level_instrumentation": "stock Module.__call__ adds callback/caller_modules/usage hooks",
            "caller_stack_difference_rows": len(mechanical_caller_differences),
            "task_content_added": False,
            "rng_consumed": False,
            "metric_input_added": False,
            "external_provider_calls": 0,
        },
    }
    materialized = (
        json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    if args.output is not None:
        temporary = args.output.with_suffix(args.output.suffix + ".tmp")
        temporary.write_text(materialized, encoding="utf-8")
        os.replace(temporary, args.output)
    print(materialized, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
