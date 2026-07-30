"""Explicit future-treatment entry for the patched stock-DSPy GEPA boundary.

This module grants no provider authority. A reviewed runner may call
``compile_gepa`` for the GEPA arm only; baseline and MIPRO remain stock DSPy.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any


IMP_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IMP_ROOT / "scripts"))

from dspy_gepa_failure_compat import patched_dspy_gepa  # noqa: E402


def compile_gepa(optimizer: Any, program: Any, **kwargs: Any) -> Any:
    """Compile with the explicit failure-preserving stock-DSPy adapter."""

    with patched_dspy_gepa():
        return optimizer.compile(program, **kwargs)
