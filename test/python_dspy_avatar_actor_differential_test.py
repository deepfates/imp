import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/dspy_avatar_actor_differential.py"
CONFIG = ROOT / "benchmarks/config/avatar-actor-differential-v1.json"
PYTHON = ROOT / "tmp/dspy-parity-venv/bin/python"
DSPY = ROOT / "tmp/dspy-3.2.1"
COMMIT = "29448ae12756abdd14bd8796c819247ebb83673c"


class AvatarActorDifferentialTest(unittest.TestCase):
    def test_authenticated_provider_free_actor_observations(self):
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(DSPY)
        environment["OPENAI_API_KEY"] = "dummy-avatar-actor-provider-canary-never-use"
        environment["AWS_SESSION_TOKEN"] = "dummy-avatar-actor-cloud-canary-never-use"
        environment["TOKEN"] = "dummy-avatar-actor-token-canary-never-use"
        completed = subprocess.run(
            [str(PYTHON), str(SCRIPT), "--config", str(CONFIG)],
            cwd=ROOT, env=environment, capture_output=True, text=True, check=True,
        )
        report = json.loads(completed.stdout)
        fixture = json.loads(CONFIG.read_text())
        self.assertEqual(report["status"], "passing")
        self.assertEqual(report["source"], fixture["source"])
        self.assertEqual(report["observations"], fixture["expected"])
        self.assertEqual(report["runtime_identity"]["git_commit"], COMMIT)
        self.assertTrue(report["runtime_identity"]["git_clean"])
        self.assertEqual(report["runtime_identity"]["authority_manifest_verified_files"], 296)
        self.assertEqual(report["credential_environment"]["provider_credential_names_present"], [])
        self.assertTrue(report["isolation"]["isolated_process"])
        self.assertIn("task effectiveness", report["scope"]["not_claimed"])


if __name__ == "__main__":
    unittest.main()
