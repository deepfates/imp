from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "dspy_mmgrpo_differential.py"
CONFIG = ROOT / "benchmarks" / "config" / "mmgrpo-differential-v1.json"
DSPY = ROOT / "tmp" / "dspy-3.2.1"


class MmgrpoDifferentialTest(unittest.TestCase):
    def test_pinned_provider_free_observations(self) -> None:
        markers = (
            "API_KEY", "ACCESS_KEY", "ACCESS_TOKEN", "AUTH_TOKEN", "CLIENT_SECRET",
            "CREDENTIAL", "PASSWORD", "PRIVATE_KEY", "SECRET", "TOKEN",
        )
        env = {
            key: value
            for key, value in os.environ.items()
            if not any(marker in key.upper() for marker in markers)
        }
        env.update({
            "PYTHONPATH": str(DSPY),
            "PYTHON_DOTENV_DISABLED": "1",
            "DOTENV_DISABLED": "1",
            "PYTHONNOUSERSITE": "1",
            "HOME": "/tmp",
        })
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--config", str(CONFIG)],
            cwd=ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        receipt = json.loads(completed.stdout)
        observations = receipt["observations"]
        self.assertEqual(receipt["status"], "passing")
        self.assertTrue(receipt["provider_free"])
        self.assertEqual(observations["selected_id_counts"], {"alpha": 4, "beta": 4, "gamma": 4})
        self.assertEqual(observations["successful_group_count"], 12)
        self.assertEqual(observations["successful_rewards"], [0.75])
        self.assertEqual(observations["predictor_group_names"], ["first", "second"])
        self.assertEqual(observations["format_failure_rewards"], [-5.0])


if __name__ == "__main__":
    unittest.main()
