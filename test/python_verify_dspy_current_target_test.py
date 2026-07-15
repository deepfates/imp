import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from verify_dspy_current_target import DSPY_VERSION, verify_target_shape


class VerifyDSPyCurrentTargetTest(unittest.TestCase):
    def test_accepts_only_the_package_metadata_and_optional_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dspy").mkdir()
            (root / f"dspy-{DSPY_VERSION}.dist-info").mkdir()

            verify_target_shape(root)
            (root / ".lock").touch()
            verify_target_shape(root)

    def test_rejects_an_extra_importable_top_level_module(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dspy").mkdir()
            (root / f"dspy-{DSPY_VERSION}.dist-info").mkdir()
            (root / "sitecustomize.py").write_text("raise RuntimeError('unexpected')\n")

            with self.assertRaisesRegex(RuntimeError, "invalid top-level shape"):
                verify_target_shape(root)

    def test_rejects_symbolic_links_inside_the_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "dspy"
            package.mkdir()
            (root / f"dspy-{DSPY_VERSION}.dist-info").mkdir()
            target = package / "target.py"
            target.write_text("VALUE = 1\n")
            (package / "linked.py").symlink_to(target)

            with self.assertRaisesRegex(RuntimeError, "symbolic links"):
                verify_target_shape(root)


if __name__ == "__main__":
    unittest.main()
