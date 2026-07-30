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

    def test_revised_legal_envelope_fits_the_authorized_workshop_spend_ceiling(
        self,
    ) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        self.assertEqual(paired.worst_case_usd(manifest), paired.Decimal("74.55283200"))
        self.assertEqual(paired.WORKSHOP_CEILING, paired.Decimal("100.00"))
        self.assertEqual(
            paired.PRIOR_SPEND_BOUND + paired.worst_case_usd(manifest),
            paired.Decimal("81.15519425"),
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

        imp_source = (HERE / "run_imp.exs").read_text()
        self.assertIn("System.stop(1)", imp_source)
        self.assertLess(
            imp_source.index("atomic_write!(\n          @output"),
            imp_source.index("System.stop(1)"),
        )

    def test_failure_requires_both_cost_preserving_stop_artifacts(self) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        launch_commit = "a" * 40
        source_commits = {
            "imp": launch_commit,
            "dspy": manifest["authorities"]["dspy"]["commit"],
            "gepa": manifest["authorities"]["gepa"]["commit"],
        }
        binding = {
            "manifest_sha256": paired.sha256_file(HERE / "contract.json"),
            "provider_free_gate_result_sha256": manifest["provider_free_gate"][
                "result_sha256"
            ],
            "launch_commit": launch_commit,
            "source_commits": source_commits,
        }
        with tempfile.TemporaryDirectory() as root, mock.patch.object(
            paired, "TMP", Path(root)
        ):
            counts = {
                "task_logical": 1,
                "optimizer_logical": 1,
                "total_logical": 2,
                "transports": 2,
            }
            common = {
                "status": "stopped",
                "actual_cost": 0.01,
                "usd_reserved": 0.087744,
                "rescue_accounting": {
                    "call_budgets": [
                        {
                            "seed": manifest["seeds"][0],
                            "arm": "gepa",
                            "ceiling": manifest["execution"]["call_ceilings"]["gepa"],
                            "counts": counts,
                            "refusal_count": 0,
                        }
                    ],
                    "ledger": {
                        "reserved": 2,
                        "transmitted": 2,
                        "completed": 2,
                        "in_flight": 0,
                        "reserved_not_transmitted": 0,
                        "transmission_observation": "completion_bound",
                    },
                },
                **binding,
            }
            (Path(root) / "imp-result.json").write_text(
                json.dumps(
                    {**common, "lm_results": [{}, {}], "transport_events": [{}, {}]}
                )
            )
            (Path(root) / "upstream-result.json").write_text(
                json.dumps({**common, "calls": [{}, {}]})
            )
            paired.require_rescued_stop_artifacts(manifest, launch_commit)

            drifted = {**common, "actual_cost": 0.1, "calls": [{}, {}]}
            (Path(root) / "upstream-result.json").write_text(json.dumps(drifted))
            with self.assertRaisesRegex(RuntimeError, "exceeds its reserved"):
                paired.require_rescued_stop_artifacts(manifest, launch_commit)

            unavailable = {
                **common,
                "source_commits": {**source_commits, "imp": "unavailable"},
                "calls": [{}, {}],
            }
            (Path(root) / "upstream-result.json").write_text(json.dumps(unavailable))
            with self.assertRaisesRegex(RuntimeError, "source commit binding"):
                paired.require_rescued_stop_artifacts(manifest, launch_commit)

            nonzero_empty = {
                **common,
                "actual_cost": 0.01,
                "usd_reserved": 0.01,
                "rescue_accounting": {
                    "call_budgets": [],
                    "ledger": {
                        "reserved": 0,
                        "transmitted": 0,
                        "completed": 0,
                        "in_flight": 0,
                        "reserved_not_transmitted": 0,
                        "transmission_observation": "completion_bound",
                    },
                },
                "calls": [],
            }
            (Path(root) / "upstream-result.json").write_text(json.dumps(nonzero_empty))
            with self.assertRaisesRegex(RuntimeError, "empty ledgers carry nonzero"):
                paired.require_rescued_stop_artifacts(manifest, launch_commit)

            inflated = {**common, "usd_reserved": 0.2, "calls": [{}, {}]}
            (Path(root) / "upstream-result.json").write_text(json.dumps(inflated))
            with self.assertRaisesRegex(RuntimeError, "does not match manifest-bound"):
                paired.require_rescued_stop_artifacts(manifest, launch_commit)

    def test_rescue_rejects_budget_and_ledger_divergence(self) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        accounting = {
            "call_budgets": [
                {
                    "seed": manifest["seeds"][0],
                    "arm": "baseline",
                    "ceiling": manifest["execution"]["call_ceilings"]["baseline"],
                    "counts": {
                        "task_logical": 1,
                        "optimizer_logical": 0,
                        "total_logical": 1,
                        "transports": 1,
                    },
                    "refusal_count": 0,
                }
            ],
            "ledger": {
                "reserved": 1,
                "transmitted": 0,
                "completed": 0,
                "in_flight": 0,
                "reserved_not_transmitted": 1,
                "transmission_observation": "completion_bound",
            },
        }
        with self.assertRaisesRegex(RuntimeError, "cannot certify"):
            paired.validate_rescue_accounting(
                "upstream", {"rescue_accounting": accounting, "calls": []}, manifest
            )

    def test_imp_rescue_certifies_transmitted_but_incomplete_calls(self) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        accounting = {
            "call_budgets": [
                {
                    "seed": manifest["seeds"][0],
                    "arm": "baseline",
                    "ceiling": manifest["execution"]["call_ceilings"]["baseline"],
                    "counts": {
                        "task_logical": 2,
                        "optimizer_logical": 0,
                        "total_logical": 2,
                        "transports": 2,
                    },
                    "refusal_count": 0,
                }
            ],
            "ledger": {
                "reserved": 2,
                "transmitted": 2,
                "completed": 1,
                "in_flight": 1,
                "reserved_not_transmitted": 0,
            },
        }
        counts = paired.validate_rescue_accounting(
            "imp",
            {
                "rescue_accounting": accounting,
                "lm_results": [{}],
                "transport_events": [{}, {}],
            },
            manifest,
        )
        self.assertEqual(counts["total_logical"], 2)

        fabricated = json.loads(json.dumps(accounting))
        fabricated["ledger"].update(
            {"completed": 2, "in_flight": 0}
        )
        with self.assertRaisesRegex(RuntimeError, "response ledger was not retained"):
            paired.validate_rescue_accounting(
                "imp",
                {
                    "rescue_accounting": fabricated,
                    "lm_results": [{}],
                    "transport_events": [{}, {}],
                },
                manifest,
            )

        misclassified = json.loads(json.dumps(accounting))
        misclassified["ledger"]["in_flight"] = 0
        with self.assertRaisesRegex(RuntimeError, "lifecycle ledger diverges"):
            paired.validate_rescue_accounting(
                "imp",
                {
                    "rescue_accounting": misclassified,
                    "lm_results": [{}],
                    "transport_events": [{}, {}],
                },
                manifest,
            )

    def test_barrier_validation_uses_content_bound_delegated_implementation(
        self,
    ) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        source = paired.delegated_upstream_source(manifest)
        self.assertIn("wait_for_peer_selection", source)
        self.assertIn("held_out_path", source)
        self.assertEqual(
            paired.sha256_file(
                (HERE / manifest["predecessor"]["runner_path"]).resolve()
            ),
            manifest["predecessor"]["runner_sha256"],
        )

    def test_upstream_direct_entry_requires_launch_commit_before_argument_parse(
        self,
    ) -> None:
        env = dict(os.environ)
        env.pop("MATCHED_IFBENCH_V2_EXPECTED_COMMIT", None)
        env.pop("OPENROUTER_API_KEY", None)
        completed = subprocess.run(
            [sys.executable, str(HERE / "run_upstream.py")],
            cwd=HERE.parents[1],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "MATCHED_IFBENCH_V2_EXPECTED_COMMIT is required", completed.stdout
        )
        self.assertNotIn("OPENROUTER_API_KEY", completed.stdout)

    def test_upstream_stop_writer_binds_context_and_normalizes_ledgers(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "matched_upstream_stop_probe", HERE / "run_upstream.py"
        )
        assert spec is not None and spec.loader is not None
        upstream = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(upstream)
        launch_commit = "b" * 40
        payload = {
            "status": "stopped",
            "source_commits": {
                "imp": launch_commit,
                "dspy": upstream.manifest_contract["authorities"]["dspy"]["commit"],
                "gepa": upstream.manifest_contract["authorities"]["gepa"]["commit"],
            },
            "call_budgets": {
                f"{upstream.manifest_contract['seeds'][0]}:baseline": {
                    "ceiling": upstream.manifest_contract["execution"]["call_ceilings"][
                        "baseline"
                    ],
                    "counts": {
                        "task_logical": 1,
                        "optimizer_logical": 0,
                        "total_logical": 1,
                        "transports": 1,
                    },
                    "refusals": [],
                }
            },
            "calls": [{"adapter_transport_dispatch": 1}],
            "actual_cost": 0.0,
            "usd_reserved": 0.007104,
        }
        with tempfile.TemporaryDirectory() as root, mock.patch.dict(
            os.environ, {"MATCHED_IFBENCH_V2_EXPECTED_COMMIT": launch_commit}
        ):
            output = Path(root) / "stopped.json"
            upstream.atomic_write(output, payload)
            stopped = json.loads(output.read_text())
        self.assertEqual(stopped["launch_commit"], launch_commit)
        self.assertEqual(
            stopped["provider_free_gate_result_sha256"],
            upstream.manifest_contract["provider_free_gate"]["result_sha256"],
        )
        self.assertEqual(
            stopped["manifest_sha256"], paired.sha256_file(HERE / "contract.json")
        )
        self.assertEqual(
            stopped["rescue_accounting"]["ledger"],
            {
                "reserved": 1,
                "transmitted": 1,
                "completed": 1,
                "in_flight": 0,
                "reserved_not_transmitted": 0,
                "transmission_observation": "completion_bound",
            },
        )
        paired.validate_rescue_accounting(
            "upstream", stopped, upstream.manifest_contract
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

    def test_compatibility_only_never_starts_peers_or_requires_provider_authority(
        self,
    ) -> None:
        with (
            mock.patch.object(
                paired,
                "compatibility_preflight",
                return_value={"status": "pass", "provider_authority_present": False},
            ),
            mock.patch.object(paired, "preflight") as preflight,
            mock.patch.object(paired, "run_peers") as run_peers,
            mock.patch("builtins.print"),
        ):
            self.assertEqual(paired.coordinate(compatibility_only=True), 0)
            preflight.assert_not_called()
            run_peers.assert_not_called()

    def test_paired_surface_is_explicit_and_v2_only(self) -> None:
        manifest = json.loads((HERE / "contract.json").read_text())
        expected = {
            "call_budget",
            "consumer_lock",
            "consumer_project",
            "contract_runtime",
            "guard_equivalence",
            "imp_entry",
            "imp_preflight",
            "response_evidence",
            "source_identity",
            "two_phase",
            "upstream_entry",
            "coordinator",
        }
        self.assertEqual(set(manifest["paired_surface"]), expected)
        for binding in manifest["paired_surface"].values():
            self.assertNotIn("matched_gepa_mipro_ifbench/", binding["path"])
            self.assertEqual(len(binding["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
