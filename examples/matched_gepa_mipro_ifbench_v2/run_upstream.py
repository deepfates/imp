#!/usr/bin/env python3
"""Unsealed v2 upstream runner using the explicit stock-DSPy task module.

All transport, accounting, optimizer, scoring, and held-out behavior remains
owned by the permanently stopped v1 runner. This entry point replaces only its
program factory before invoking it. It has no network authority until a v2
manifest is separately reviewed and sealed.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
V1_RUNNER = HERE.parent / "matched_gepa_mipro_ifbench" / "run_upstream.py"
sys.path.insert(0, str(V1_RUNNER.parent))
SPEC = importlib.util.spec_from_file_location("matched_ifbench_v1_upstream", V1_RUNNER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load stopped v1 runner at {V1_RUNNER}")
v1 = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = v1
SPEC.loader.exec_module(v1)

v1.MANIFEST_PATH = HERE / "contract.json"
v1.OUTPUT = Path(
    os.environ.get(
        "UPSTREAM_MATCHED_IFBENCH_V2_OUTPUT",
        v1.IMP_ROOT / "tmp" / "matched_gepa_mipro_ifbench_v2" / "upstream-result.json",
    )
)
v1.SELECTION_OUTPUT = Path(str(v1.OUTPUT) + ".selection-sealed.json")


def build_program(dspy: Any, task_lm: Any):
    from ifbench_stock_module import IFBenchCoT2StageModule

    program = IFBenchCoT2StageModule()
    program.set_lm(task_lm)
    return program


# v1 has one program factory used before baseline, GEPA, or MIPRO dispatch.
# Replacing that factory guarantees every v2 upstream arm receives the
# translated class without changing the stopped source or manifest.
v1.build_program = build_program


if __name__ == "__main__":
    v1.main()
