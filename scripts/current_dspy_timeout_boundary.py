#!/usr/bin/env python3
"""Probe cancellation of DSPy's documented ``asyncify`` serving primitive.

The program is local and deterministic.  A slow synchronous call attempts a
filesystem side effect after the caller's deadline; a healthy call follows
immediately with the documented async worker capacity set to one.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from verify_dspy_current_target import DSPY_VERSION, verify  # noqa: E402


async def run(target: Path) -> dict:
    verify(target)
    sys.path.insert(0, str(target))
    import dspy  # noqa: PLC0415

    if dspy.__version__ != DSPY_VERSION:
        raise RuntimeError(
            f"expected DSPy {DSPY_VERSION}, imported {dspy.__version__}"
        )

    class BlockingProgram(dspy.Module):
        def forward(self, *, delay_seconds: float, marker_path: str | None):
            time.sleep(delay_seconds)
            if marker_path:
                Path(marker_path).write_text("late side effect\n")
            return {"status": "ok"}

    dspy.configure(async_max_workers=1)
    program = dspy.asyncify(BlockingProgram())

    with tempfile.TemporaryDirectory(prefix="imp-dspy-timeout-boundary-") as directory:
        marker = Path(directory) / "slow-finished"
        started = time.monotonic()
        timed_out = False

        try:
            await asyncio.wait_for(
                program(delay_seconds=0.2, marker_path=str(marker)), timeout=0.025
            )
        except TimeoutError:
            timed_out = True

        timeout_elapsed_ms = (time.monotonic() - started) * 1000
        healthy_started = time.monotonic()
        healthy = await asyncio.wait_for(
            program(delay_seconds=0.0, marker_path=None), timeout=0.1
        )
        healthy_elapsed_ms = (time.monotonic() - healthy_started) * 1000

        await asyncio.sleep(0.25)

        return {
            "dspy_version": dspy.__version__,
            "primitive": "dspy.asyncify + asyncio.wait_for",
            "async_max_workers": 1,
            "caller_timed_out": timed_out,
            "timeout_elapsed_ms": timeout_elapsed_ms,
            "healthy_call_succeeded": healthy == {"status": "ok"},
            "healthy_elapsed_ms": healthy_elapsed_ms,
            "timed_out_worker_side_effect_observed": marker.exists(),
            "scope": {
                "provider_calls": 0,
                "http_server_exercised": False,
                "provider_transport_cancellation_claimed": False,
            },
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dspy-target", type=Path, default=ROOT / "tmp" / "dspy-current-target"
    )
    args = parser.parse_args()
    print(json.dumps(asyncio.run(run(args.dspy_target.resolve())), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
