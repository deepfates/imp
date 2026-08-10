"""Per-trial optimizer-evidence extraction for upstream (Python DSPy) sealing.

INTEGRATION (rehearsal run_upstream.py) — after each optimizer.compile(...):

    from upstream_trial_sealing import extract_trial_ledger
    # mipro cell:
    cell_record["trial_ledger"] = extract_trial_ledger(
        arm="mipro", optimizer=optimizer, program=compiled_program)
    # gepa cell:
    cell_record["trial_ledger"] = extract_trial_ledger(
        arm="gepa", optimizer=optimizer, program=compiled_program)
    # (cell_record is the dict later json.dumps'ed into the sealed per-cell JSON.)

The ledger is guaranteed json.dumps-safe; when evidence is unavailable it is
{"available": false, "reason": ...} rather than an exception.

Sources (pinned):
- MIPROv2, tmp/dspy-3.2.1/dspy/teleprompt/mipro_optimizer_v2.py:
  * trial_logs is attached to the RETURNED program only when track_stats=True
    (line 677-679: ``best_program.trial_logs = trial_logs``), not to the
    optimizer object. Per-trial keys written at lines 774/781
    (``{i}_predictor_instruction`` / ``{i}_predictor_demos``), minibatch score
    at line 711 (``mb_score``), full-eval score at lines 546/860
    (``full_eval_score``).
  * score_data entries are {"score", "program", "full_eval"} (lines 554,
    600-602) and are attached, sorted by score, as
    ``best_program.candidate_programs`` (full_eval=True) and
    ``best_program.mb_candidate_programs`` (lines 681-690).
  * The optuna study is a local variable of _optimize_prompt_parameters
    (line 661) and is NOT retained on the optimizer or the program; pass it
    explicitly via ``study=`` if the caller captured it (e.g. by
    monkeypatching optuna.create_study), otherwise the ledger records it as
    unavailable with that reason.
- GEPA:
  * dspy 3.2.1 attaches ``detailed_results`` (a DspyGEPAResult) to the
    returned program when track_stats=True
    (tmp/dspy-3.2.1/dspy/teleprompt/gepa/gepa.py:601-602); its to_dict()
    (gepa.py:114-131) yields candidates/parents/val_aggregate_scores/
    val_subscores/per_val_instance_best_candidates/discovery_eval_counts/
    total_metric_calls/num_full_val_evals/seed/best_idx — but candidates are
    dspy Modules there, so we re-extract instruction text per predictor.
  * Raw gepa GEPAResult (tmp/gepa-v0.1.4/src/gepa/core/result.py) exposes the
    same iteration history via to_dict(); candidates are already
    dict[str, str].
"""

from __future__ import annotations

import json
import re
from typing import Any

_MIPRO_PARAM_KEY = re.compile(r"^\d+_predictor_(instruction|demos)$")

# ---------------------------------------------------------------------------
# JSON safety
# ---------------------------------------------------------------------------


def _json_safe(value: Any, depth: int = 0) -> Any:
    """Best-effort conversion to a json.dumps-able structure.

    Program/Module objects (and anything else exotic) collapse to a short
    typed summary instead of raising.
    """
    if depth > 8:
        return {"unserializable": True, "reason": "max_depth"}
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value if value == value and value not in (float("inf"), float("-inf")) else repr(value)
    # numpy scalars
    item = getattr(value, "item", None)
    if callable(item) and type(value).__module__.startswith("numpy"):
        try:
            return _json_safe(value.item(), depth + 1)
        except Exception:
            pass
    if isinstance(value, dict):
        return {str(k): _json_safe(v, depth + 1) for k, v in value.items()}
    if isinstance(value, (list, tuple, set, frozenset)):
        seq = sorted(value, key=repr) if isinstance(value, (set, frozenset)) else value
        return [_json_safe(v, depth + 1) for v in seq]
    return {
        "unserializable": True,
        "type": f"{type(value).__module__}.{type(value).__qualname__}",
        "repr": repr(value)[:200],
    }


def _numeric(value: Any) -> float | int | None:
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if out != out or out in (float("inf"), float("-inf")):
        return None
    return int(out) if isinstance(value, int) and not isinstance(value, bool) else out


def _predictor_instructions(program: Any) -> list[dict[str, str]] | None:
    named = getattr(program, "named_predictors", None)
    if not callable(named):
        return None
    try:
        return [
            {"name": name, "instructions": predictor.signature.instructions}
            for name, predictor in named()
        ]
    except Exception as exc:  # noqa: BLE001 - evidence capture must not abort sealing
        return [{"name": "<error>", "instructions": repr(exc)[:200]}]


def _unavailable(reason: str) -> dict[str, Any]:
    return {"available": False, "reason": reason}


# ---------------------------------------------------------------------------
# MIPRO
# ---------------------------------------------------------------------------


