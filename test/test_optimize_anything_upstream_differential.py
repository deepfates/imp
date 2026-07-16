import copy
import json
import os
import runpy
import socket
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = runpy.run_path(
    str(ROOT / "scripts" / "optimize_anything_upstream_differential.py")
)
MANIFEST = ROOT / "benchmarks/config/optimize-anything-upstream-differential-v1.json"


class OptimizeAnythingUpstreamDifferentialUnitTest(unittest.TestCase):
    def setUp(self):
        self.manifest = SCRIPT["load_manifest"](MANIFEST)

    def test_manifest_binds_three_ordered_domains_and_fixed_controls(self):
        self.assertEqual(
            [domain["id"] for domain in self.manifest["domains"]],
            ["circle_packing_26", "blackbox_problem_46", "swe_bench_flask_5014"],
        )
        self.assertEqual(self.manifest["controls"]["seeds"], [0, 1, 2])
        self.assertEqual(self.manifest["controls"]["max_candidate_proposals"], 2)
        self.assertFalse(self.manifest["controls"]["cache_evaluation"])

    def test_manifest_rejects_missing_prompt_boundary(self):
        drifted = copy.deepcopy(self.manifest)
        drifted["reflection_template"] = drifted["reflection_template"].replace(
            "<side_info>", "side information"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(drifted), encoding="utf-8")
            with self.assertRaisesRegex(
                SCRIPT["ProtocolError"], "<side_info> exactly once"
            ):
                SCRIPT["load_manifest"](path)

    def test_manifest_rejects_relaxed_cache_control(self):
        drifted = copy.deepcopy(self.manifest)
        drifted["controls"]["cache_evaluation"] = True
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(drifted), encoding="utf-8")
            with self.assertRaisesRegex(
                SCRIPT["ProtocolError"], "canonical v1 constants"
            ):
                SCRIPT["load_manifest"](path)

    def test_manifest_rejects_model_evaluator_and_registry_identity_mutation(self):
        mutations = [
            lambda value: value["controls"]["model"].__setitem__("max_tokens", 8192),
            lambda value: value["controls"]["model"].__setitem__(
                "upstream_retries", 99
            ),
            lambda value: value["domains"][1]["evaluator"].__setitem__(
                "objective_call_budget", 200
            ),
            lambda value: value["authority"].__setitem__("commit", "0" * 40),
            lambda value: value["swe_bench"].__setitem__("dataset_revision", "0" * 40),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                drifted = copy.deepcopy(self.manifest)
                mutate(drifted)
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "manifest.json"
                    path.write_text(json.dumps(drifted), encoding="utf-8")
                    with self.assertRaises(SCRIPT["ProtocolError"]):
                        SCRIPT["load_manifest"](path)

    def test_manifest_pass_to_pass_mutation_is_rejected_by_verified_parquet_row(self):
        drifted = copy.deepcopy(self.manifest)
        drifted["swe_bench"]["pass_to_pass"] = drifted["swe_bench"]["pass_to_pass"][:-1]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(drifted), encoding="utf-8")
            loaded = SCRIPT["load_manifest"](path)
            with self.assertRaisesRegex(
                SCRIPT["ProtocolError"], "verified canonical row"
            ):
                SCRIPT["verify_authorities"](loaded)

    def test_local_parquet_row_and_setup_authority_are_verified(self):
        authorities = SCRIPT["verify_authorities"](self.manifest)
        verification = authorities["dataset_verification"]
        _, _, dataset = SCRIPT["load_canonical_authorities"]()

        self.assertEqual(
            verification["parquet_sha256"],
            dataset["source_hashes"][SCRIPT["SWE_BENCH_PARQUET_KEY"]],
        )
        self.assertEqual(
            verification["row_sha256"],
            dataset["source_hashes"][SCRIPT["SWE_BENCH_ROW_KEY"]],
        )
        self.assertEqual(
            verification["environment_setup_commit"],
            dataset["metadata"]["environment_setup_commit"],
        )
        self.assertEqual(
            authorities["source_materialization"], "git_archive_of_pinned_commit"
        )
        self.assertFalse((authorities["upstream"] / ".git").exists())
        self.assertFalse((authorities["flask"] / ".git").exists())
        runtime = authorities["flask_runtime"]
        self.assertRegex(runtime["interpreter_sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(
            runtime["installed_distribution_manifest_sha256"], r"^[0-9a-f]{64}$"
        )
        distributions = runtime["installed_distribution_manifest"]["distributions"]
        self.assertTrue(distributions)
        self.assertTrue(
            all(
                row["installed_file_count"] > 0
                and len(row["installed_files_sha256"]) == 64
                for row in distributions
            )
        )
        self.assertFalse(runtime["cross_platform_reproducible"])

    def test_authority_pristine_check_rejects_untracked_package_initializer(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
            (repository / "src" / "authority").mkdir(parents=True)
            (repository / "src" / "authority" / "module.py").write_text(
                "VALUE = 1\n", encoding="utf-8"
            )
            subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repository),
                    "-c",
                    "user.name=OA Test",
                    "-c",
                    "user.email=oa@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
            )
            untracked = repository / "src" / "shadow" / "__init__.py"
            untracked.parent.mkdir()
            untracked.write_text("RAISE_IF_IMPORTED = True\n", encoding="utf-8")

            with self.assertRaisesRegex(
                SCRIPT["ProtocolError"], "tracked or untracked drift"
            ):
                SCRIPT["verify_pristine_checkout"](
                    repository, "fixture", ("src",)
                )

    def test_blackbox_candidate_cannot_forge_a_file_ledger_or_reported_score(self):
        authorities = SCRIPT["verify_authorities"](self.manifest)
        candidate = """
def solve(objective_function, config, best_xs=None):
    import os
    exposed = dict(getattr(objective_function, '__dict__', {}))
    closure = getattr(objective_function, '__closure__', None) or ()
    for cell in closure:
        try:
            exposed['closure'] = cell.cell_contents
        except Exception:
            pass
    for value in exposed.values():
        if isinstance(value, str) and (value.endswith('.jsonl') or 'ledger' in value):
            with open(value, 'w') as handle:
                handle.write('{"x":[0,0,0,0,0],"score":-1e300}\\n')
    x = [0.0] * config['dim']
    observed = objective_function(x)
    return {'x': x, 'score': -1e300, 'all_attempts': [{'x': x, 'score': -1e300}]}
"""
        result = SCRIPT["evaluate_domain"](
            self.manifest, authorities, "blackbox_problem_46", candidate
        )

        self.assertEqual(result["objective_calls"], 1)
        self.assertEqual(result["side_info"]["objective_completed_calls"], 1)
        self.assertGreater(result["score"], -1.0e9)
        self.assertNotEqual(result["score"], 1.0e300)

    def test_malformed_call_is_counted_before_full_budget_and_cannot_bypass_limit(self):
        authorities = SCRIPT["verify_authorities"](self.manifest)
        candidate = """
def solve(objective_function, config, best_xs=None):
    class Malformed:
        def tolist(self):
            raise ValueError('cannot serialize')
    try:
        objective_function(Malformed())
    except Exception:
        pass
    x = [0.0] * config['dim']
    attempts = []
    for _ in range(config['budget']):
        try:
            score = objective_function(x)
            attempts.append({'x': x, 'score': score})
        except Exception:
            pass
    return {'x': x, 'score': 0.0, 'all_attempts': attempts}
"""
        result = SCRIPT["evaluate_domain"](
            self.manifest, authorities, "blackbox_problem_46", candidate
        )

        side_info = result["side_info"]
        self.assertEqual(result["objective_calls"], 21)
        self.assertEqual(side_info["objective_completed_calls"], 19)
        self.assertEqual(side_info["objective_failed_calls"], 1)
        self.assertEqual(side_info["objective_rejected_calls"], 1)
        self.assertEqual(result["score"], -1.0e9)
        self.assertIn("exceeded", side_info["error"])

    def test_candidate_environment_is_scrubbed_and_output_is_never_persisted(self):
        authorities = SCRIPT["verify_authorities"](self.manifest)
        output_sentinel = "HOSTILE_CANDIDATE_OUTPUT_SHOULD_NOT_PERSIST"
        candidate = f"""
def solve(objective_function, config, best_xs=None):
    import os, sys
    try:
        open({str(ROOT / ".env")!r}, 'rb').read(1)
        host_file_readable = True
    except OSError:
        host_file_readable = False
    parent_secret_readable = False
    try:
        import psutil
        process = psutil.Process(os.getppid())
        for _ in range(3):
            parent_secret_readable |= process.environ().get('IMP_OA_HOST_SECRET') is not None
            process = process.parent()
            if process is None:
                break
    except Exception:
        pass
    present = (
        os.environ.get('IMP_OA_HOST_SECRET') is not None
        or host_file_readable
        or parent_secret_readable
    )
    print('{output_sentinel}')
    print('{output_sentinel}', file=sys.stderr)
    x = [1.0 if present else 0.0] * config['dim']
    score = objective_function(x)
    return {{'x': x, 'score': score, 'all_attempts': [{{'x': x, 'score': score}}]}}
"""
        with mock.patch.dict(os.environ, {"IMP_OA_HOST_SECRET": "provider-secret"}):
            result = SCRIPT["evaluate_domain"](
                self.manifest, authorities, "blackbox_problem_46", candidate
            )

        serialized = json.dumps(result, sort_keys=True)
        self.assertNotIn(output_sentinel, serialized)
        self.assertNotIn("provider-secret", serialized)
        self.assertEqual(result["side_info"]["best_observed"]["x"], [0.0] * 5)
        self.assertFalse(result["side_info"]["candidate_output_retained"])

    def test_executable_style_candidate_result_is_rejected_without_host_side_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "host-side-effect"
            candidate = f"""
class ExecutableResult:
    def __reduce__(self):
        import os
        return (os.system, ("touch {sentinel}",))

def main(timeout, current_best_solution):
    return {{"circles": ExecutableResult(), "all_scores": [1.0]}}
"""
            sandbox = SCRIPT["CandidateSandbox"](Path(os.sys.executable))
            try:
                success, result, _elapsed, error = SCRIPT["run_candidate_json"](
                    candidate,
                    kind="circle_packing_v1",
                    entry_point="main",
                    entry_kwargs={"timeout": 1, "current_best_solution": None},
                    seed=0,
                    timeout_seconds=5,
                    sandbox=sandbox,
                )
            finally:
                sandbox.close()
            sentinel_exists = sentinel.exists()

        self.assertFalse(success)
        self.assertIsNone(result)
        self.assertIn("invalid result", error)
        self.assertFalse(sentinel_exists)

    def test_candidate_json_rejects_non_finite_numbers_at_parse_and_validation(self):
        frame_prefix = (
            '{"schema_version":1,"kind":"blackbox_v1","status":"ok",'
            '"result":{"x":['
        )
        frame_suffix = '],"score":0,"all_attempts":[]}}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            for literal in ("NaN", "Infinity", "-Infinity", "1e999"):
                with self.subTest(literal=literal):
                    path.write_text(
                        frame_prefix + literal + frame_suffix, encoding="utf-8"
                    )
                    with self.assertRaises(SCRIPT["ProtocolError"]):
                        SCRIPT["load_candidate_frame"](path, "blackbox_v1")

        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(recursive_value=value):
                with self.assertRaisesRegex(
                    SCRIPT["ProtocolError"], "non-finite number"
                ):
                    SCRIPT["_bounded_json_value"]({"nested": [value]})

    def test_authenticated_objective_requests_use_strict_bounded_json(self):
        class Problem:
            def do_evaluate(self, _point):
                return 1.0

        invalid_frames = [
            b'{"value":[0,0,0,0,0],"value":[0,0,0,0,0]}',
            b'{"value":[NaN,0,0,0,0]}',
            b'{"value":' + (b"[" * 18) + b"0" + (b"]" * 18) + b"}",
        ]

        def receive_exact(connection, size):
            chunks = bytearray()
            while len(chunks) < size:
                chunks.extend(connection.recv(size - len(chunks)))
            return bytes(chunks)

        def receive(connection):
            size = struct.unpack("!I", receive_exact(connection, 4))[0]
            return json.loads(receive_exact(connection, size))

        with tempfile.TemporaryDirectory() as directory:
            service = SCRIPT["TrustedObjectiveService"](
                Problem(), 20, Path(directory) / "objective.sock"
            )
            with service:
                for frame in invalid_frames:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.connect(str(service.socket_path))
                        connection.sendall(service.token.encode("ascii") + b"\n")
                        self.assertTrue(receive(connection)["accepted"])
                        connection.sendall(struct.pack("!I", len(frame)) + frame)
                        self.assertFalse(receive(connection)["ok"])

        self.assertEqual(service.attempted_calls, len(invalid_frames))
        self.assertEqual(service.failed_calls, len(invalid_frames))
        self.assertEqual(service.observations, [])

    def test_pytest_zero_exit_without_completion_receipt_fails_closed(self):
        class PrematureSuccessSandbox:
            def __init__(self, *_args, **_kwargs):
                pass

            def run(self, *_args, **_kwargs):
                return subprocess.CompletedProcess(args=[], returncode=0)

            def close(self):
                pass

        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            with mock.patch.dict(
                SCRIPT["run_pytest"].__globals__,
                {"CandidateSandbox": PrematureSuccessSandbox},
            ):
                result = SCRIPT["run_pytest"](
                    checkout,
                    Path(os.sys.executable),
                    ["tests/test_blueprints.py::test_empty_name_not_allowed"],
                    5,
                )

        self.assertFalse(result["passed"])
        self.assertEqual(result["exit_status"], 0)
        self.assertIn("completion receipt", result["error"])

    def test_pytest_completion_receipt_requires_each_requested_node(self):
        tests = [
            "tests/test_blueprints.py::test_empty_name_not_allowed",
            "tests/test_blueprints.py::test_register_blueprint",
        ]
        report = """<?xml version=\"1.0\" encoding=\"utf-8\"?>
<testsuites><testsuite name=\"pytest\" tests=\"2\">
<testcase classname=\"tests.test_blueprints\" name=\"test_empty_name_not_allowed\" />
<testcase classname=\"tests.test_blueprints\" name=\"test_register_blueprint\" />
</testsuite></testsuites>"""
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.xml"
            report_path.write_text(report, encoding="utf-8")
            receipt = SCRIPT["verify_pytest_receipt"](report_path, tests)

        self.assertEqual(receipt["expected_tests"], 2)
        self.assertEqual(receipt["completed_tests"], 2)
        self.assertEqual(receipt["passed_tests"], 2)

    def test_flask_forged_exact_receipt_and_clean_exit_are_rejected_before_execution(self):
        authorities = SCRIPT["verify_authorities"](self.manifest)
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "candidate-executed"
            candidate = f"""diff --git a/src/flask/blueprints.py b/src/flask/blueprints.py
--- a/src/flask/blueprints.py
+++ b/src/flask/blueprints.py
@@ -190,6 +190,15 @@ def __init__(
             root_path=root_path,
         )
\x20
+        if not name:
+            import os
+            import sys
+            report_path = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--junitxml="))
+            with open(report_path, "w", encoding="utf-8") as report:
+                report.write('<?xml version="1.0"?><testsuites><testsuite tests="1"><testcase classname="tests.test_blueprints" name="test_empty_name_not_allowed" /></testsuite></testsuites>')
+            open({str(sentinel)!r}, "w").close()
+            os._exit(0)
+
         if "." in name:
             raise ValueError("'name' may not contain a dot '.' character.")
\x20
"""
            forbidden_runner = mock.Mock(
                side_effect=AssertionError("rejected candidate reached pytest")
            )
            with mock.patch.dict(
                SCRIPT["evaluate_flask"].__globals__,
                {"run_pytest": forbidden_runner},
            ):
                result = SCRIPT["evaluate_flask"](
                    candidate,
                    self.manifest["domains"][2]["evaluator"],
                    self.manifest,
                    authorities["flask"],
                    authorities["flask_python"],
                )
            sentinel_exists = sentinel.exists()

        self.assertEqual(result["score"], 0.0)
        self.assertFalse(result["side_info"]["patch_policy"]["admitted"])
        self.assertIn("capability policy", result["side_info"]["error"])
        self.assertFalse(sentinel_exists)
        forbidden_runner.assert_not_called()

    def test_sandbox_writes_only_to_explicit_ephemeral_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkout = root / "checkout"
            checkout.mkdir()
            forbidden = root / "host-side.txt"
            sandbox = SCRIPT["CandidateSandbox"](
                Path(os.sys.executable),
                read_roots=(checkout,),
                write_roots=(checkout,),
            )
            code = """
import errno, pathlib, sys
pathlib.Path(sys.argv[1]).write_text('fixture-write', encoding='utf-8')
try:
    pathlib.Path(sys.argv[2]).write_text('forbidden', encoding='utf-8')
    raise SystemExit(41)
except OSError as exc:
    if exc.errno not in (errno.EPERM, errno.EACCES):
        raise
"""
            try:
                process = sandbox.run(
                    [
                        os.sys.executable,
                        "-c",
                        code,
                        str(checkout / "fixture.txt"),
                        str(forbidden),
                    ],
                    cwd=checkout,
                    timeout=10,
                )
            finally:
                sandbox.close()

            self.assertEqual(process.returncode, 0)
            self.assertEqual((checkout / "fixture.txt").read_text(), "fixture-write")
            self.assertFalse(forbidden.exists())

    def test_candidate_isolation_fails_closed_when_sandbox_exec_is_unavailable(self):
        missing = Path(tempfile.gettempdir()) / "missing-sandbox-exec"
        with self.assertRaisesRegex(
            SCRIPT["ProtocolError"],
            "candidate isolation unavailable: sandbox-exec is missing",
        ):
            SCRIPT["verify_candidate_isolation"](sandbox_exec=missing, force=True)

    def test_flask_patch_boundary_rejects_a_second_path(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            (checkout / "allowed.py").write_text("value = 1\n", encoding="utf-8")
            (checkout / "forbidden.py").write_text("value = 1\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(checkout), "add", "."], check=True)

            patch = """diff --git a/allowed.py b/allowed.py
--- a/allowed.py
+++ b/allowed.py
@@ -1 +1 @@
-value = 1
+value = 2
diff --git a/forbidden.py b/forbidden.py
--- a/forbidden.py
+++ b/forbidden.py
@@ -1 +1 @@
-value = 1
+value = 2
"""
            applied, message = SCRIPT["apply_patch"](checkout, patch, "allowed.py")

        self.assertFalse(applied)
        self.assertIn("must touch only allowed.py", message)


if __name__ == "__main__":
    unittest.main()
