#!/usr/bin/env python3
"""Replay provider-free golden trace fixtures through Python DSPy."""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional

import dspy
import pydantic


@dataclass
class FakeResponse:
    choices: list
    usage: dict
    model: str
    _hidden_params: dict


_CAPABILITY_TIERS = {
    # tier name -> (supported_params, supports_response_schema)
    None: (set(), False),
    "none": (set(), False),
    "response_format": ({"response_format"}, False),
    "json_object": ({"response_format"}, False),
    "json_schema": ({"response_format"}, True),
    "response_schema": ({"response_format"}, True),
}


class FixtureLM(dspy.BaseLM):
    def __init__(self, responses: List[str], capability: Optional[str] = None) -> None:
        super().__init__(model="fake/golden", cache=False)
        self.responses = list(responses)
        if capability not in _CAPABILITY_TIERS:
            raise ValueError(f"unknown lm_capability tier: {capability!r}")
        self._supported_params, self._supports_response_schema = _CAPABILITY_TIERS[capability]

    # The two properties dspy.JSONAdapter gates response_format on. Declaring
    # them here lets one fixture exercise a specific capability tier so the
    # Elixir side (Imp.LM.Capability) can be proven to match tier-for-tier.
    @property
    def supported_params(self) -> set:
        return set(self._supported_params)

    @property
    def supports_response_schema(self) -> bool:
        return self._supports_response_schema

    def forward(self, prompt=None, messages=None, **kwargs):  # noqa: ANN001
        if not self.responses:
            raise RuntimeError("fixture response queue exhausted")

        content = self.responses.pop(0)
        return FakeResponse(
            choices=[SimpleNamespace(message=SimpleNamespace(content=content))],
            usage={},
            model=self.model,
            _hidden_params={},
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()

    cases = json.loads(Path(args.fixtures).read_text())
    report = {
        "schema_version": 1,
        "runner": "python-dspy-golden-trace",
        "python": platform.python_version(),
        "dspy_version": getattr(dspy, "__version__", "unknown"),
        "git_sha": git_sha(),
        "cases": [run_case(case) for case in cases],
    }

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(args.out)
    else:
        print(json.dumps(report, indent=2, sort_keys=True))

    return 0


def run_case(case: Dict[str, Any]) -> Dict[str, Any]:
    lm = FixtureLM(case.get("dspy_responses", case["responses"]), case.get("lm_capability"))
    dspy.configure(lm=lm)

    try:
        signature = dspy.Signature(dspy_signature(case["signature"]), case.get("instructions"))
        dspy.configure(lm=lm, adapter=adapter(case.get("adapter")))
        program = build_program(case, signature)
        prediction = program(**case["inputs"])
        status = "ok"
        error = None
        prediction_map = normalize_prediction(prediction)
        tool_trace = normalize_tool_trace(prediction_map)
    except Exception as exc:  # noqa: BLE001
        status = "error"
        error = repr(exc)
        prediction_map = None
        tool_trace = []

    history = normalize_history(lm.history)

    return {
        "id": case["id"],
        "status": status,
        "prediction": prediction_map,
        "tool_trace": tool_trace,
        "error": error,
        "history": history,
        "remaining_responses": len(lm.responses),
    }


def build_program(case: Dict[str, Any], signature):
    module = case["module"]

    # Few-shot demos are attached to the predictor. DSPy's adapter.format reads
    # `program.demos` (Predict) / `program.predict.demos` (ChainOfThought) and
    # renders them as multiturn messages, so setting them here threads demos
    # into the rendered prompt exactly as an optimized program would (dee-u4st,
    # dee-0bwu). Plain dicts match the JSON fixture and DSPy's `k in demo` /
    # `demo.get(k, ...)` key-presence checks (present-null stays null).
    demos = case.get("demos") or []

    if module == "predict":
        program = dspy.Predict(signature)
        program.demos = demos
        return program
    if module == "chain_of_thought":
        program = dspy.ChainOfThought(signature)
        program.predict.demos = demos
        return program
    if module in ("react", "react_dspy"):
        # `react` and `react_dspy` both build the real dspy.ReAct. The Imp side
        # differs: `react` builds provider-native ReAct (documented deviation),
        # while `react_dspy` builds Imp's byte-faithful :dspy_3_2_1 mode.
        return dspy.ReAct(signature, build_tools(case), max_iters=case.get("max_iters", 5))
    raise ValueError(f"unsupported fixture module: {module}")


def build_tools(case: Dict[str, Any]):
    return [build_tool(spec) for spec in case.get("tools", [])]


def build_tool(spec: Dict[str, Any]):
    name = spec["name"]
    desc = spec.get("description", "")
    outputs = spec.get("outputs", {})

    def run(**kwargs):
        key = json.dumps(kwargs, sort_keys=True, separators=(",", ":"))
        if key not in outputs:
            raise ValueError(f"unexpected tool arguments for {name}: {kwargs!r}")
        return outputs[key]

    return dspy.Tool(run, name=name, desc=desc, args=spec.get("schema", {}).get("properties", {}))


def adapter(name: Optional[str]):
    if name == "json":
        return dspy.JSONAdapter()
    if name == "xml":
        return dspy.XMLAdapter()
    return dspy.ChatAdapter()


def dspy_signature(signature: str) -> str:
    """Translate Imp's signature type syntax into DSPy/Python type syntax so one
    fixture signature string parses identically on both sides.

    Composite types are handled first (order matters: `array[T]` must be rewritten
    before its inner scalar, and the bare-word scalar swaps must not touch names
    inside `enum[...]`), then the remaining scalar aliases.
    """
    signature = _translate_composites(signature)
    return (
        signature.replace(": string", ": str")
        .replace(": integer", ": int")
        .replace(": boolean", ": bool")
    )


_SCALAR_TO_PY = {
    "string": "str",
    "integer": "int",
    "int": "int",
    "float": "float",
    "number": "float",
    "boolean": "bool",
    "bool": "bool",
}


def _translate_composites(signature: str) -> str:
    import re

    # enum[a,b] / class[a,b] -> Literal['a', 'b']
    def enum_repl(match: "re.Match[str]") -> str:
        values = [v.strip() for v in re.split(r"[,|]", match.group(1)) if v.strip()]
        rendered = ", ".join(_quote_literal(v) for v in values)
        return f"Literal[{rendered}]"

    signature = re.sub(r"(?:enum|class)\[([^\]]*)\]", enum_repl, signature)

    # array[T] -> list[<T translated>], with BALANCED bracket matching so nested
    # arrays and object-valued elements survive. The old non-nesting regex
    # `array\[([^\]]*)\]` produced invalid `list[array[integer]]` /`list[object]`
    # that DSPy rejects, masking the divergence (dee-68oy / dee-p1d5).
    signature = _rewrite_arrays(signature)

    # bare `array` -> `list`
    signature = re.sub(r"(?<![\w\[])array(?![\w\[])", "list", signature)

    # standalone object / map -> dict[str, Any] (array elements handled above)
    signature = re.sub(r"(?<![\w\[])(?:object|map)(?![\w\[])", "dict[str, Any]", signature)

    return signature


def _rewrite_arrays(signature: str) -> str:
    """Replace every balanced `array[...]` span with `list[<translated inner>]`."""
    out = []
    i = 0
    n = len(signature)
    while i < n:
        if signature.startswith("array[", i):
            depth = 0
            k = i + len("array")  # index of the opening '['
            while k < n:
                if signature[k] == "[":
                    depth += 1
                elif signature[k] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            out.append(_translate_type(signature[i : k + 1]))
            i = k + 1
        else:
            out.append(signature[i])
            i += 1
    return "".join(out)


def _translate_type(t: str) -> str:
    """Translate a single, whole Imp type expression into Python type syntax."""
    t = t.strip()
    if t.startswith("array[") and t.endswith("]"):
        return f"list[{_translate_type(t[len('array['):-1])}]"
    if t == "array":
        return "list"
    if t in ("object", "map"):
        return "dict[str, Any]"
    if t.startswith(("Literal[", "list[", "dict[")):
        return t
    return _SCALAR_TO_PY.get(t, t)


def _quote_literal(value: str) -> str:
    # Mirror dspy.adapters.utils._quoted_string_for_literal_type_annotation.
    has_single = "'" in value
    has_double = '"' in value
    if has_single and not has_double:
        return f'"{value}"'
    if has_double and not has_single:
        return f"'{value}'"
    if has_single and has_double:
        return "'" + value.replace("'", "\\'") + "'"
    return f"'{value}'"


def normalize_prediction(prediction: Any) -> Dict[str, Any]:
    if hasattr(prediction, "toDict"):
        return prediction.toDict()
    if hasattr(prediction, "_store"):
        return dict(prediction._store)
    return {"repr": repr(prediction)}


def normalize_tool_trace(prediction_map: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if not prediction_map:
        return []

    trajectory = prediction_map.get("trajectory") or {}
    trace = []
    idx = 0
    while f"tool_name_{idx}" in trajectory:
        name = trajectory.get(f"tool_name_{idx}")
        args = trajectory.get(f"tool_args_{idx}", {})
        result = trajectory.get(f"observation_{idx}")
        if name != "finish":
            trace.append({"tool": name, "arguments": args, "result": result})
        idx += 1
    return trace


def normalize_history(history: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    # `kwargs` is DSPy's PER-CALL request envelope: the extra options the
    # adapter passed to this LM call (response_format, tools, tool_choice, ...),
    # logged by dspy.BaseLM._process_lm_response minus base sampling params. The
    # Elixir harness compares this per call against Imp's recorded LM opts to
    # measure envelope_parity (dee-idig). Preserving it PER ENTRY keeps call
    # boundaries intact so a differently-split trajectory cannot be masked.
    normalized = []
    for entry in history:
        normalized.append(
            {
                "messages": entry.get("messages"),
                "kwargs": _sanitize_kwargs(entry.get("kwargs")),
                "outputs": entry.get("outputs"),
                "model": entry.get("model"),
                "model_type": entry.get("model_type"),
            }
        )
    return normalized


def _sanitize_kwargs(kwargs: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """Render the request envelope in its true on-the-wire form.

    For the json_schema tier DSPy sets `response_format` to a pydantic model
    CLASS (`DSPyProgramOutputs`); litellm — DSPy's transport — converts that to
    the OpenAI `{"type": "json_schema", "json_schema": {...}}` param before it
    hits the provider. We reproduce that exact conversion here so the logged
    envelope is (a) JSON-serializable and (b) the same bytes any real
    litellm-backed dspy.LM would send — the honest comparison target for Imp.
    """
    if not kwargs:
        return kwargs

    rf = kwargs.get("response_format")
    if isinstance(rf, type) and issubclass(rf, pydantic.BaseModel):
        from litellm.utils import type_to_response_format_param

        kwargs = dict(kwargs)
        kwargs["response_format"] = type_to_response_format_param(rf)
    return kwargs


def git_sha() -> Optional[str]:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        return None


if __name__ == "__main__":
    raise SystemExit(main())
