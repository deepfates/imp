"""Explicit DSPy 3.2.1 -> GEPA 0.1.4 source compatibility boundary.

DSPy 3.2.1's package metadata pins ``gepa[dspy]==0.0.27``.  Its public GEPA
adapter also documents ``gepa_kwargs`` as a direct pass-through to
``gepa.optimize``.  GEPA did not expose ``acceptance_criterion`` until 0.1.2,
so a DSPy 3.2.1 environment using its stock dependency cannot accept that
option.  Imp's pinned GEPA authority is 0.1.4.

This module makes the version override explicit before either package is
imported.  It never drops or translates an optimizer option.  Callers must run
DSPy 3.2.1's public adapter against the exact GEPA 0.1.4 source tree, and the
bridge rejects any source, import-order, signature, or dependency declaration
drift before optimizer construction.
"""

from __future__ import annotations

from dataclasses import dataclass
import inspect
from pathlib import Path
import subprocess
import sys
from typing import Any


DSPY_COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"
GEPA_COMMIT = "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"
DSPY_VERSION = "3.2.1"
GEPA_VERSION = "0.1.4"
DSPY_DECLARED_GEPA = "0.0.27"
ACCEPTANCE_FIRST_RELEASE = "0.1.2"


class VersionBridgeError(RuntimeError):
    """The pinned DSPy/GEPA compatibility boundary is not authenticated."""


@dataclass(frozen=True)
class VersionBridge:
    dspy_root: Path
    gepa_root: Path
    dspy_commit: str
    gepa_commit: str
    dspy_version: str
    gepa_version: str
    dspy_declared_gepa: str
    acceptance_first_release: str

    def as_dict(self) -> dict[str, str]:
        return {
            "dspy_commit": self.dspy_commit,
            "gepa_commit": self.gepa_commit,
            "dspy_version": self.dspy_version,
            "gepa_version": self.gepa_version,
            "dspy_declared_gepa": self.dspy_declared_gepa,
            "acceptance_first_release": self.acceptance_first_release,
            "mode": "explicit_gepa_source_override_before_dspy_import",
        }


def _git_head(root: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()


def _tag_has_acceptance(root: Path, tag: str) -> bool:
    source = subprocess.run(
        ["git", "-C", str(root), "show", f"{tag}:src/gepa/api.py"],
        check=True,
        text=True,
        capture_output=True,
    ).stdout
    return "    acceptance_criterion:" in source


def install_source_bridge(dspy_root: Path, gepa_root: Path) -> VersionBridge:
    """Authenticate and prepend GEPA then DSPy before either can be imported."""

    already = sorted(name for name in sys.modules if name == "dspy" or name.startswith("dspy.") or name == "gepa" or name.startswith("gepa."))
    if already:
        raise VersionBridgeError(
            "DSPy/GEPA source bridge must run before optional imports; already loaded: "
            + ", ".join(already[:5])
        )

    dspy_root = dspy_root.resolve()
    gepa_root = gepa_root.resolve()
    if _git_head(dspy_root) != DSPY_COMMIT:
        raise VersionBridgeError("DSPy source commit does not match pinned 3.2.1")
    if _git_head(gepa_root) != GEPA_COMMIT:
        raise VersionBridgeError("GEPA source commit does not match pinned 0.1.4")

    pyproject = (dspy_root / "pyproject.toml").read_text()
    declaration = f'"gepa[dspy]=={DSPY_DECLARED_GEPA}"'
    if declaration not in pyproject:
        raise VersionBridgeError("DSPy 3.2.1 GEPA dependency declaration drifted")
    if _tag_has_acceptance(gepa_root, "v0.1.1"):
        raise VersionBridgeError("GEPA 0.1.1 unexpectedly exposes acceptance_criterion")
    if not _tag_has_acceptance(gepa_root, "v0.1.2"):
        raise VersionBridgeError("GEPA 0.1.2 no longer establishes acceptance_criterion")
    if not _tag_has_acceptance(gepa_root, "v0.1.4"):
        raise VersionBridgeError("GEPA 0.1.4 lacks acceptance_criterion")

    # Insert DSPy first, then GEPA at index zero: GEPA must win over the
    # environment's DSPy-owned 0.0.27 dependency before DSPy imports it.
    sys.path.insert(0, str(dspy_root))
    sys.path.insert(0, str(gepa_root / "src"))
    return VersionBridge(
        dspy_root=dspy_root,
        gepa_root=gepa_root,
        dspy_commit=DSPY_COMMIT,
        gepa_commit=GEPA_COMMIT,
        dspy_version=DSPY_VERSION,
        gepa_version=GEPA_VERSION,
        dspy_declared_gepa=DSPY_DECLARED_GEPA,
        acceptance_first_release=ACCEPTANCE_FIRST_RELEASE,
    )


def authenticate_loaded_runtime(bridge: VersionBridge, dspy: Any, gepa: Any) -> None:
    """Reject a shadowed 0.0.27 import or an incompatible public API."""

    dspy_file = Path(inspect.getfile(dspy)).resolve()
    gepa_file = Path(inspect.getfile(gepa)).resolve()
    if bridge.dspy_root not in dspy_file.parents:
        raise VersionBridgeError(f"DSPy imported from unpinned path: {dspy_file}")
    if (bridge.gepa_root / "src") not in gepa_file.parents:
        raise VersionBridgeError(f"GEPA imported from unpinned path: {gepa_file}")
    # The exact 3.2.1 tag/commit retains ``dspy.__version__ == \"3.2.0\"`` in
    # source while its built distribution metadata is 3.2.1.  Commit identity
    # owns this bridge; accept only that known upstream packaging discrepancy.
    if str(getattr(dspy, "__version__", "")) not in {"3.2.0", DSPY_VERSION}:
        raise VersionBridgeError("loaded DSPy module metadata is not the pinned 3.2.1 source")

    parameters = inspect.signature(gepa.optimize).parameters
    required = {
        "acceptance_criterion",
        "callbacks",
        "stop_callbacks",
        "selection_strategy",
        "module_selector",
        "max_metric_calls",
    }
    missing = sorted(required - parameters.keys())
    if missing:
        raise VersionBridgeError(
            "GEPA 0.1.4 public optimize surface is incomplete: " + ", ".join(missing)
        )
