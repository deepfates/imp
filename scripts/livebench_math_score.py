#!/usr/bin/env python3
"""Source-derived LiveBenchMath scoring bridge for symbolic branches.

The Elixir runtime ports deterministic LiveBenchMath branches directly. AMPS_Hard
uses SymPy/Lark symbolic equivalence upstream, so Imp calls this narrow bridge
instead of implementing a weak approximation.
"""

import json
import os
import contextlib
import io
from pathlib import Path
import re
import sys
import traceback
import warnings


def last_boxed_only_string(string):
    idx = string.rfind("\\boxed")

    if "\\boxed " in string:
        return "\\boxed " + string.split("\\boxed ")[-1].split("$")[0]
    if idx < 0:
        idx = string.rfind("\\fbox")
        if idx < 0:
            return None

    right_brace_idx = None
    num_left_braces_open = 0
    i = idx
    while i < len(string):
        if string[i] == "{":
            num_left_braces_open += 1
        if string[i] == "}":
            num_left_braces_open -= 1
            if num_left_braces_open == 0:
                right_brace_idx = i
                break
        i += 1

    if right_brace_idx is None:
        return None
    return string[idx : right_brace_idx + 1].replace("$", "").replace("fbox", "boxed")


def remove_boxed(s):
    if "\\boxed " in s:
        return s[len("\\boxed ") :]
    return s[len("\\boxed{") : -1]


def parse_latex_expr(value):
    try:
        import lark
        import sympy
        from sympy.parsing.latex import parse_latex
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "LiveBenchMath AMPS_Hard scoring requires sympy and lark; install them in the bridge Python"
        ) from exc

    try:
        parsed = parse_latex(value, backend="lark")
    except Exception:
        try:
            parsed = parse_latex(value.replace("\\\\", "\\"), backend="lark")
        except Exception:
            try:
                parsed = parse_latex(value)
            except Exception:
                warnings.warn(f"couldn't parse {value}")
                return []

    if isinstance(parsed, lark.Tree):
        return parsed.children
    return [parsed]


def is_equiv(x1, x2):
    import sympy

    parsed_x1s = parse_latex_expr(x1)
    parsed_x2s = parse_latex_expr(x2)

    if len(parsed_x1s) == 0 or len(parsed_x2s) == 0:
        return False

    for parsed_x1 in parsed_x1s:
        for parsed_x2 in parsed_x2s:
            try:
                diff = parsed_x1 - parsed_x2
            except Exception:
                continue

            try:
                if sympy.simplify(diff) == 0:
                    return True
            except Exception:
                pass

            try:
                if sympy.Abs(sympy.simplify(diff)) < 0.001:
                    return True
            except Exception:
                pass
    return False


def normalize_final_answer(final_answer):
    final_answer = final_answer.split("=")[-1]
    final_answer = re.sub(r"(.*?)(\$)(.*?)(\$)(.*)", "$\\3$", final_answer)
    final_answer = re.sub(r"(\\text\{)(.*?)(\})", "\\2", final_answer)
    final_answer = re.sub(r"(\\textbf\{)(.*?)(\})", "\\2", final_answer)
    final_answer = re.sub(r"(\\overline\{)(.*?)(\})", "\\2", final_answer)
    final_answer = re.sub(r"(\\boxed\{)(.*)(\})", "\\2", final_answer)
    final_answer = re.sub(r"(frac)([^{])(.)", "frac{\\2}{\\3}", final_answer)
    final_answer = re.sub(r"(sqrt)([^{\[])", "sqrt{\\2}", final_answer)
    final_answer = final_answer.replace("$", "")

    if final_answer.replace(",", "").isdigit():
        final_answer = final_answer.replace(",", "")

    return final_answer


