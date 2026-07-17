from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "dspy_ensemble_differential.py"
CONFIG = ROOT / "benchmarks" / "config" / "ensemble-differential-v1.json"
DSPY = ROOT / "tmp" / "dspy-3.2.1"


class EnsembleDifferentialTest(unittest.TestCase):
    def test_pinned_provider_free_observations(self) -> None:
        env = {
            key: value
            for key, value in os.environ.items()
            if not any(
                marker in key.upper()
                for marker in (
                    "API_KEY",
                    "ACCESS_KEY",
                    "ACCESS_TOKEN",
                    "AUTH_TOKEN",
                    "CLIENT_SECRET",
                    "CREDENTIAL",
                    "PASSWORD",
                    "PRIVATE_KEY",
                    "SECRET",
                    "TOKEN",
                )
            )
        }
        env.update(
            {
                "PYTHONPATH": str(DSPY),
                "PYTHON_DOTENV_DISABLED": "1",
                "DOTENV_DISABLED": "1",
                "PYTHONNOUSERSITE": "1",
            }
        )
        completed = subprocess.run(
            [os.environ.get("PYTHON", "python3"), str(SCRIPT), "--config", str(CONFIG)],
            cwd=ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        receipt = json.loads(completed.stdout)
        self.assertEqual(receipt["status"], "passing")
        self.assertTrue(receipt["provider_free"])
        self.assertEqual(receipt["observations"]["all_program_count"], 5)
        self.assertEqual(receipt["observations"]["subset_count"], 3)
        self.assertTrue(receipt["observations"]["dspy_rejects_deterministic"])


if __name__ == "__main__":
    unittest.main()