def extract_mipro_trial_ledger(
    optimizer: Any = None,
    program: Any = None,
    study: Any = None,
) -> dict[str, Any]:
    """Extract per-trial evidence from a completed MIPROv2 run.

    dspy 3.2.1 attaches trial evidence to the RETURNED program (track_stats),
    not the optimizer, so ``program`` is the primary source. ``study`` is the
    optuna study if the caller captured it (MIPROv2 does not retain it).
    """
    trial_logs = getattr(program, "trial_logs", None)
    if trial_logs is None:
        trial_logs = getattr(optimizer, "trial_logs", None)  # future-proofing only
    if not isinstance(trial_logs, dict) or not trial_logs:
        return _unavailable(
            "no trial_logs on returned program (MIPROv2 requires track_stats=True; "
            "dspy 3.2.1 attaches logs to best_program only, "
            "mipro_optimizer_v2.py:677-679)"
        )

    trials = []
    for trial_num in sorted(trial_logs):
        log = trial_logs[trial_num]
        if not isinstance(log, dict):
            continue
        params = {k: _json_safe(v) for k, v in log.items() if _MIPRO_PARAM_KEY.match(str(k))}
        mb_score = _numeric(log.get("mb_score"))
        full_score = _numeric(log.get("full_eval_score"))
        trials.append(
            {
                "trial_num": int(trial_num),
                "params": params,
                "score": full_score if full_score is not None else mb_score,
                "full_eval": "full_eval_score" in log,
                "mb_score": mb_score,
                "full_eval_score": full_score,
                "total_eval_calls_so_far": _numeric(log.get("total_eval_calls_so_far")),
                "full_eval_program_path": _json_safe(log.get("full_eval_program_path")),
                "mb_program_path": _json_safe(log.get("mb_program_path")),
            }
        )

    # score_data ({"score","program","full_eval"}) as sorted-by-score summaries
    def _score_data(attr: str) -> Any:
        entries = getattr(program, attr, None)
        if not isinstance(entries, list):
            return None
        return [
            {
                "score": _numeric(e.get("score")) if isinstance(e, dict) else None,
                "full_eval": bool(e.get("full_eval")) if isinstance(e, dict) else None,
                "program_instructions": _predictor_instructions(e.get("program")) if isinstance(e, dict) else None,
            }
            for e in entries
        ]

    if study is None:
        study = getattr(optimizer, "study", None)  # not set by stock 3.2.1
    if study is not None:
        optuna_trials: Any = []
        try:
            for t in study.trials:
                optuna_trials.append(
                    {
                        "number": int(t.number),
                        "params": _json_safe(dict(t.params)),
                        "value": _numeric(t.value),
                        "state": str(t.state),
                    }
                )
        except Exception as exc:  # noqa: BLE001
            optuna_trials = _unavailable(f"study traversal failed: {exc!r}")
    else:
        optuna_trials = _unavailable(
            "optuna study not reachable: MIPROv2 keeps it as a local variable "
            "(mipro_optimizer_v2.py:661) and never stores it; pass study= if captured"
        )

    return {
        "available": True,
        "optimizer": "MIPROv2",
        "source": "best_program.trial_logs (dspy 3.2.1 mipro_optimizer_v2.py:677-679)",
        "num_trials": len(trials),
        "trials": trials,
        "best_score": _numeric(getattr(program, "score", None)),
        "candidate_programs_full_eval": _score_data("candidate_programs"),
        "candidate_programs_minibatch": _score_data("mb_candidate_programs"),
        "optuna_trials": optuna_trials,
    }


# ---------------------------------------------------------------------------
# GEPA
# ---------------------------------------------------------------------------

_GEPA_RESULT_FIELDS = (
    "parents",
    "val_aggregate_scores",
    "val_subscores",
    "per_val_instance_best_candidates",
    "discovery_eval_counts",
    "total_metric_calls",
    "num_full_val_evals",
    "seed",
    "best_idx",
)


def extract_gepa_trial_ledger(result: Any = None, program: Any = None) -> dict[str, Any]:
    """Extract candidate/iteration history from a completed GEPA run.

    Accepts either a result object (raw gepa GEPAResult or dspy
    DspyGEPAResult) or the compiled program (dspy attaches
    ``detailed_results`` when track_stats=True, gepa.py:601-602).
    """
    if result is None:
        result = getattr(program, "detailed_results", None)
    if result is None:
        return _unavailable(
            "no GEPA result: pass result= or a program with detailed_results "
            "(dspy 3.2.1 GEPA requires track_stats=True, gepa/gepa.py:601-602)"
        )

    ledger: dict[str, Any] = {
        "available": True,
        "optimizer": "GEPA",
        "result_type": f"{type(result).__module__}.{type(result).__qualname__}",
    }
    for field in _GEPA_RESULT_FIELDS:
        if hasattr(result, field):
            ledger[field] = _json_safe(getattr(result, field))

    # candidates: dict[str, str] in raw GEPAResult; dspy Modules in DspyGEPAResult
    candidates = getattr(result, "candidates", None)
    if isinstance(candidates, list):
        ledger["num_candidates"] = len(candidates)
        ledger["candidates"] = [
            _json_safe(c) if isinstance(c, dict) else _predictor_instructions(c) or _json_safe(c)
            for c in candidates
        ]

    scores = ledger.get("val_aggregate_scores")
    if not isinstance(scores, list) or not scores:
        ledger["available"] = False
        ledger["reason"] = "result object exposes no val_aggregate_scores history"
    return ledger


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------


def extract_trial_ledger(
    arm: str,
    optimizer: Any = None,
    program: Any = None,
    study: Any = None,
    result: Any = None,
) -> dict[str, Any]:
    """Arm-dispatching entry point; always returns a json.dumps-safe dict."""
    try:
        if arm == "mipro":
            ledger = extract_mipro_trial_ledger(optimizer=optimizer, program=program, study=study)
        elif arm == "gepa":
            ledger = extract_gepa_trial_ledger(result=result, program=program)
        else:
            ledger = _unavailable(f"unknown arm {arm!r}")
    except Exception as exc:  # noqa: BLE001 - sealing must not fail on evidence capture
        ledger = _unavailable(f"extraction raised {type(exc).__name__}: {exc}")
    json.dumps(ledger)  # hard guarantee; _json_safe makes this unreachable-to-fail
    return ledger
