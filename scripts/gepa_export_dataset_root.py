#!/usr/bin/env python3
"""Export GEPA artifact benchmark splits into Imp GEPA campaign JSONL format."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List


DATASET_ALIASES = {
    "hotpot_qa": "hotpotqa/hotpot_qa",
    "hover": "hover-nlp/hover",
}

DATASET_REVISIONS = {
    "AI-MO/aimo-validation-aime": "13f9e12f613e720c2a2b2f345dd04b998a29494d",
    "MathArena/aime_2025": "c94da77eb22bbd6439e62a323bec18493a421302",
    "hotpotqa/hotpot_qa": "1908d6afbbead072334abe2965f91bd2709910ab",
    "hover-nlp/hover": "c0e43052759879b3461642ca6c0dd26658f47691",
    "livebench/math": "bb66571c8ccf32d3df9e6f48b920d3770ff4aacb",
    "Columbia-NLP/PUPA": "9981b49b6ced0033988a224b6712895ebf119294",
}

FAMILY_DATASETS = {
    "AIMEBench": ["AI-MO/aimo-validation-aime", "MathArena/aime_2025"],
    "HotpotQABench": ["hotpotqa/hotpot_qa"],
    "hoverBench": ["hover-nlp/hover"],
    "LiveBenchMathBench": ["livebench/math"],
    "Papillon": ["Columbia-NLP/PUPA"],
}

HOVER_RAW_SOURCE = {
    "repository": "https://github.com/hover-nlp/hover",
    "commit": "39b84697f196308f398a251a7aea9b82ae0f0562",
    "files": {
        "data/hover/hover_train_release_v1.1.json": {
            "bytes": 9_205_582,
            "sha256": "1f1cd57abd616fa00c70bdc575ce77c16fc6cf1a6cffd5ff87c208030a336bb6",
        },
        "data/hover/hover_dev_release_v1.1.json": {
            "bytes": 2_153_439,
            "sha256": "67c14858f2d7fcdb96b6fe3d538ffcd6f76e3ba594aa2c0cd4359f601101e89d",
        },
        "data/hover/hover_test_release_v1.1.json": {
            "bytes": 898_814,
            "sha256": "c58e7fc59b4962213a5a6d41d746384ee88a7645e36cb3a439969cf762c8ec24",
        },
    },
}

HOVER_FROZEN_SPLITS = {
    "train": {
        "count": 150,
        "sha256": "448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
    },
    "dev": {
        "count": 300,
        "sha256": "b342dbaaa4516e55b7f4f7ac046828c2201952e69de5b97751173238674a74a7",
    },
    "test": {
        "count": 300,
        "sha256": "cf1b51ca6ed32c21355a954624d88b396d3e963585549cea68308b519c5a8807",
    },
}

HOVER_IDENTITY_DISJOINT_SPLITS = {
    "train": {
        "count": 150,
        "sha256": "448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
    },
    "dev": {
        "count": 300,
        "sha256": "052fdda83d8e7fff83c7f4db67cd1a2a8cb66047e6cd68ecfe14310dcbf93602",
    },
    "test": {
        "count": 300,
        "sha256": "cf1b51ca6ed32c21355a954624d88b396d3e963585549cea68308b519c5a8807",
    },
}


FAMILY_SPECS: Dict[str, Dict[str, Any]] = {
    "AIMEBench": {
        "module": "gepa_artifact.benchmarks.AIME",
        "program": "CoT",
        "signature": "problem -> answer",
        "instructions": "Solve the problem and provide the answer in the correct format.",
        "input_keys": ["problem"],
        "output_key": "answer",
        "metric_calls": 1839,
        "upstream_metric": "AIME.metric integer exact match",
    },
    "HotpotQABench": {
        "module": "gepa_artifact.benchmarks.hotpotQA",
        "program": "HotpotMultiHop",
        "signature": "question -> answer",
        "instructions": "Answer the multi-hop question using retrieved evidence.",
        "input_keys": ["question"],
        "output_key": "answer",
        "metric_calls": 6871,
        "upstream_metric": "dspy.evaluate.answer_exact_match",
    },
    "hoverBench": {
        "module": "gepa_artifact.benchmarks.hover",
        "program": "HoverMultiHop",
        "signature": "claim -> retrieved_docs",
        "instructions": "Verify the claim using retrieved supporting evidence.",
        "input_keys": ["claim"],
        "output_key": "retrieved_docs",
        "metric_calls": 7051,
        "upstream_metric": "hover_utils.discrete_retrieval_eval",
    },
    "IFBench": {
        "module": "gepa_artifact.benchmarks.IFBench",
        "program": "IFBenchCoT2StageProgram",
        "signature": "prompt -> response",
        "instructions": "Respond to the query while satisfying all instruction-following constraints.",
        "input_keys": ["prompt"],
        "output_key": "response",
        "metric_calls": 3593,
        "upstream_metric": "IFBench.ifbench_metric.metric",
    },
    "LiveBenchMathBench": {
        "module": "gepa_artifact.benchmarks.livebench_math",
        "program": "CoT",
        "signature": "question -> answer",
        "instructions": "Solve the question and provide the answer in the correct format.",
        "input_keys": ["question"],
        "output_key": "answer",
        "metric_calls": 1839,
        "upstream_metric": "livebench_math.calculate_livebench_score",
    },
    "Papillon": {
        "module": "gepa_artifact.benchmarks.papillon",
        "program": "PAPILLON",
        "signature": "user_query -> llm_request, response",
        "instructions": "Answer the user query while preserving privacy-sensitive information.",
        "input_keys": ["user_query"],
        "output_key": "response",
        "metric_calls": 2426,
        "upstream_metric": "papillon_utils.compute_overall_score",
    },
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gepa-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--max-per-split", type=int)
    parser.add_argument("--family", choices=sorted(FAMILY_SPECS))
    parser.add_argument("--hover-source-root")
    parser.add_argument("--hover-identity-disjoint", action="store_true")
    args = parser.parse_args()
    dataset_scope = "full" if args.max_per_split is None else "capped"

    gepa_root = Path(args.gepa_root).resolve()
    out = Path(args.out).resolve()
    source = source_identity(gepa_root)
    selected_specs = selected_family_specs(args.family)
    hover_raw_authority = None

    if args.family == "hoverBench":
        if args.max_per_split is not None:
            raise RuntimeError("the authenticated hoverBench export must not be capped")
        if not args.hover_source_root:
            raise RuntimeError(
                "the authenticated hoverBench export requires --hover-source-root"
            )
        hover_raw_authority = verify_hover_raw_source(
            Path(args.hover_source_root).resolve()
        )
    elif args.hover_identity_disjoint:
        raise RuntimeError("--hover-identity-disjoint requires --family hoverBench")

    sys.path.insert(0, str(gepa_root))
    install_dataset_compatibility_shims()

    out.mkdir(parents=True, exist_ok=True)
    exported_specs: List[Dict[str, Any]] = []

    for family, spec in selected_specs.items():
        benchmark = instantiate_benchmark(spec["module"], family)
        family_dir = out / family
        family_dir.mkdir(parents=True, exist_ok=True)

        split_counts = {}
        split_checksums = {}
        split_records = benchmark_split_records(benchmark)
        split_lineage = None

        if args.family == "hoverBench" and args.hover_identity_disjoint:
            split_records, split_lineage = identity_disjoint_hover_records(
                benchmark, split_records
            )

        for split_name in ["train", "dev", "test"]:
            records = split_records[split_name]
            if args.max_per_split is not None:
                records = records[: args.max_per_split]

            path = family_dir / f"{split_name}.jsonl"
            write_jsonl(path, records)
            split_counts[split_name] = len(records)
            split_checksums[split_name] = "sha256:" + sha256(path)

        if args.family == "hoverBench":
            expected = (
                HOVER_IDENTITY_DISJOINT_SPLITS
                if args.hover_identity_disjoint
                else HOVER_FROZEN_SPLITS
            )
            verify_frozen_hover_export(
                family_dir, split_counts, split_checksums, expected
            )

        exported_specs.append(
            {
                **{key: value for key, value in spec.items() if key != "module"},
                "family": family,
                "dataset_source": f"{source['repository']}@{source['commit']}",
                "dataset_scope": dataset_scope,
                "max_per_split": args.max_per_split,
                "split_counts": split_counts,
                "split_checksums": split_checksums,
                "dataset_authorities": dataset_authorities(
                    gepa_root, family, source, hover_raw_authority
                ),
                **family_extra_metadata(gepa_root, family),
                **(
                    {
                        "split_policy": "released_split_with_content_identity_overlap_removed",
                        "split_lineage": split_lineage,
                    }
                    if split_lineage is not None
                    else {}
                ),
                "metric_fidelity": (
                    "upstream_metric_named_for_adapter; Imp campaign runner ports "
                    "deterministic adapters, Papillon judge scoring, IFBench registry "
                    "checks, and guarded LiveBenchMath symbolic bridge branches"
                ),
            }
        )

    write_json(
        out / "families.json",
        {
            "schema_version": 2,
            "runner": "gepa_export_dataset_root.py",
            "upstream_source": source,
            "dataset_scope": dataset_scope,
            "max_per_split": args.max_per_split,
            "selected_family": args.family,
            "dataset_aliases": DATASET_ALIASES,
            "families": exported_specs,
        },
    )

    print(out)
    return 0


def selected_family_specs(family: str | None) -> Dict[str, Dict[str, Any]]:
    if family is None:
        return FAMILY_SPECS
    return {family: FAMILY_SPECS[family]}


def verify_hover_raw_source(source_root: Path) -> Dict[str, Any]:
    repository = canonical_repository(git_value(source_root, "remote", "get-url", "origin"))
    commit = git_value(source_root, "rev-parse", "HEAD")

    if repository != HOVER_RAW_SOURCE["repository"]:
        raise RuntimeError(
            f"HoVer raw source repository mismatch: expected {HOVER_RAW_SOURCE['repository']}, "
            f"got {repository or '<missing>'}"
        )
    if commit != HOVER_RAW_SOURCE["commit"]:
        raise RuntimeError(
            f"HoVer raw source commit mismatch: expected {HOVER_RAW_SOURCE['commit']}, "
            f"got {commit or '<missing>'}"
        )

    files = []
    for relative_path, expected in HOVER_RAW_SOURCE["files"].items():
        path = source_root / relative_path
        actual_bytes = path.stat().st_size if path.is_file() else None
        actual_sha256 = sha256(path) if path.is_file() else None
        if actual_bytes != expected["bytes"] or actual_sha256 != expected["sha256"]:
            raise RuntimeError(
                f"HoVer raw source file mismatch: {relative_path}; expected "
                f"{expected['bytes']} bytes/{expected['sha256']}, got "
                f"{actual_bytes}/{actual_sha256 or '<missing>'}"
            )
        files.append(
            {
                "path": relative_path,
                "bytes": actual_bytes,
                "sha256": actual_sha256,
                "raw_url": (
                    f"https://raw.githubusercontent.com/hover-nlp/hover/"
                    f"{HOVER_RAW_SOURCE['commit']}/{relative_path}"
                ),
            }
        )

    return {
        "kind": "git_raw_dataset_files",
        "repository": repository,
        "revision": commit,
        "files": files,
    }


def verify_frozen_hover_export(
    family_dir: Path,
    split_counts: Dict[str, int],
    split_checksums: Dict[str, str],
    expected_splits: Dict[str, Dict[str, Any]] = HOVER_FROZEN_SPLITS,
) -> None:
    for split, expected in expected_splits.items():
        actual_count = split_counts.get(split)
        actual_sha256 = split_checksums.get(split)
        expected_sha256 = "sha256:" + expected["sha256"]
        if actual_count != expected["count"] or actual_sha256 != expected_sha256:
            raise RuntimeError(
                f"frozen hoverBench {split} mismatch at {family_dir / (split + '.jsonl')}: "
                f"expected {expected['count']} rows/{expected_sha256}, got "
                f"{actual_count}/{actual_sha256}"
            )


def benchmark_split_records(benchmark) -> Dict[str, List[Dict[str, Any]]]:
    return {
        "train": [example_to_record(example) for example in list(benchmark.train_set)],
        "dev": [example_to_record(example) for example in list(benchmark.val_set)],
        "test": [example_to_record(example) for example in list(benchmark.test_set)],
    }


def identity_disjoint_hover_records(
    benchmark, released: Dict[str, List[Dict[str, Any]]]
) -> tuple[Dict[str, List[Dict[str, Any]]], Dict[str, Any]]:
    """Remove source duplicates without using model outputs or task scores."""
    for split, expected in HOVER_FROZEN_SPLITS.items():
        actual = jsonl_sha256(released[split])
        if len(released[split]) != expected["count"] or actual != expected["sha256"]:
            raise RuntimeError(
                f"released HoVer {split} lineage differs before identity reconciliation"
            )

    dataset = list(benchmark.dataset)
    total = len(dataset)
    pools = {
        "test": dataset[: int(0.4 * total)],
        "dev": dataset[int(0.4 * total) : int(0.8 * total)],
        "train": dataset[int(0.8 * total) :],
    }
    pool_records = {
        split: [example_to_record(example) for example in examples]
        for split, examples in pools.items()
    }
    forbidden = {
        record_identity(record)
        for records in released.values()
        for record in records
    }
    seen: set[str] = set()
    reconciled: Dict[str, List[Dict[str, Any]]] = {}
    skipped: Dict[str, List[Dict[str, Any]]] = {}
    replacements: Dict[str, List[Dict[str, Any]]] = {}

    for split in ["train", "dev", "test"]:
        kept = []
        skipped[split] = []

        for position, record in enumerate(released[split]):
            identity = record_identity(record)
            if identity in seen:
                skipped[split].append(
                    {"released_position": position, "content_sha256": identity}
                )
            else:
                kept.append(record)
                seen.add(identity)

        needed = HOVER_FROZEN_SPLITS[split]["count"] - len(kept)
        candidates = sorted(
            (
                record_identity(record),
                source_position,
                record,
            )
            for source_position, record in enumerate(pool_records[split])
            if record_identity(record) not in forbidden
            and record_identity(record) not in seen
        )
        chosen = candidates[:needed]

        if len(chosen) != needed:
            raise RuntimeError(f"HoVer {split} has no finite identity-disjoint replacement")

        replacements[split] = [
            {"source_pool_position": position, "content_sha256": identity}
            for identity, position, _record in chosen
        ]

        for identity, _position, record in chosen:
            kept.append(record)
            seen.add(identity)

        reconciled[split] = kept

    return reconciled, {
        "released_split_sha256": {
            split: expected["sha256"] for split, expected in HOVER_FROZEN_SPLITS.items()
        },
        "identity": "sha256(canonical compact sorted-key JSON record)",
        "precedence": ["train", "dev", "test"],
        "replacement_policy": (
            "lowest unused content identity from the same released source pool; "
            "append after retained released rows"
        ),
        "skipped": skipped,
        "replacements": replacements,
    }


def record_identity(record: Dict[str, Any]) -> str:
    source = json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def jsonl_sha256(records: List[Dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for record in records:
        digest.update(json.dumps(record, sort_keys=True).encode("utf-8") + b"\n")
    return digest.hexdigest()


def install_dataset_compatibility_shims() -> None:
    try:
        import datasets
    except ImportError:
        return

    original_load_dataset = datasets.load_dataset

    def load_dataset_compat(path: str, *args: Any, **kwargs: Any):
        canonical_path = DATASET_ALIASES.get(path, path)
        revision = DATASET_REVISIONS.get(canonical_path)
        if revision is not None:
            kwargs.setdefault("revision", revision)
        return original_load_dataset(canonical_path, *args, **kwargs)

    datasets.load_dataset = load_dataset_compat

    try:
        import spacy.util
        import spacy.cli
    except ImportError:
        return

    original_spacy_download = spacy.cli.download

    def download_spacy_model_compat(model: str, *args: Any, **kwargs: Any):
        if spacy.util.is_package(model):
            return None

        return original_spacy_download(model, *args, **kwargs)

    spacy.cli.download = download_spacy_model_compat


def instantiate_benchmark(module_name: str, family: str):
    module = importlib.import_module(module_name)
    metas = getattr(module, "benchmark")
    meta = metas[0]
    dataset_mode = getattr(meta, "dataset_mode", None)
    benchmark = meta.benchmark(dataset_mode=dataset_mode) if dataset_mode else meta.benchmark()
    expected_name = meta.name or benchmark.__class__.__name__
    if expected_name != family:
        raise RuntimeError(f"expected family {family}, got benchmark {expected_name}")
    return benchmark


def family_extra_metadata(gepa_root: Path, family: str) -> Dict[str, Any]:
    # HotpotMultiHop imports and executes hover.hover_program.search. Although
    # its module configures a ColBERT client, that client is not on the executed
    # program path in the artifact.
    if family not in {"HotpotQABench", "hoverBench"}:
        return {}

    hover_dir = gepa_root / "gepa_artifact" / "benchmarks" / "hover"
    corpus = hover_dir / "wiki.abstracts.2017.jsonl"
    index = hover_dir / "bm25s_retriever"

    retrieval: Dict[str, Any] = {
        "kind": "bm25s_wiki_abstracts_2017",
        "source_url": "https://huggingface.co/dspy/cache/resolve/main/wiki.abstracts.2017.tar.gz",
        "corpus_path": corpus.relative_to(gepa_root).as_posix(),
        "index_path": index.relative_to(gepa_root).as_posix(),
        "status": "present" if corpus.exists() and index.exists() else "missing",
    }

    if corpus.exists():
        retrieval["corpus_checksum"] = "sha256:" + sha256(corpus)

    if index.exists():
        if index.is_file():
            retrieval["index_checksum"] = "sha256:" + sha256(index)
        else:
            retrieval["index_checksum"] = "sha256:" + sha256_tree(index)

    return {"retrieval": retrieval}


def dataset_authorities(
    gepa_root: Path,
    family: str,
    source: Dict[str, str],
    hover_raw_authority: Dict[str, Any] | None = None,
) -> List[Dict[str, Any]]:
    authorities = [
        {
            "kind": "huggingface_dataset",
            "repository": repository,
            "revision": DATASET_REVISIONS[repository],
        }
        for repository in FAMILY_DATASETS.get(family, [])
    ]

    if family == "IFBench":
        for relative_path in [
            "gepa_artifact/benchmarks/IFBench/data/IFBench_train.jsonl",
            "gepa_artifact/benchmarks/IFBench/data/IFBench_test.jsonl",
        ]:
            authorities.append(
                {
                    "kind": "embedded_upstream_file",
                    "repository": source["repository"],
                    "revision": source["commit"],
                    "path": relative_path,
                    "sha256": sha256(gepa_root / relative_path),
                }
            )

    if family == "hoverBench" and hover_raw_authority is not None:
        authorities.append(hover_raw_authority)

    return authorities


def example_to_record(example: Any) -> Dict[str, Any]:
    if hasattr(example, "toDict"):
        data = example.toDict()
    elif isinstance(example, dict):
        data = dict(example)
    else:
        data = dict(example)
    return json_safe(data)


def json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): json_safe(val) for key, val in value.items() if not str(key).startswith("_")}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def write_jsonl(path: Path, records: Iterable[Dict[str, Any]]) -> None:
    with path.open("w") as f:
        for record in records:
            f.write(json.dumps(record, sort_keys=True) + "\n")


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_tree(path: Path) -> str:
    h = hashlib.sha256()
    for file_path in sorted(p for p in path.rglob("*") if p.is_file()):
        rel = file_path.relative_to(path).as_posix()
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        with file_path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        h.update(b"\0")
    return h.hexdigest()


def source_identity(path: Path) -> Dict[str, str]:
    repository = git_value(path, "remote", "get-url", "origin")
    commit = git_value(path, "rev-parse", "HEAD")
    tree = git_value(path, "rev-parse", "HEAD^{tree}")

    if not repository or not is_hex_digest(commit, 40) or not is_hex_digest(tree, 40):
        raise RuntimeError(
            "GEPA artifact source must be a Git checkout with an origin, commit, and tree identity"
        )

    return {
        "repository": canonical_repository(repository),
        "commit": commit,
        "tree": tree,
    }


def canonical_repository(repository: str) -> str:
    value = repository.strip()
    if value.startswith("git@github.com:"):
        value = "https://github.com/" + value.removeprefix("git@github.com:")
    if value.endswith(".git"):
        value = value[:-4]
    return value


def is_hex_digest(value: str, length: int) -> bool:
    return len(value) == length and all(char in "0123456789abcdef" for char in value)


def git_value(path: Path, *args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), *args], stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        return ""


if __name__ == "__main__":
    raise SystemExit(main())
