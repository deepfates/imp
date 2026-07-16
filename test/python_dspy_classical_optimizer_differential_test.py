import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/dspy_classical_optimizer_differential.py"
CONFIG = ROOT / "benchmarks/config/classical-optimizer-differential-v1.json"
PYTHON = ROOT / "tmp/dspy-parity-venv/bin/python"
DSPY = ROOT / "tmp/dspy-3.2.1"
COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"


class ClassicalOptimizerDifferentialTest(unittest.TestCase):
    def test_pinned_provider_free_observations_and_scope(self):
        self.assertTrue(PYTHON.exists())
        self.assertTrue((DSPY / ".git").is_dir())
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(DSPY)
        environment["OPENAI_API_KEY"] = "dummy-classical-provider-canary-never-use"
        environment["AWS_SESSION_TOKEN"] = "dummy-classical-cloud-canary-never-use"
        environment["API_KEY"] = "dummy-classical-generic-canary-never-use"
        environment["TOKEN"] = "dummy-classical-token-canary-never-use"

        completed = subprocess.run(
            [str(PYTHON), str(SCRIPT), "--config", str(CONFIG)],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=True,
        )
        report = json.loads(completed.stdout)
        fixture = json.loads(CONFIG.read_text())

        self.assertEqual(report["status"], "passing")
        self.assertEqual(report["source"], fixture["source"])
        self.assertEqual(report["runtime_identity"]["git_commit"], COMMIT)
        self.assertTrue(report["runtime_identity"]["git_clean"])
        self.assertEqual(report["runtime_identity"]["authority_manifest_verified_files"], 296)
        self.assertEqual(report["credential_environment"]["provider_credential_names_present"], [])
        self.assertTrue(report["isolation"]["isolated_process"])
        self.assertEqual(report["observations"]["bootstrap_few_shot"], fixture["bootstrap_few_shot"]["expected"])
        self.assertEqual(report["observations"]["random_search"], fixture["random_search"]["expected"])

        for family in ("bootstrap_few_shot", "random_search"):
            exclusions = report["scopes"][family]["not_claimed"]
            self.assertIn("exact Python RNG parity", exclusions)
            self.assertIn("provider behavior or effectiveness", exclusions)
            self.assertIn("full optimizer parity", exclusions)


if __name__ == "__main__":
    unittest.main()
