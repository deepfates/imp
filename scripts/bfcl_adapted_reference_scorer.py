#!/usr/bin/env python3
"""Independent stdlib implementation of Imp's BFCL-shaped scorer contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "benchmarks/config/bfcl-adapted-differential-v1.json"
CONFIG = json.loads(CONFIG_PATH.read_text())
FIXTURE_PATH = ROOT / CONFIG["fixture"]["path"]
TERMINALS = {"submitted", "max_iters", "tool_error", "unknown_tool"}
SCORE_KEYS = (
    "valid_input",
    "tool_name_exact",
    "arguments_exact",
    "terminal_state_exact",
    "passing",
    "error_code",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    fixture = validate_protocol()
    rows = [score_case(case, "positive") for case in fixture["cases"]]
    mutations = [score_case(case, "mutation") for case in fixture["mutations"]]
    report = {
        "schema_version": 2,
        "runner": "independent-python-bfcl-shaped-scorer",
        "protocol_id": CONFIG["protocol_id"],
        "runtime": {
            "implementation": platform.python_implementation(),
            "version": platform.python_version(),
            "dependencies": "stdlib_only",
        },
        "source": source_bindings(),
        "rows": rows,
        "mutations": mutations,
        "summary": summarize(rows, mutations),
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(out)
    return 0


def score_case(case: dict[str, Any], corpus: str) -> dict[str, Any]:
    result = {"id": case["id"], "category": case["category"], "corpus": corpus}
    try:
        expected = normalize_trace(case["expected"])
        candidate = normalize_trace(case["candidate"])
    except json.JSONDecodeError:
        return result | failed_input("malformed_argument_json")
    except (KeyError, TypeError, ValueError):
        return result | failed_input("invalid_trace")

    expected_calls = expected["calls"]
    candidate_calls = candidate["calls"]
    names = [call["name"] for call in candidate_calls] == [call["name"] for call in expected_calls]
    arguments = [call["arguments"] for call in candidate_calls] == [call["arguments"] for call in expected_calls]
    terminal = candidate["terminal_state"] == expected["terminal_state"]
    return result | {
        "valid_input": True,
        "tool_name_exact": names,
        "arguments_exact": arguments,
        "terminal_state_exact": terminal,
        "passing": names and arguments and terminal,
        "error_code": None,
    }


def failed_input(code: str) -> dict[str, Any]:
    return {
        "valid_input": False,
        "tool_name_exact": False,
        "arguments_exact": False,
        "terminal_state_exact": False,
        "passing": False,
        "error_code": code,
    }


def normalize_trace(trace: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(trace, dict) or not isinstance(trace.get("calls"), list):
        raise TypeError("trace must contain a calls list")
    terminal = trace.get("terminal_state")
    if terminal not in TERMINALS:
        raise ValueError("invalid terminal")
    calls = []
    for call in trace["calls"]:
        if not isinstance(call, dict) or not isinstance(call.get("name"), str) or "arguments" not in call:
            raise TypeError("invalid call")
        calls.append({"name": call["name"], "arguments": normalize_argument_root(call["arguments"])})
    return {"calls": calls, "terminal_state": terminal}


def normalize_argument_root(value: Any) -> Any:
    if isinstance(value, str):
        value = json.loads(value)
    return normalize_arguments(value)


def normalize_arguments(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): normalize_arguments(value[key]) for key in sorted(value, key=str)}
    if isinstance(value, list):
        return [normalize_arguments(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError(f"unsupported argument value: {type(value).__name__}")


def summarize(rows: list[dict[str, Any]], mutations: list[dict[str, Any]]) -> dict[str, Any]:
    detected = sum(score_projection(row) == expected_mutation(row["id"]) for row in mutations)
    return {
        "positive_rows": len(rows),
        "positive_passing": sum(row["passing"] for row in rows),
        "mutation_rows": len(mutations),
        "mutations_detected": detected,
        "tool_name_accuracy": sum(row["tool_name_exact"] for row in rows) / len(rows),
        "argument_accuracy": sum(row["arguments_exact"] for row in rows) / len(rows),
        "terminal_state_accuracy": sum(row["terminal_state_exact"] for row in rows) / len(rows),
        "mutation_detection_accuracy": detected / len(mutations),
    }


def expected_mutation(case_id: str) -> dict[str, Any]:
    fixture = json.loads(FIXTURE_PATH.read_text())
    case = next(case for case in fixture["mutations"] if case["id"] == case_id)
    return case["expected_score"]


def score_projection(row: dict[str, Any]) -> dict[str, Any]:
    return {key: row[key] for key in SCORE_KEYS}


def validate_protocol() -> dict[str, Any]:
    fixture = json.loads(FIXTURE_PATH.read_text())
    actual = hashlib.sha256(FIXTURE_PATH.read_bytes()).hexdigest()
    upstream = CONFIG["upstream_protocol"]
    valid = (
        actual == CONFIG["fixture"]["sha256"]
        and CONFIG["fixture"]["positive_rows"] == len(fixture["cases"]) == 12
        and CONFIG["fixture"]["mutation_rows"] == len(fixture["mutations"]) == 9
        and CONFIG["fixture"]["license"] == fixture["provenance"]["row_license"] == "CC0-1.0"
        and fixture["protocol_id"] == CONFIG["protocol_id"]
        and fixture["provenance"]["upstream_revision"] == upstream["commit"]
        and upstream["usage"] == "protocol_provenance_only"
    )
    if not valid:
        raise RuntimeError("BFCL-shaped fixture or protocol preregistration is invalid")
    return fixture


def source_bindings() -> dict[str, str]:
    upstream = CONFIG["upstream_protocol"]
    return {
        "fixture_sha256": file_sha256(FIXTURE_PATH),
        "config_sha256": file_sha256(CONFIG_PATH),
        "script_sha256": file_sha256(Path(__file__)),
        "upstream_authority_sha256": file_sha256(ROOT / upstream["authority_manifest"]),
        "upstream_repository": upstream["repository"],
        "upstream_commit": upstream["commit"],
        "upstream_usage": upstream["usage"],
    }


def file_sha256(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
