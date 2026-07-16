import hashlib
import json
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/dspy_copro_isolation_differential.py"
CONFIG = ROOT / "test/fixtures/dspy_copro_isolation_differential.json"
PYTHON = ROOT / "tmp/dspy-parity-venv/bin/python"
BETA_PYTHON = ROOT / "tmp/dspy-current-venv/bin/python"
DSPY_TARGET = ROOT / "tmp/dspy-3.2.1"
SETUP = """git clone https://github.com/stanfordnlp/dspy.git tmp/dspy-3.2.1
git -C tmp/dspy-3.2.1 checkout --detach 29448ae12756abdd14bd8796c819247ebb83673c
IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh"""


class DSPyCOPROIsolationDifferentialTest(unittest.TestCase):
    def test_beta_environment_is_not_accepted_as_the_stable_copro_authority(self):
        if not BETA_PYTHON.exists() or not (DSPY_TARGET / ".git").is_dir():
            self.skipTest("beta rejection probe requires both local environments")

        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(DSPY_TARGET)
        completed = subprocess.run(
            [str(BETA_PYTHON), str(SCRIPT), "--config", str(CONFIG)],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Exact setup:", completed.stderr)
        self.assertIn("tmp/dspy-parity-venv/bin/python", completed.stderr)

    def test_pinned_provider_free_copro_fixture_is_isolated_and_bound(self):
        if not PYTHON.exists() or not (DSPY_TARGET / ".git").is_dir():
            self.fail(f"pinned DSPy 3.2.1 fixture environment is missing. Exact setup:\n{SETUP}")

        environment = os.environ.copy()
        environment["PYTHONPATH"] = os.pathsep.join(
            [str(DSPY_TARGET)] + ([environment["PYTHONPATH"]] if environment.get("PYTHONPATH") else [])
        )
        environment["OPENAI_API_KEY"] = "dummy-copro-canary-never-use"
        environment["AWS_SESSION_TOKEN"] = "dummy-copro-cloud-canary-never-use"
        environment["API_KEY"] = "dummy-copro-generic-canary-never-use"
        environment["TOKEN"] = "dummy-copro-generic-token-never-use"
        completed = subprocess.run(
            [str(PYTHON), str(SCRIPT), "--config", str(CONFIG)],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=True,
        )
        artifact = json.loads(completed.stdout)
        fixture = json.loads(CONFIG.read_text())

        self.assertEqual(artifact["status"], "passing")
        self.assertEqual(artifact["fixture_id"], fixture["fixture_id"])
        self.assertEqual(artifact["source"], fixture["source"])
        self.assertEqual(artifact["runtime_identity"]["distribution_version"], "3.2.1")
        self.assertEqual(artifact["runtime_identity"]["module_version"], "3.2.0")
        self.assertEqual(
            artifact["runtime_identity"]["git_commit"],
            "29448ae12756abdd14bd8796c819247ebb83673c",
        )
        self.assertTrue(artifact["runtime_identity"]["git_clean"])
        self.assertEqual(artifact["runtime_identity"]["authority_manifest_verified_files"], 296)
        self.assertEqual(
            artifact["credential_environment"]["provider_credential_names_present"], []
        )
        self.assertTrue(artifact["isolation"]["isolated_process"])
        self.assertFalse(artifact["isolation"]["poison_marker_seen"])
        self.assertEqual(artifact["observations"]["proposal_n"], [3])
        self.assertEqual(artifact["observations"]["proposal_order"], fixture["copro"]["proposal_order"])
        proposal_history = artifact["observations"]["proposal_call_history"]
        self.assertEqual(len(proposal_history), 1)
        self.assertEqual(proposal_history[0]["requested_n"], 3)
        self.assertEqual(proposal_history[0]["response_choice_count"], 3)
        history_order = [
            {"instruction": response["instruction"], "prefix": response["prefix"]}
            for call in proposal_history
            for response in call["responses"]
        ]
        self.assertEqual(artifact["observations"]["proposal_order"], history_order)
        self.assertEqual(artifact["observations"]["evaluation_order"], fixture["copro"]["evaluation_order"])
        self.assertEqual(
            artifact["observations"]["candidate_program_count"],
            fixture["copro"]["candidate_program_count"],
        )
        self.assertEqual(artifact["observations"]["total_calls"], fixture["copro"]["total_calls"])
        self.assertIn("exact Python RNG parity", artifact["scope"]["not_claimed"])
        self.assertIn("provider behavior or effectiveness", artifact["scope"]["not_claimed"])
        self.assertIn("full optimizer parity", artifact["scope"]["not_claimed"])
        self.assertIn(
            "COPRO directly removes an equal-score duplicate candidate",
            artifact["scope"]["claims"],
        )
        self.assertIn(
            "The pinned COPRO source's greater-than-or-equal score guard retains the first record for an identical instruction/prefix duplicate",
            artifact["scope"]["source_supported"],
        )
        self.assertEqual(artifact["fixture_identity"]["script_sha256"], digest(SCRIPT))
        self.assertEqual(artifact["fixture_identity"]["config_sha256"], digest(CONFIG))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
