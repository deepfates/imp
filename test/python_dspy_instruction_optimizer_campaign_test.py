import hashlib
import importlib.util
import json
import tempfile
import threading
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "dspy_instruction_optimizer_campaign.py"
SPEC = importlib.util.spec_from_file_location("instruction_campaign", SCRIPT)
campaign = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(campaign)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FakeRuntime:
    compile_calls = []
    eval_calls = []

    def __init__(self, config):
        self.ledger = None
        self.source_identity = {
            "project": "stanfordnlp/dspy",
            "version": campaign.EXPECTED_VERSION,
            "commit": campaign.EXPECTED_COMMIT,
            "source_hashes": dict(campaign.AUTHORITY["source_hashes"]),
        }
        self.dependency_identity = {"optuna": campaign.EXPECTED_OPTUNA_VERSION}

    def activate_arm(self, arm, ledger):
        self.ledger = ledger

    def examples(self, records):
        return list(records)

    def compile(self, name, options, train, dev, seed):
        self.compile_calls.append(name)
        if name != "baseline":
            self.call()
        return {"name": name, "prompt": f"prompt-{name}", "demos": train[:1]}

    def evaluate_one(self, program, record, split, arm, index):
        self.eval_calls.append((arm, split, index))
        self.call(f"{arm}:{split}:{index}")
        correct = arm != "baseline" or index % 2 == 0
        return {"index": index, "prediction": record["answer"] if correct else "-1", "correct": correct}

    def call(self, prompt="fake"):
        reservation_id = self.ledger.reserve(prompt=prompt)
        self.ledger.reconcile(
            reservation_id,
            {"prompt_tokens": 2, "completion_tokens": 1, "total_tokens": 3},
            0.000003,
        )

    def save_program(self, program, path):
        campaign.atomic_json_write(path, program)

    def load_program(self, path):
        return json.loads(path.read_text())

    def selected_material(self, program):
        return {"prompt": program["prompt"], "demos": program["demos"]}


class CrashAfterDispatchRuntime(FakeRuntime):
    def evaluate_one(self, program, record, split, arm, index):
        if split == "test":
            self.eval_calls.append((arm, split, index))
            self.call(f"{arm}:{split}:{index}")
            raise RuntimeError("simulated post-dispatch interruption")
        return super().evaluate_one(program, record, split, arm, index)


class StopAfterCommittedFrozenRow(campaign.Campaign):
    stopped = False

    def _checkpoint(self, state=None):
        super()._checkpoint(state)
        target = state if state is not None else getattr(self, "state", None)
        test = target and target.get("arms", {}).get("baseline", {}).get("test")
        if not self.stopped and test and len(test.get("rows", [])) == 1 and not test.get("complete"):
            self.stopped = True
            raise RuntimeError("simulated stop after committed row")


