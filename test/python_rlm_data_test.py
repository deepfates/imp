import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATA_ROOT = ROOT / "benchmarks" / "data" / "rlm"
CONFIG_PATH = ROOT / "benchmarks" / "config" / "rlm-paper-protocol-v3.json"
OOLONG_PAIRS_NORMALIZED_SHA256 = "11b58e289d19152c3e6fa80f347e250021a6fe25f181925bac8e4e4ca2a4d4cc"


def load_normalizer():
    spec = importlib.util.spec_from_file_location("rlm_normalize_test", DATA_ROOT / "normalize.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RLMDataTest(unittest.TestCase):
    def test_pinned_oolong_pairs_identity_is_complete_and_t2_only(self):
        provenance = json.loads((DATA_ROOT / "provenance.json").read_text())
        family = provenance["families"]["oolong_pairs"]
        grid = [2**power for power in range(10, 21)]

        self.assertEqual(family["status"], "t2_operator_reconstructed_inputs_and_gold_complete")
        self.assertEqual(family["normalized_sha256"], OOLONG_PAIRS_NORMALIZED_SHA256)
        self.assertEqual(family["normalized_layout"], "shared_context_row_v1")
        self.assertEqual(family["reserved_context_row_id"], "__contexts__")
        self.assertEqual(family["revision"], "d1e1522b86ac0c169bbc890b0471408aaa29e8fa")
        self.assertEqual(list(map(int, family["gold_sha256_by_context"])), grid)
        self.assertEqual(list(map(int, family["context_window_id_by_context_size"])), grid)
        self.assertEqual(set(family["gold_source_files"]), {f"data/oolong-pairs-{size}.json" for size in grid})
        self.assertEqual(len(family["context_source_files"]), 7)
        self.assertTrue(all(len(value) == 64 for value in family["gold_source_files"].values()))
        self.assertTrue(all(len(value) == 64 for value in family["context_source_files"].values()))

        dataset = json.loads(CONFIG_PATH.read_text())["datasets"]["oolong_pairs"]
        self.assertEqual(dataset["sha256"], OOLONG_PAIRS_NORMALIZED_SHA256)
        self.assertEqual(dataset["context_grid"], grid)
        self.assertEqual(dataset["metric"], "set_f1")
        self.assertEqual(dataset["source"], "https://huggingface.co/datasets/mit-oasys/oolong-pairs + oolongbench/oolong-synth")
        self.assertEqual(dataset["revision"], "pairs@d1e1522b86ac0c169bbc890b0471408aaa29e8fa; contexts@49898a421f4b14f2c9cae084d2d270f930ff4c90")

    def test_normalizer_preserves_size_specific_gold_and_canonical_contexts(self):
        normalize = load_normalizer()
        original_loader = normalize._load_oolong_pair_contexts
        normalize._load_oolong_pair_contexts = lambda _sources: {
            str(size): f"context-{size}" for size in normalize.OOLONG_PAIRS_CONTEXT_GRID
        }

        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                questions = [
                    {"id": str(index), "question": f"question-{index}", "type": "list_of_answers"}
                    for index in range(1, 21)
                ]
                questions_path = root / "questions.json"
                questions_path.write_text(json.dumps(questions))
                answers_dir = root / "answers"
                answers_dir.mkdir()
                for size in normalize.OOLONG_PAIRS_CONTEXT_GRID:
                    rows = [
                        {"id": str(index), "question": f"question-{index}", "answer": ([f"({index}, {index + 1})"] if index == 1 else [])}
                        for index in range(1, 21)
                    ]
                    (answers_dir / f"oolong-pairs-{size}.json").write_text(json.dumps(rows))

                output = root / "normalized.jsonl"
                normalize.normalize_oolong_pairs(questions_path, answers_dir, [], output)
                rows = [json.loads(line) for line in output.read_text().splitlines()]

            self.assertEqual(len(rows), 21)
            self.assertEqual(rows[0]["id"], "__contexts__")
            self.assertEqual(set(rows[0]["contexts"]), {str(size) for size in normalize.OOLONG_PAIRS_CONTEXT_GRID})
            self.assertNotIn("gold_by_context_size", rows[0])
            self.assertEqual(rows[1]["gold_by_context_size"]["1024"], ["(1, 2)"])
            self.assertNotIn("contexts", rows[1])
            self.assertEqual(rows[1]["revision"], normalize.OOLONG_PAIRS_DATASET_REVISION)
        finally:
            normalize._load_oolong_pair_contexts = original_loader


if __name__ == "__main__":
    unittest.main()
