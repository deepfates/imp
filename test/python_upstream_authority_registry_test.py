import json
import runpy
import sys
import tempfile
import types
import unittest
from contextlib import contextmanager
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = ROOT / "benchmarks" / "authorities.json"


@contextmanager
def fake_dspy_modules():
    names = [
        "dspy",
        "dspy.propose",
        "dspy.propose.grounded_proposer",
        "dspy.teleprompt",
        "dspy.teleprompt.bootstrap",
        "dspy.teleprompt.mipro_optimizer_v2",
        "dspy.teleprompt.simba",
        "dspy.teleprompt.simba_utils",
        "dspy.teleprompt.utils",
    ]
    previous = {name: sys.modules.get(name) for name in names}
    modules = {name: types.ModuleType(name) for name in names}
    modules["dspy"].__version__ = "unused"
    modules["dspy"].propose = modules["dspy.propose"]
    modules["dspy"].teleprompt = modules["dspy.teleprompt"]
    modules["dspy.propose"].grounded_proposer = modules["dspy.propose.grounded_proposer"]
    for child in ("mipro_optimizer_v2", "simba", "simba_utils", "utils"):
        setattr(modules["dspy.teleprompt"], child, modules[f"dspy.teleprompt.{child}"])
    sys.modules.update(modules)
    try:
        yield
    finally:
        for name, module in previous.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module


class PythonUpstreamAuthorityRegistryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with fake_dspy_modules():
            cls.dspy_contract = runpy.run_path(str(ROOT / "scripts" / "dspy_instruction_optimizer_contract.py"))
        cls.gepa_contract = runpy.run_path(str(ROOT / "scripts" / "gepa_v011_contract.py"))
        cls.gepa_current_contract = runpy.run_path(str(ROOT / "scripts" / "gepa_v014_contract.py"))
        cls.registry = cls.dspy_contract["UPSTREAM_REGISTRY"]

    def test_contracts_resolve_pins_from_script_relative_registry(self):
        dspy = self.registry["authorities"]["dspy_instruction_optimizers"]
        gepa = self.registry["authorities"]["gepa_v0_1_1_contract"]
        gepa_current = self.registry["authorities"]["gepa_v0_1_4_contract"]

        self.assertEqual(self.dspy_contract["REGISTRY_PATH"], REGISTRY_PATH)
        self.assertEqual(self.dspy_contract["EXPECTED_VERSION"], dspy["version"])
        self.assertEqual(self.dspy_contract["EXPECTED_COMMIT"], dspy["commit"])
        self.assertEqual(set(self.dspy_contract["SOURCE_PINS"]), set(dspy["source_hashes"]))
        self.assertEqual(self.gepa_contract["REGISTRY_PATH"], REGISTRY_PATH)
        self.assertEqual(self.gepa_contract["EXPECTED_VERSION"], gepa["version"])
        self.assertEqual(self.gepa_contract["EXPECTED_COMMIT"], gepa["commit"])
        self.assertEqual(self.gepa_contract["SOURCE_PINS"], gepa["source_hashes"])
        self.assertEqual(self.gepa_current_contract["REGISTRY_PATH"], REGISTRY_PATH)
        self.assertEqual(self.gepa_current_contract["EXPECTED_VERSION"], gepa_current["version"])
        self.assertEqual(self.gepa_current_contract["EXPECTED_COMMIT"], gepa_current["commit"])
        self.assertEqual(self.gepa_current_contract["SOURCE_PINS"], gepa_current["source_hashes"])

    def test_contracts_reject_valid_looking_source_hash_drift(self):
        for contract in (self.dspy_contract, self.gepa_contract, self.gepa_current_contract):
            drifted = json.loads(REGISTRY_PATH.read_text())
            authority_id = drifted["contracts"][contract["CONTRACT_ID"]]["authority"]
            authority = contract["AUTHORITY"]
            source = next(iter(authority["source_hashes"]))
            actual_hashes = dict(authority["source_hashes"])
            pinned = drifted["pinned_sources"][authority_id]
            if "source_hashes" in pinned:
                pinned["source_hashes"][source] = "0" * 64
            else:
                next(entry for entry in pinned["files"] if entry["path"] == source)[
                    "sha256"
                ] = "0" * 64

            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "registry.json"
                path.write_text(json.dumps(drifted))
                _, authority = contract["load_authority_registry"](path)
                failures = contract["source_hash_failures"](actual_hashes, authority)

            self.assertEqual(len(failures), 1)
            self.assertIn(source, failures[0])

    def test_contracts_reject_missing_registry(self):
        missing = ROOT / "benchmarks" / "does-not-exist.json"
        for contract in (self.dspy_contract, self.gepa_contract, self.gepa_current_contract):
            with self.assertRaisesRegex(RuntimeError, "invalid upstream authority registry"):
                contract["load_authority_registry"](missing)

    def test_contracts_reject_incomplete_registry(self):
        incomplete = json.loads(REGISTRY_PATH.read_text())
        del incomplete["pinned_sources"]["req_llm"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.json"
            path.write_text(json.dumps(incomplete))
            for contract in (self.dspy_contract, self.gepa_contract, self.gepa_current_contract):
                with self.assertRaisesRegex(RuntimeError, "missing required authorities"):
                    contract["load_authority_registry"](path)


if __name__ == "__main__":
    unittest.main()
