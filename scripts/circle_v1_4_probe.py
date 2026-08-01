#!/usr/bin/env python3
"""Repository-only, provider-free probe for the pinned Circle v1.4 evaluator."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

AUTHORITY_COMMIT = "6388548aac5de93ed3e581de20cc943bb3bee3fe"
DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
CIRCLE_ROOT = Path("acm_cais_artifact_evaluation/domains/circle_packing")
SOURCE_SHA256 = {
    "main.py": "96ace3c62513c1e14fcf07a20da021ab6428cc0b662565d09bd3812344032686",
    "utils.py": "6c269ad8568d9060bb9d11372fa0f35a4e0aae5fdb380bc5ba6a57511464824b",
    "llms.py": "536c35e27e8e6d7c996bb330ce72acba0d58634715c637009d0ae32d2300c04e",
    "requirements.txt": "e2cdbc3bd3627798ac752d0d38b077bd26202f713b352bb4d1691b25e93db12a",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def authority(root: Path, dspy_root: Path) -> dict[str, Any]:
    head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if head != AUTHORITY_COMMIT:
        raise RuntimeError(f"Optimize Anything authority mismatch: {head}")

    dspy_head = subprocess.check_output(
        ["git", "-C", str(dspy_root), "rev-parse", "HEAD"], text=True
    ).strip()
    if dspy_head != DSPY_COMMIT:
        raise RuntimeError(f"DSPy authority mismatch: {dspy_head}")

    actual = {name: sha256(root / CIRCLE_ROOT / name) for name in SOURCE_SHA256}
    if actual != SOURCE_SHA256:
        raise RuntimeError(f"Circle source hash mismatch: {actual}")

    return {
        "commit": head,
        "dspy_commit": dspy_head,
        "source_sha256": actual,
    }


def load_circle(root: Path):
    sys.path.insert(0, str((root / "src").resolve()))
    sys.path.insert(0, str((root / CIRCLE_ROOT).resolve()))
    import utils  # type: ignore

    return utils


def normalize(value: Any) -> Any:
    if hasattr(value, "tolist"):
        return value.tolist()
    if isinstance(value, dict):
        return {str(key): normalize(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalize(item) for item in value]
    return value


def evaluate(root: Path, dspy_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    verified_authority = authority(root, dspy_root)
    utils = load_circle(root)
    code = payload.get("code", utils.SEED_CODE)
    timeout = int(payload.get("timeout", 600))
    current_best = payload.get("current_best_solution")
    if current_best is not None:
        import numpy as np

        current_best = np.asarray(current_best, dtype=float)
    result = utils.execute_code(code, timeout, current_best, num_circles=26)
    body = result.get("result") or {}
    details = body.get("validation_details") or {}
    circles = normalize(body.get("circles"))

    return {
        "authority": verified_authority,
        "success": bool(result.get("success")),
        "score": details.get("sum_radii", 0.0),
        "circles": circles,
        "circles_sha256": hashlib.sha256(
            json.dumps(circles, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "all_scores": normalize(body.get("all_scores")),
        "error": result.get("error"),
        "code": code,
        "code_sha256": hashlib.sha256(code.encode()).hexdigest(),
        "current_best_input_sha256": hashlib.sha256(
            json.dumps(normalize(current_best), sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
    }


def upstream_probe(root: Path, dspy_root: Path) -> dict[str, Any]:
    verified_authority = authority(root, dspy_root)
    utils = load_circle(root)
    from llms import CIRCLE_PACKING_BACKGROUND  # type: ignore
    from gepa.optimize_anything import (  # type: ignore
        EngineConfig,
        GEPAConfig,
        ReflectionConfig,
        RefinerConfig,
        optimize_anything,
    )

    calls = {"evaluator": 0, "lm": 0, "best": None, "state": []}

    def evaluator(candidate):
        calls["evaluator"] += 1
        calls["state"].append(
            hashlib.sha256(
                json.dumps(normalize(calls["best"]), sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
        )
        result = utils.execute_code(
            candidate["code"], 30, calls["best"], num_circles=26
        )
        if not result["success"]:
            return 0.0, {"error": result.get("error")}
        body = result["result"]
        circles = body["circles"]
        score = body["validation_details"]["sum_radii"]
        calls["best"] = circles
        return score, {"score": score}

    def lm(_prompt):
        calls["lm"] += 1
        return json.dumps({"code": utils.SEED_CODE})

    result = optimize_anything(
        seed_candidate={"code": utils.SEED_CODE},
        evaluator=evaluator,
        objective=(
            "Optimize circle packing code to maximize sum of circle radii "
            "within a unit square for N=26 circles."
        ),
        background=CIRCLE_PACKING_BACKGROUND,
        config=GEPAConfig(
            engine=EngineConfig(
                max_metric_calls=1,
                max_candidate_proposals=0,
                parallel=False,
                max_workers=1,
                cache_evaluation=True,
                frontier_type="objective",
                track_best_outputs=True,
            ),
            reflection=ReflectionConfig(reflection_lm=lm),
            refiner=RefinerConfig(refiner_lm=lm, max_refinements=1),
        ),
    )
    best = result.best_candidate
    return {
        "authority": verified_authority,
        "evaluator_calls": calls["evaluator"],
        "lm_calls": calls["lm"],
        "total_metric_calls": result.total_metric_calls,
        "best_score": result.val_aggregate_scores[result.best_idx],
        "best_code_sha256": hashlib.sha256(best["code"].encode()).hexdigest(),
        "best_has_refiner_prompt": "refiner_prompt" in best,
        "current_best_input_sha256s": calls["state"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--authority-root", default="tmp/optimize-anything-upstream")
    parser.add_argument("--dspy-root", default="tmp/dspy-3.2.1")
    parser.add_argument("--mode", choices=["identity", "evaluate", "upstream-probe"], required=True)
    parser.add_argument("--payload-json")
    args = parser.parse_args()
    root = Path(args.authority_root).resolve()
    dspy_root = Path(args.dspy_root).resolve()

    if args.mode == "identity":
        verified_authority = authority(root, dspy_root)
        utils = load_circle(root)
        from llms import CIRCLE_PACKING_BACKGROUND  # type: ignore
        from gepa.optimize_anything import DEFAULT_REFINER_PROMPT  # type: ignore

        objective = (
            "Optimize circle packing code to maximize sum of circle radii "
            "within a unit square for N=26 circles."
        )
        output = {
            "authority": verified_authority,
            "n": 26,
            "model": "openai/gpt-5.1",
            "timeout_seconds": 600,
            "semantic_max_metric_calls": 150,
            "max_refinements": 1,
            "parallel": True,
            "cache_evaluation": True,
            "seed_code": utils.SEED_CODE,
            "seed_code_sha256": hashlib.sha256(utils.SEED_CODE.encode()).hexdigest(),
            "background": CIRCLE_PACKING_BACKGROUND,
            "objective": objective,
            "refiner_prompt": DEFAULT_REFINER_PROMPT.format(
                objective=objective, background=CIRCLE_PACKING_BACKGROUND
            ),
        }
    elif args.mode == "evaluate":
        payload = json.loads(args.payload_json) if args.payload_json else json.load(sys.stdin)
        output = evaluate(root, dspy_root, payload)
    else:
        output = upstream_probe(root, dspy_root)

    print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
