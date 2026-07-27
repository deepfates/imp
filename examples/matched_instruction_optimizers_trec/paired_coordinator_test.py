#!/usr/bin/env python3
"""No-network regressions for the paired launch coordinator."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
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

    def test_revised_legal_envelope_fits_the_authorized_workshop_spend_ceiling(self) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        self.assertEqual(paired.worst_case_usd(manifest), paired.Decimal("59.10912000"))
        self.assertEqual(paired.WORKSHOP_CEILING, paired.Decimal("100.00"))
        self.assertEqual(
            paired.PRIOR_SPEND_BOUND + paired.worst_case_usd(manifest),
            paired.Decimal("62.19247175"),
        )
        self.assertLessEqual(
            paired.PRIOR_SPEND_BOUND + paired.worst_case_usd(manifest),
            paired.WORKSHOP_CEILING,
        )

    def test_graceful_stop_signal_gets_a_bounded_rescue_window(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            artifact = Path(root) / "rescued.json"
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import json,signal,sys,time; p=sys.argv[1]; "
                    "signal.signal(signal.SIGTERM, lambda *_: (open(p,'w').write(json.dumps({'status':'stopped','actual_cost':0.0,'usd_reserved':0.0})), sys.exit(0))); "
                    "time.sleep(30)",
                    str(artifact),
                ],
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            time.sleep(0.1)
            paired.stop_peer(child)
            child.wait(timeout=3)
            self.assertEqual(json.loads(artifact.read_text())["status"], "stopped")

    def test_failure_requires_both_cost_preserving_stop_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as root, mock.patch.object(paired, "TMP", Path(root)):
            payload = {"status": "stopped", "actual_cost": 0.25, "usd_reserved": 1.0}
            for runtime in ("imp", "upstream"):
                (Path(root) / f"{runtime}-result.json").write_text(json.dumps(payload))
            paired.require_rescued_stop_artifacts()
            (Path(root) / "imp-result.json").write_text(json.dumps({"status": "stopped"}))
            with self.assertRaisesRegex(RuntimeError, "actual cost"):
                paired.require_rescued_stop_artifacts()

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