class CampaignTest(unittest.TestCase):
    def setUp(self):
        FakeRuntime.compile_calls = []
        FakeRuntime.eval_calls = []
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.config_path = self.root / "campaign.json"
        self.checkpoint = self.root / "checkpoint.json"
        self.output = self.root / "report.json"
        split_specs = {}
        for split in ("train", "dev", "test"):
            path = self.root / f"{split}.jsonl"
            path.write_text('\n'.join(json.dumps({"problem": f"{split}-{i}", "answer": i}) for i in range(2)) + '\n')
            split_specs[split] = {"path": str(path), "sha256": digest(path)}
        self.config = {
            "schema_version": 1,
            "campaign_id": "unit-aime",
            "source_identity": {"version": campaign.EXPECTED_VERSION, "commit": campaign.EXPECTED_COMMIT},
            "dependency_identity": {"optuna": campaign.EXPECTED_OPTUNA_VERSION},
            "dataset": split_specs,
            "provider": {
                "model": "fake/unit",
                "reservation": {
                    "max_output_tokens": 10,
                    "input_tokens_per_byte": 1,
                    "input_usd_per_million": 1.0,
                    "output_usd_per_million": 1.0,
                },
            },
            "budget_scope": "per_arm",
            "per_arm_ceilings": {
                "requests": 100,
                "input_tokens": 500,
                "output_tokens": 500,
                "usd": 1.0,
            },
            "seed": 7,
            "arms": [
                {"name": "baseline", "config": {}},
                {"name": "BootstrapFewShot", "config": {"max_bootstrapped_demos": 1}},
                {"name": "MIPROv2", "config": {"constructor": {"auto": "light"}}},
                {"name": "SIMBA", "config": {"max_steps": 1}},
            ],
        }
        self.write_config()

    def tearDown(self):
        self.directory.cleanup()

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config))

    def runner(self, runtime=FakeRuntime):
        return campaign.Campaign(self.config, self.config_path, self.checkpoint, self.output, runtime_factory=runtime)

    def test_complete_resume_does_not_replay_committed_frozen_rows(self):
        report = self.runner().run()
        self.assertEqual(report["selected_arm"], "BootstrapFewShot")
        self.assertTrue(report["scope"]["research_preflight"])
        self.assertTrue(report["scope"]["not_t3"])
        self.assertEqual(len([call for call in FakeRuntime.eval_calls if call[1] == "test"]), 8)
        self.assertTrue(
            all(
                admission["active_reservations"] == 0
                for admission in report["admission_control_by_arm"].values()
            )
        )
        self.assertGreater(report["aggregate_actual_usage_cost"]["tokens"], 0)
        first_usage = report["actual_usage_cost_by_arm"]

        FakeRuntime.compile_calls = []
        FakeRuntime.eval_calls = []
        resumed = self.runner().run()
        self.assertEqual(FakeRuntime.compile_calls, [])
        self.assertEqual(FakeRuntime.eval_calls, [])
        self.assertEqual(resumed["actual_usage_cost_by_arm"], first_usage)

    def test_committed_frozen_prefix_resumes_at_later_row(self):
        StopAfterCommittedFrozenRow.stopped = False
        interrupted = StopAfterCommittedFrozenRow(
            self.config,
            self.config_path,
            self.checkpoint,
            self.output,
            runtime_factory=FakeRuntime,
        )
        with self.assertRaisesRegex(RuntimeError, "stop after committed row"):
            interrupted.run()
        FakeRuntime.eval_calls = []
        report = self.runner().run()
        self.assertNotIn(("baseline", "test", 0), FakeRuntime.eval_calls)
        self.assertIn(("baseline", "test", 1), FakeRuntime.eval_calls)
        self.assertEqual(report["status"], "complete")

    def test_ambiguous_in_flight_row_requires_resolution_and_is_not_replayed(self):
        with self.assertRaisesRegex(campaign.AmbiguousEvaluation, "explicit resolution required"):
            self.runner(CrashAfterDispatchRuntime).run()
        started_count = len([call for call in FakeRuntime.eval_calls if call[1] == "test"])
        FakeRuntime.eval_calls = []
        with self.assertRaisesRegex(campaign.AmbiguousEvaluation, "explicit resolution required"):
            self.runner().run()
        self.assertEqual(FakeRuntime.eval_calls, [])
        self.assertEqual(started_count, 1)

    def test_request_cap_is_checked_before_subsequent_call(self):
        self.config["per_arm_ceilings"] = {
            "requests": 1,
            "input_tokens": 500,
            "output_tokens": 500,
            "usd": 1.0,
        }
        self.write_config()
        with self.assertRaisesRegex(campaign.BudgetExceeded, "requests ceiling reservation rejected"):
            self.runner().run()
        state = json.loads(self.checkpoint.read_text())
        self.assertEqual(state["usage_by_arm"]["baseline"]["requests"], 1)
        self.assertEqual(state["status"], "failed")

    def test_input_output_and_usd_caps_are_enforced_independently(self):
        cases = (
            ("input_tokens", 1, "input_tokens ceiling reservation"),
            ("output_tokens", 9, "output_tokens ceiling reservation"),
            ("usd", 0.000001, "usd ceiling reservation"),
        )
        for ceiling, value, message in cases:
            with self.subTest(ceiling=ceiling):
                checkpoint = self.root / f"{ceiling}.json"
                output = self.root / f"{ceiling}-out.json"
                config = json.loads(json.dumps(self.config))
                config["campaign_id"] = ceiling
                config["per_arm_ceilings"] = {
                    "requests": 100,
                    "input_tokens": 500,
                    "output_tokens": 500,
                    "usd": 1.0,
                }
                config["per_arm_ceilings"][ceiling] = value
                with self.assertRaisesRegex(campaign.BudgetExceeded, message):
                    campaign.Campaign(config, self.config_path, checkpoint, output, runtime_factory=FakeRuntime).run()

    def test_atomic_reservations_reject_concurrent_overcommit(self):
        reservation = self.config["provider"]["reservation"]
        probe = campaign.UsageLedger(
            {"requests": 2, "input_tokens": 6, "output_tokens": 10, "usd": 1.0},
            reservation=reservation,
        )
        barrier = threading.Barrier(2)
        outcomes = []

        def reserve():
            barrier.wait()
            try:
                outcomes.append(("reserved", probe.reserve(prompt="fake")))
            except campaign.BudgetExceeded:
                outcomes.append(("rejected", None))

        threads = [threading.Thread(target=reserve) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(sorted(kind for kind, _ in outcomes), ["rejected", "reserved"])
        self.assertEqual(probe.snapshot()["requests"], 1)
        self.assertEqual(probe.admission_snapshot()["active_reservations"], 1)

    def test_each_arm_has_an_independent_allowance_and_aggregate_usage(self):
        self.config["per_arm_ceilings"] = {
            "requests": 5,
            "input_tokens": 500,
            "output_tokens": 500,
            "usd": 1.0,
        }
        self.write_config()
        report = self.runner().run()
        requests = {
            name: usage["requests"]
            for name, usage in report["actual_usage_cost_by_arm"].items()
        }
        self.assertEqual(
            requests,
            {"baseline": 4, "BootstrapFewShot": 5, "MIPROv2": 5, "SIMBA": 5},
        )
        self.assertEqual(report["aggregate_actual_usage_cost"]["requests"], 19)
        self.assertEqual(report["budget_scope"], "per_arm")

    def test_mipro_seed_is_fixed_in_constructor_and_compile(self):
        captured = {}

        class Optimizer:
            def __init__(self, **kwargs):
                captured["constructor"] = kwargs

            def compile(self, student, **kwargs):
                captured["compile"] = kwargs
                return student

        runtime = object.__new__(campaign.DSPyRuntime)
        runtime.dspy = types.SimpleNamespace(MIPROv2=Optimizer)
        runtime.lm = object()
        runtime.new_program = lambda: object()
        runtime.compile("MIPROv2", {"constructor": {"auto": "light"}}, [], [], seed=17)
        self.assertEqual(captured["constructor"]["seed"], 17)
        self.assertEqual(captured["compile"]["seed"], 17)

    def test_dataset_tamper_and_config_mismatch_are_rejected(self):
        self.runner().run()
        test_path = Path(self.config["dataset"]["test"]["path"])
        test_path.write_text(test_path.read_text() + json.dumps({"problem": "tamper", "answer": 9}) + "\n")
        with self.assertRaisesRegex(campaign.IdentityError, "dataset test hash mismatch"):
            self.runner()

        test_path.write_text('\n'.join(json.dumps({"problem": f"test-{i}", "answer": i}) for i in range(2)) + '\n')
        changed = json.loads(json.dumps(self.config))
        changed["seed"] = 99
        with self.assertRaisesRegex(campaign.IdentityError, "checkpoint config mismatch"):
            campaign.Campaign(changed, self.config_path, self.checkpoint, self.output, runtime_factory=FakeRuntime)

    def test_held_out_split_overlap_is_rejected(self):
        train = Path(self.config["dataset"]["train"]["path"])
        dev = Path(self.config["dataset"]["dev"]["path"])
        dev.write_text(train.read_text())
        self.config["dataset"]["dev"]["sha256"] = digest(dev)
        with self.assertRaisesRegex(campaign.IdentityError, "dataset leakage"):
            self.runner()

    def test_checkpoint_and_artifact_tamper_are_rejected(self):
        self.runner().run()
        state = json.loads(self.checkpoint.read_text())
        artifact = Path(state["arms"]["baseline"]["artifact"]["path"])
        artifact.write_text("{}\n")
        with self.assertRaisesRegex(campaign.IdentityError, "compiled artifact mismatch"):
            self.runner()

        state["usage_by_arm"]["baseline"]["tokens"] += 1
        campaign.atomic_json_write(self.checkpoint, state)
        with self.assertRaisesRegex(campaign.IdentityError, "checkpoint integrity digest mismatch"):
            self.runner()

    def test_source_identity_config_mismatch_fails_closed(self):
        self.config["source_identity"]["commit"] = "0" * 40
        with self.assertRaisesRegex(campaign.IdentityError, "source_identity"):
            self.runner()

    def test_optuna_dependency_identity_mismatch_fails_closed(self):
        self.config["dependency_identity"]["optuna"] = "4.8.0"
        with self.assertRaisesRegex(campaign.IdentityError, "optuna 4.9.0"):
            self.runner()

    def test_pinned_source_hash_drift_is_rejected_offline(self):
        fake_dspy = types.SimpleNamespace(__version__=campaign.EXPECTED_VERSION)
        module = types.ModuleType("tampered_dspy_source")
        module.__file__ = __file__
        modules = {path: module for path in campaign.AUTHORITY["source_hashes"]}
        with self.assertRaisesRegex(campaign.IdentityError, "pinned DSPy validation failed"):
            campaign.validate_dspy_sources(fake_dspy, modules)


if __name__ == "__main__":
    unittest.main()
