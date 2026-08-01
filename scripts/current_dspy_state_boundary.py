#!/usr/bin/env python3
"""Exercise the current DSPy state boundary without provider calls.

This is a deliberately narrow operational comparison input.  It records what
DSPy's ordinary JSON state path guarantees and what it intentionally leaves to
the surrounding application.  It does not grade either runtime or exercise a
serving framework.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from verify_dspy_current_target import DSPY_VERSION, verify  # noqa: E402


def import_dspy(target: Path):
    verify(target)
    sys.path.insert(0, str(target))
    import dspy  # noqa: PLC0415

    if dspy.__version__ != DSPY_VERSION:
        raise RuntimeError(
            f"expected DSPy {DSPY_VERSION}, imported {dspy.__version__}"
        )
    return dspy


def fresh_load(target: Path, state_path: Path) -> None:
    dspy = import_dspy(target)
    program = dspy.Predict("question -> answer")
    program.load(state_path)
    print(
        json.dumps(
            {
                "instruction": program.signature.instructions,
                "lm_api_base": getattr(program.lm, "kwargs", {}).get("api_base")
                if program.lm
                else None,
            },
            sort_keys=True,
        )
    )


def run(target: Path, python: Path) -> dict:
    dspy = import_dspy(target)

    with tempfile.TemporaryDirectory(prefix="imp-dspy-state-boundary-") as directory:
        root = Path(directory)
        state_path = root / "program.json"
        tampered_path = root / "program-tampered.json"
        whole_program_path = root / "whole-program"

        lm = dspy.LM(
            "openai/gpt-4o-mini",
            api_key="sk-operational-boundary-canary",
            api_base="https://private-endpoint.invalid/v1",
        )
        program = dspy.Predict("question -> answer")
        program.lm = lm
        program.signature = program.signature.with_instructions("selected instruction")
        previous_umask = os.umask(0o022)
        try:
            program.save(state_path)
        finally:
            os.umask(previous_umask)

        encoded = state_path.read_text()
        state = json.loads(encoded)
        mode = stat.S_IMODE(state_path.stat().st_mode)
        state_without_metadata = {k: v for k, v in state.items() if k != "metadata"}

        child = subprocess.run(
            [
                str(python),
                str(Path(__file__).resolve()),
                "--fresh-load",
                str(state_path),
                "--dspy-target",
                str(target),
            ],
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "PYTHONPATH": ""},
        )
        fresh = json.loads(child.stdout)

        tampered = json.loads(encoded)
        tampered["signature"]["instructions"] = "operator-edited instruction"
        tampered_path.write_text(json.dumps(tampered))
        edited = dspy.Predict("question -> answer")
        edited.load(tampered_path)

        transactional = dspy.Predict("question -> answer")
        before = transactional.signature.instructions
        invalid = json.loads(encoded)
        invalid.pop("signature")
        invalid_path = root / "invalid.json"
        invalid_path.write_text(json.dumps(invalid))
        invalid_rejected = False
        try:
            transactional.load(invalid_path)
        except Exception:
            invalid_rejected = True

        program.save(whole_program_path, save_program=True)
        pickle_requires_opt_in = False
        try:
            dspy.load(whole_program_path)
        except ValueError as error:
            pickle_requires_opt_in = "allow_pickle=True" in str(error)

        return {
            "dspy_version": dspy.__version__,
            "state_json": {
                "fresh_process_instruction": fresh["instruction"],
                "api_key_absent": "sk-operational-boundary-canary" not in encoded,
                "endpoint_config_present":
                    "https://private-endpoint.invalid/v1" in encoded,
                "unsafe_endpoint_removed_on_default_load": fresh["lm_api_base"] is None,
                "mode": f"{mode:04o}",
                "creation_umask": "0022",
                "owner_private_by_default": mode & 0o077 == 0,
                "integrity_field_present": any(
                    "sha" in key.lower() or "checksum" in key.lower()
                    for key in state_without_metadata
                ),
                "operator_edit_accepted":
                    edited.signature.instructions == "operator-edited instruction",
                "invalid_state_rejected_transactionally":
                    invalid_rejected
                    and transactional.signature.instructions == before,
            },
            "whole_program": {
                "format": "cloudpickle",
                "untrusted_load_requires_explicit_opt_in": pickle_requires_opt_in,
            },
            "scope": {
                "provider_calls": 0,
                "serving_framework_exercised": False,
                "supervision_compared": False,
            },
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dspy-target", type=Path, default=ROOT / "tmp" / "dspy-current-target"
    )
    parser.add_argument(
        "--python", type=Path, default=ROOT / "tmp" / "dspy-current-venv" / "bin" / "python"
    )
    parser.add_argument("--fresh-load", type=Path)
    args = parser.parse_args()

    if args.fresh_load:
        fresh_load(args.dspy_target.resolve(), args.fresh_load.resolve())
    else:
        print(
            json.dumps(
                run(args.dspy_target.resolve(), args.python),
                indent=2,
                sort_keys=True,
            )
        )


if __name__ == "__main__":
    main()
