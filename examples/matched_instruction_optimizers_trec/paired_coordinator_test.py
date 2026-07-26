#!/usr/bin/env python3
"""No-network regressions for the paired launch coordinator."""

from __future__ import annotations

import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("matched_paired", HERE / "run_paired.py")
assert SPEC is not None and SPEC.loader is not None
paired = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(paired)


class PairedCoordinatorTest(unittest.TestCase):
    def test_preflight_subprocesses_never_receive_provider_authority(self) -> None:
        with mock.patch.dict(os.environ, {"OPENROUTER_API_KEY": "secret"}):
            self.assertNotIn("OPENROUTER_API_KEY", paired.preflight_environment())

    def test_sealed_maximum_and_prior_bound_stay_below_workshop_ceiling(self) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        self.assertEqual(paired.worst_case_usd(manifest), paired.Decimal("38.43072000"))
        self.assertEqual(
            paired.PRIOR_SPEND_BOUND + paired.worst_case_usd(manifest),
            paired.Decimal("40.01421300"),
        )
        self.assertLess(
            paired.PRIOR_SPEND_BOUND + paired.worst_case_usd(manifest),
            paired.WORKSHOP_CEILING,
        )

    def test_any_preflight_failure_starts_neither_peer(self) -> None:
        with (
            mock.patch.object(paired, "preflight", side_effect=RuntimeError("drift")),
            mock.patch.object(paired, "run_peers") as run_peers,
        ):
            with self.assertRaisesRegex(RuntimeError, "drift"):
                paired.coordinate()
            run_peers.assert_not_called()

    def test_preflight_only_never_starts_peers(self) -> None:
        with (
            mock.patch.object(paired, "preflight", return_value={"status": "pass"}),
            mock.patch.object(paired, "run_peers") as run_peers,
            mock.patch("builtins.print"),
        ):
            self.assertEqual(paired.coordinate(preflight_only=True), 0)
            run_peers.assert_not_called()


if __name__ == "__main__":
    unittest.main()
