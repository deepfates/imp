#!/usr/bin/env python3
"""Run pinned provider-free cases against the standalone RLM runtime."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import inspect
import json
import os
import platform
import secrets
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from unittest.mock import Mock, patch


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def publish_json_exclusively(path: Path, artifact: dict[str, Any]) -> None:
    """Atomically publish one complete artifact without replacing prior evidence."""
    payload = json.dumps(artifact, indent=2, sort_keys=True) + "\n"
    requested_parent = Path(os.path.abspath(path.parent))
    requested_parent.mkdir(parents=True, exist_ok=True)
    canonical_parent = requested_parent.resolve(strict=True)

    if canonical_parent != requested_parent:
        raise RuntimeError(
            "artifact parent must have a canonical, symlink-free identity: "
            f"{requested_parent} resolves to {canonical_parent}"
        )

    directory_flags = os.O_RDONLY
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    expected_parent = os.stat(canonical_parent, follow_symlinks=False)
    directory = os.open(canonical_parent, directory_flags)
    opened_parent = os.fstat(directory)

    if (expected_parent.st_dev, expected_parent.st_ino) != (
        opened_parent.st_dev,
        opened_parent.st_ino,
    ):
        os.close(directory)
        raise RuntimeError("artifact parent changed identity during publication")

    target_name = path.name

    try:
        while True:
            temporary_name = f"{target_name}.tmp-{secrets.token_hex(8)}"

            try:
                descriptor = os.open(
                    temporary_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=directory,
                )
                break
            except FileExistsError:
                continue

        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())

            # Directory-relative linking keeps publication bound to the
            # verified parent if its lexical path changes after this check.
            os.link(
                temporary_name,
                target_name,
                src_dir_fd=directory,
                dst_dir_fd=directory,
                follow_symlinks=False,
            )
            os.fsync(directory)
        finally:
            os.unlink(temporary_name, dir_fd=directory)
    finally:
        os.close(directory)


def canonical_pytest_evidence(exit_code: int, stdout: str, stderr: str) -> bytes:
    """Length-prefix captured pytest process data for a stable evidence digest."""
    return (
        b"pytest-output-v1\0"
        + str(exit_code).encode("ascii")
        + b"\0"
        + str(len(stdout.encode())).encode("ascii")
        + b"\0"
        + stdout.encode()
        + str(len(stderr.encode())).encode("ascii")
        + b"\0"
        + stderr.encode()
    )


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def verify_authority(manifest: dict[str, Any], upstream: Path) -> dict[str, Any]:
    authority = manifest["authority"]
    commit = git(upstream, "rev-parse", "HEAD")
    if commit != authority["commit"]:
        raise RuntimeError(
            f"standalone RLM commit mismatch: expected {authority['commit']}, got {commit}"
        )

    if (
        subprocess.run(
            ["git", "-C", str(upstream), "diff", "--quiet", "HEAD"]
        ).returncode
        != 0
    ):
        raise RuntimeError("standalone RLM checkout has tracked modifications")

    actual_files = {}
    for relative, expected in authority["files"].items():
        path = upstream / relative
        actual = sha256(path)
        if actual != expected:
            raise RuntimeError(
                f"standalone RLM source mismatch for {relative}: expected {expected}, got {actual}"
            )
        actual_files[relative] = actual

    return {
        "repository": authority["repository"],
        "commit": commit,
        "package": authority["package"],
        "version": authority["version"],
        "selected_tests": authority["selected_tests"],
        "files": actual_files,
    }


def run_selected_upstream_tests(
    manifest: dict[str, Any], upstream: Path
) -> dict[str, Any]:
    tests = manifest["authority"]["selected_tests"]
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "-q", *tests],
        cwd=upstream,
        capture_output=True,
        text=True,
        check=False,
    )
    output = canonical_pytest_evidence(result.returncode, result.stdout, result.stderr)
    if result.returncode != 0:
        raise RuntimeError(
            "selected pinned upstream authority tests failed:\n"
            f"{result.stdout}{result.stderr}"
        )

    summary = next(
        (line.strip() for line in reversed(result.stdout.splitlines()) if line.strip()),
        "",
    )
    return {
        "runner": "pytest",
        "command": ["python", "-m", "pytest", "-q", *tests],
        "tests": tests,
        "status": "passed",
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "output_sha256": sha256_bytes(output),
        "summary": summary,
    }


@contextmanager
def observe_public_method(runtime: dict[str, Any], boundary: dict[str, Any]):
    """Instrument the named public method and record actual invocations."""
    class_name = boundary["class"]
    method = boundary["method"]
    owner = runtime[class_name]
    original = inspect.getattr_static(owner, method)

    if (
        boundary["kind"] != "public_method"
        or owner.__module__ != boundary["module"]
        or method.startswith("_")
        or not callable(original)
    ):
        raise RuntimeError(f"invalid public boundary specification: {boundary}")

    calls: list[dict[str, Any]] = []

    def wrapped(*args: Any, **kwargs: Any) -> Any:
        calls.append(
            {
                "positional_arguments": len(args),
                "keyword_arguments": sorted(kwargs),
            }
        )
        return original(*args, **kwargs)

    setattr(owner, method, wrapped)
    try:
        yield calls
    finally:
        setattr(owner, method, original)


def valid_boundary_evidence(
    evidence: dict[str, Any], boundary: dict[str, Any]
) -> bool:
    return (
        evidence.get("mechanism") == "python_public_method_wrapper"
        and evidence.get("module") == boundary["module"]
        and evidence.get("class") == boundary["class"]
        and evidence.get("method") == boundary["method"]
        and evidence.get("method_is_public") is True
        and isinstance(evidence.get("observed_invocations"), int)
        and evidence["observed_invocations"] >= boundary["minimum_invocations"]
        and isinstance(evidence.get("call_shapes"), list)
        and len(evidence["call_shapes"]) == evidence["observed_invocations"]
    )


def public_boundary_evidence(
    boundary: dict[str, Any], calls: list[dict[str, Any]]
) -> dict[str, Any]:
    return {
        "mechanism": "python_public_method_wrapper",
        "module": boundary["module"],
        "class": boundary["class"],
        "method": boundary["method"],
        "method_is_public": not boundary["method"].startswith("_"),
        "observed_invocations": len(calls),
        "call_shapes": calls,
    }


def load_runtime(upstream: Path) -> dict[str, Any]:
    sys.path.insert(0, str(upstream))

    import rlm.core.rlm as rlm_module
    from rlm import RLM
    from rlm.core.types import ModelUsageSummary, RLMChatCompletion, UsageSummary
    from rlm.environments.local_repl import LocalREPL
    from rlm.logger import RLMLogger

    source = Path(rlm_module.__file__).resolve()
    if upstream.resolve() not in source.parents:
        raise RuntimeError(f"loaded RLM outside pinned checkout: {source}")

    package_version = importlib.metadata.version("rlms")

    return {
        "module": rlm_module,
        "RLM": RLM,
        "LocalREPL": LocalREPL,
        "RLMLogger": RLMLogger,
        "ModelUsageSummary": ModelUsageSummary,
        "RLMChatCompletion": RLMChatCompletion,
        "UsageSummary": UsageSummary,
        "package_version": package_version,
        "source": source,
    }


def mock_lm(
    runtime: dict[str, Any], responses: list[str], model: str = "mock-model"
) -> Mock:
    lm = Mock()
    lm.model_name = model
    lm.completion.side_effect = list(responses)
    usage = runtime["ModelUsageSummary"](
        total_calls=1,
        total_input_tokens=10,
        total_output_tokens=10,
    )
    lm.get_usage_summary.return_value = runtime["UsageSummary"](
        model_usage_summaries={model: usage}
    )
    lm.get_last_usage.return_value = usage
    return lm


def repl_response(code: str) -> str:
    fence = chr(96) * 3
    return f"Execute the next step.\n{fence}repl\n{code}\n{fence}"


def continuous_root_transcript(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    lm = mock_lm(
        runtime,
        [
            repl_response("scratch = context + '-derived'\nprint('stage:' + scratch)"),
            repl_response("answer['content'] = scratch\nanswer['ready'] = True"),
        ],
        "root-model",
    )
    logger = runtime["RLMLogger"]()

    with patch.object(runtime["module"], "get_client", return_value=lm):
        rlm = runtime["RLM"](
            backend="openai",
            backend_kwargs={"model_name": "root-model"},
            max_depth=1,
            max_iterations=2,
            logger=logger,
        )
        result = rlm.completion("alpha")

    second_prompt = lm.completion.call_args_list[1].args[0]
    saw_stage = any(
        "stage:alpha-derived" in str(message.get("content", ""))
        for message in second_prompt
    )
    canonical = {
        "continuous_transcript": saw_stage,
        "controller_iterations": len(result.metadata["iterations"]),
        "output": result.response,
    }
    return canonical, {
        "second_turn_roles": [message["role"] for message in second_prompt],
    }


def protected_context_alias(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    repl = runtime["LocalREPL"](context_payload="original")
    try:
        first = repl.execute_code("context = 'hijacked'")
        second = repl.execute_code("print(context)")
        context = repl.locals["context"]
        canonical = {"context": context, "restored": context == "original"}
        return canonical, {
            "first_stderr": first.stderr,
            "second_stdout": second.stdout.strip(),
        }
    finally:
        repl.cleanup()


def persistent_context_versioning(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    first_lm = mock_lm(
        runtime,
        [
            repl_response(
                "scratch = context + '-derived'\n"
                "answer['content'] = scratch\n"
                "answer['ready'] = True"
            )
        ],
        "root-model",
    )
    second_lm = mock_lm(
        runtime,
        [
            repl_response(
                "answer['content'] = context_0 + ':' + context_1 + ':' + scratch\n"
                "answer['ready'] = True"
            )
        ],
        "root-model",
    )

    with patch.object(
        runtime["module"], "get_client", side_effect=[first_lm, second_lm]
    ):
        rlm = runtime["RLM"](
            backend="openai",
            backend_kwargs={"model_name": "root-model"},
            max_depth=1,
            max_iterations=1,
            persistent=True,
        )
        try:
            first = rlm.completion("first").response
            second = rlm.completion("second").response
            environment = rlm._persistent_env
            canonical = {
                "context_count": environment.get_context_count(),
                "first_output": first,
                "history_count": environment.get_history_count(),
                "second_output": second,
            }
            return canonical, {
                "environment": type(environment).__name__,
            }
        finally:
            rlm.close()


def compaction_public_prompt_transition(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    # `format_iteration` caps REPL output at 20k characters. Keep the bounded
    # high-entropy trajectory in the public assistant response so the upstream
    # compaction threshold is crossed without private status manipulation.
    trajectory_comment, trajectory_probes = compaction_trajectory()

    lm = mock_lm(
        runtime,
        [
            repl_response(f"# {trajectory_comment}\nprint('recover-me')"),
            "summary-without-raw-marker",
            repl_response("answer['content'] = 'done'\nanswer['ready'] = True"),
        ],
        "root-model",
    )
    logger = runtime["RLMLogger"]()
    with patch.object(runtime["module"], "get_client", return_value=lm):
        rlm = runtime["RLM"](
            backend="openai",
            backend_kwargs={"model_name": "root-model"},
            max_depth=1,
            max_iterations=2,
            compaction=True,
            compaction_threshold_pct=0.99,
            logger=logger,
        )
        result = rlm.completion("alpha")

    prompts = [call.args[0] for call in lm.completion.call_args_list]
    summary_prompt = prompts[1]
    next_prompt = prompts[2]
    summary_prompt_text = json.dumps(summary_prompt, sort_keys=True)
    next_prompt_text = json.dumps(next_prompt, sort_keys=True)
    canonical = {
        "controller_iterations": len(result.metadata["iterations"]),
        "root_model_calls": lm.completion.call_count,
        "summary_request_observed": any(
            str(message.get("content", "")).startswith("Summarize your progress so far")
            for message in summary_prompt
        ),
        "next_prompt_shorter": len(json.dumps(next_prompt))
        < len(json.dumps(summary_prompt)),
        "summary_prompt_has_full_raw_trajectory": trajectory_comment
        in summary_prompt_text,
        "next_prompt_has_full_raw_trajectory": trajectory_comment in next_prompt_text,
        "trajectory_probe_count": len(trajectory_probes),
        "summary_prompt_trajectory_probes_observed": sum(
            marker in summary_prompt_text for marker in trajectory_probes
        ),
        "next_prompt_trajectory_probes_observed": sum(
            marker in next_prompt_text for marker in trajectory_probes
        ),
        "trajectory_bytes": len(trajectory_comment.encode()),
        "trajectory_sha256": sha256_bytes(trajectory_comment.encode()),
        "next_prompt_has_summary": any(
            "summary-without-raw-marker" in str(message.get("content", ""))
            for message in next_prompt
        ),
    }
    return canonical, {
        "summary_prompt_messages": len(summary_prompt),
        "next_prompt_messages": len(next_prompt),
        "summary_prompt_bytes": len(json.dumps(summary_prompt)),
        "next_prompt_bytes": len(json.dumps(next_prompt)),
        "trajectory_probe_scheme": "16 deterministic probes interleaved across 100000 fixed-width hexadecimal values",
    }


def compaction_trajectory() -> tuple[str, list[str]]:
    probe_count = 16
    values_per_probe = 6250
    parts: list[str] = []
    probes: list[str] = []

    for probe_index in range(probe_count):
        start = probe_index * values_per_probe
        parts.append(
            "".join(
                format(value, "08x")
                for value in range(start, start + values_per_probe)
            )
        )
        probe_seed = f"imp-rlm-trajectory-probe-{probe_index}".encode()
        probe = (
            f"imp-rlm-trajectory-probe-{probe_index:02d}-"
            f"{sha256_bytes(probe_seed)}"
        )
        probes.append(probe)
        parts.append(probe)

    return "".join(parts), probes


def recursive_depth_boundary(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    lm = mock_lm(
        runtime,
        [
            repl_response(
                "reply = rlm_query('leaf prompt', 'child-model')\n"
                "answer['content'] = reply\nanswer['ready'] = True"
            ),
            "leaf response",
        ],
        "leaf-client",
    )
    parent = runtime["RLM"](
        backend="openai",
        backend_kwargs={"model_name": "parent-model"},
        depth=1,
        max_depth=2,
    )
    try:
        with patch.object(runtime["module"], "get_client", return_value=lm):
            result = parent.completion("root")
        requested_model = "child-model"
        canonical = {
            "depth_boundary_fallback": lm.completion.call_count == 2,
            "output": result.response,
            "parent_model": parent.backend_kwargs["model_name"],
            "requested_model": requested_model,
        }
        return canonical, {
            "result_root_model": result.root_model,
            "controller_calls": lm.completion.call_count,
        }
    finally:
        parent.close()


def bounded_ordered_recursive_fanout(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    lock = threading.Lock()
    state = {"active": 0, "max_active": 0}
    calls: list[tuple[str, str | None]] = []

    def subcall(prompt: str, model: str | None = None):
        with lock:
            state["active"] += 1
            state["max_active"] = max(state["max_active"], state["active"])
            calls.append((prompt, model))
        try:
            time.sleep({"slow": 0.05, "bad": 0.02, "fast": 0.01}[prompt])
            if prompt == "bad":
                raise RuntimeError("intentional child failure")
            return runtime["RLMChatCompletion"](
                root_model=model or "child",
                prompt=prompt,
                response=prompt,
                usage_summary=runtime["UsageSummary"](model_usage_summaries={}),
                execution_time=0.01,
            )
        finally:
            with lock:
                state["active"] -= 1

    repl = runtime["LocalREPL"](
        context_payload="parent",
        depth=1,
        subcall_fn=subcall,
        max_concurrent_subcalls=2,
    )
    try:
        result = repl.execute_code(
            "items = rlm_query_batched(['slow', 'bad', 'fast'], 'child-model')\n"
            "print('|'.join(items))"
        )
        normalized = [
            "error" if value.startswith("Error:") else value
            for value in result.stdout.strip().split("|")
        ]
        canonical = {
            "call_count": len(calls),
            "max_concurrency": state["max_active"],
            "ordered_results": normalized,
        }
        return canonical, {
            "calls": calls,
            "stderr": result.stderr,
        }
    finally:
        repl.cleanup()


def expired_deadline_prevents_subcall(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    lm = mock_lm(runtime, [], "parent-model")

    def delayed_controller(_prompt: Any) -> str:
        time.sleep(0.1)
        return repl_response(
            "reply = rlm_query('too late')\n"
            "answer['content'] = reply\nanswer['ready'] = True"
        )

    lm.completion.side_effect = delayed_controller
    parent = runtime["RLM"](
        backend="openai",
        backend_kwargs={"model_name": "parent-model"},
        max_depth=3,
        max_timeout=0.05,
    )
    try:
        with patch.object(runtime["module"], "get_client", return_value=lm):
            result = parent.completion("root")
        canonical = {
            "status": "bounded_failure",
            "subcall_started": lm.completion.call_count > 1,
        }
        return canonical, {
            "response": result.response,
        }
    finally:
        parent.close()


def local_code_capability(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    repl = runtime["LocalREPL"]()
    try:
        result = repl.execute_code("import math\nvalue = math.sqrt(9)")
        allowed = result.stderr == "" and repl.locals.get("value") == 3.0
        canonical = {
            "imports_allowed": allowed,
            "value": repl.locals.get("value") if allowed else None,
            "runtime": "non_isolated_local_python",
        }
        return canonical, {
            "stderr": result.stderr,
            "source": "import math; value = math.sqrt(9)",
        }
    finally:
        repl.cleanup()


def assignment_before_cell_error(
    runtime: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    repl = runtime["LocalREPL"](context_payload="original")
    try:
        result = repl.execute_code("scratch = context + '-saved'\nmissing()")
        canonical = {"assignment_survives_error": "scratch" in repl.locals}
        return canonical, {
            "stderr": result.stderr,
        }
    finally:
        repl.cleanup()


CASES: dict[str, Callable[[dict[str, Any]], tuple[dict[str, Any], dict[str, Any]]]] = {
    "continuous_root_transcript": continuous_root_transcript,
    "protected_context_alias": protected_context_alias,
    "persistent_context_versioning": persistent_context_versioning,
    "compaction_public_prompt_transition": compaction_public_prompt_transition,
    "recursive_depth_boundary": recursive_depth_boundary,
    "bounded_ordered_recursive_fanout": bounded_ordered_recursive_fanout,
    "expired_deadline_prevents_subcall": expired_deadline_prevents_subcall,
    "local_code_capability": local_code_capability,
    "assignment_before_cell_error": assignment_before_cell_error,
}


def expected(case: dict[str, Any]) -> dict[str, Any]:
    if case["comparison"] == "matched":
        return case["expected"]
    return case["expected_by_runtime"]["official"]


def run_case(case: dict[str, Any], runtime: dict[str, Any]) -> dict[str, Any]:
    base = {
        key: case[key]
        for key in [
            "id",
            "category",
            "comparison",
            "required",
            "invariant",
            "authority_tests",
            "boundary",
        ]
    }
    try:
        with observe_public_method(runtime, case["boundary"]["official"]) as calls:
            canonical, details = CASES[case["id"]](runtime)

        boundary_evidence = public_boundary_evidence(
            case["boundary"]["official"], calls
        )
        wanted = expected(case)
        boundary_valid = valid_boundary_evidence(
            boundary_evidence, case["boundary"]["official"]
        )
        return {
            **base,
            "executed": True,
            "real_boundary": boundary_valid,
            "passing": canonical == wanted and boundary_valid,
            "expected": wanted,
            "canonical": canonical,
            "details": {**details, "boundary_evidence": boundary_evidence},
            "errors": []
            if canonical == wanted and boundary_valid
            else [
                error
                for error, failed in [
                    ("canonical observation mismatch", canonical != wanted),
                    (
                        "public boundary observation missing or invalid",
                        not boundary_valid,
                    ),
                ]
                if failed
            ],
        }
    except Exception as error:
        return {
            **base,
            "executed": True,
            "real_boundary": False,
            "passing": False,
            "expected": expected(case),
            "canonical": None,
            "details": {},
            "errors": [f"{type(error).__name__}: {error}"],
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--upstream", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    manifest_path = args.manifest.resolve()
    upstream = args.upstream.resolve()
    manifest = json.loads(manifest_path.read_text())
    authority = verify_authority(manifest, upstream)
    runtime = load_runtime(upstream)
    upstream_tests = run_selected_upstream_tests(manifest, upstream)

    if runtime["package_version"] != authority["version"]:
        raise RuntimeError(
            f"rlms package version mismatch: expected {authority['version']}, "
            f"got {runtime['package_version']}"
        )

    rows = [run_case(case, runtime) for case in manifest["cases"]]
    artifact = {
        "schema_version": 1,
        "runner": "official-standalone-rlm-runtime-differential",
        "runtime": "official",
        "evidence_tier": "t1_pinned_runtime_differential",
        "claim_scope": manifest["claim_scope"],
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "python_version": platform.python_version(),
        "fixture": {
            "path": str(manifest_path),
            "sha256": sha256(manifest_path),
        },
        "runner_source": {
            "path": str(Path(__file__).resolve()),
            "sha256": sha256(Path(__file__).resolve()),
        },
        "authority": authority,
        "upstream_tests": upstream_tests,
        "loaded_source": str(runtime["source"]),
        "summary": {
            "total_cases": len(rows),
            "passing_cases": sum(row["passing"] for row in rows),
            "all_cases_pass": all(row["passing"] for row in rows),
            "all_public_boundary_evidence": all(
                row["real_boundary"] for row in rows
            ),
        },
        "rows": rows,
    }

    publish_json_exclusively(args.out, artifact)
    print(args.out)
    print(json.dumps(artifact["summary"], indent=2, sort_keys=True))
    return 0 if artifact["summary"]["all_cases_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