def amps_hard_process_results(ground_truth, llm_answer):
    retval = 0
    parsed_answer = None

    if isinstance(ground_truth, list):
        ground_truth = ground_truth[-1]

    llm_answer = llm_answer.replace("+C", "")
    llm_answer = llm_answer.replace("+ C", "")
    llm_answer = llm_answer.replace("+ c", "")
    llm_answer = llm_answer.replace("+c", "")
    llm_answer = llm_answer.replace("\\\\fbox{", "\\\\boxed{")
    llm_answer = llm_answer.replace("\\dfrac", "\\frac")
    llm_answer = llm_answer.replace("\\tfrac", "\\frac")
    llm_answer = llm_answer.replace("\\left", "")
    llm_answer = llm_answer.replace("\\right", "")
    llm_answer = llm_answer.replace("\\bigl", "")
    llm_answer = llm_answer.replace("\\bigr", "")
    llm_answer = llm_answer.replace("\\Bigl", "")
    llm_answer = llm_answer.replace("\\Bigr", "")
    llm_answer = llm_answer.replace("\\,", "")
    llm_answer = llm_answer.replace("\\;", "")
    llm_answer = llm_answer.replace("\n", "")
    llm_answer = llm_answer.replace("\\cdot", "*")

    ground_truth = ground_truth.replace("\\left", "")
    ground_truth = ground_truth.replace("\\right", "")
    ground_truth = ground_truth.replace(" ^", "^")
    ground_truth = ground_truth.replace("\\ ", "*")

    last_boxed = last_boxed_only_string(llm_answer)
    if last_boxed:
        parsed_answer = normalize_final_answer(remove_boxed(last_boxed))

    if parsed_answer is None:
        last_line = llm_answer.split("\n")[-1]
        if last_line.count("$") >= 2:
            close_pos = last_line.rfind("$")
            if last_line[close_pos - 1] == "$":
                close_pos -= 1
            open_pos = last_line.rfind("$", 0, close_pos)
            math = last_line[open_pos + 1 : close_pos]
            if "=" in math:
                math = math.split("=")[-1].strip()
            elif "\\quad \\text{or} \\quad" in math:
                math = math.split("\\quad \\text{or} \\quad")[-1].strip()
            parsed_answer = normalize_final_answer(math)

    if parsed_answer is not None:
        if is_equiv(ground_truth, parsed_answer):
            retval = 1
    else:
        if len(llm_answer) > 0 and llm_answer[-1] == ".":
            llm_answer = llm_answer[:-1]
        if ground_truth == llm_answer[-len(ground_truth) :]:
            retval = 1
            parsed_answer = llm_answer[-len(ground_truth) :]

    return retval, parsed_answer


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)
    task = payload.get("task")

    if task == "livebench_math_feedback":
        source_root = os.environ.get("IMP_LIVEBENCH_MATH_SOURCE_ROOT")
        if not source_root:
            raise RuntimeError("livebench_math_feedback requires IMP_LIVEBENCH_MATH_SOURCE_ROOT")
        source_root = str(Path(source_root).resolve())
        if source_root not in sys.path:
            sys.path.insert(0, source_root)
        from gepa_artifact.benchmarks.livebench_math.livebenchmath_utils.metric import (
            calculate_livebench_score,
        )

        with (
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
            warnings.catch_warnings(),
        ):
            warnings.simplefilter("ignore")
            score, feedback = calculate_livebench_score(
                payload["question_d"], str(payload.get("answer", "")), debug=True
            )
        print(json.dumps({"score": score, "feedback": feedback}))
        return

    if task not in {"amps_hard", "amps_hard_feedback"}:
        raise RuntimeError(f"unsupported bridge task: {task}")

    score, parsed_answer = amps_hard_process_results(
        str(payload.get("ground_truth", "")),
        str(payload.get("answer", "")),
    )

    result = {"score": score, "parsed_answer": parsed_answer}
    if task == "amps_hard_feedback":
        result["feedback"] = (
            f"The symbolic scorer parsed {parsed_answer!r}; the answer scored {float(score)}."
        )
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        json.dump({"error": str(exc), "traceback": traceback.format_exc()}, sys.stdout)
        sys.stdout.write("\n")
        sys.exit(1)
