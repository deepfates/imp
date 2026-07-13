#!/usr/bin/env python3
"""Evaluate IFBench parity fixtures against the upstream GEPA artifact source."""

import argparse
import importlib.util
import json
import os
import sys
import types
import warnings


def install_spacy_stub_if_needed():
    try:
        import spacy  # type: ignore
        import spacy.cli  # type: ignore

        spacy.cli.download = lambda *_args, **_kwargs: None
        spacy.load = lambda *_args, **_kwargs: object()
    except ModuleNotFoundError:
        spacy = types.ModuleType("spacy")
        cli = types.ModuleType("spacy.cli")
        cli.download = lambda *_args, **_kwargs: None
        spacy.cli = cli
        spacy.load = lambda *_args, **_kwargs: object()
        sys.modules["spacy"] = spacy
        sys.modules["spacy.cli"] = cli


def install_optional_import_stubs():
    try:
        import nltk  # type: ignore

        nltk.download = lambda *_args, **_kwargs: None
    except ModuleNotFoundError:
        nltk = types.ModuleType("nltk")
        nltk.download = lambda *_args, **_kwargs: None
        sys.modules["nltk"] = nltk

    for module_name in ("emoji", "syllapy"):
        if importlib.util.find_spec(module_name) is None:
            sys.modules[module_name] = types.ModuleType(module_name)


def load_fixtures(path):
    fixtures = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.strip()
            if line:
                fixture = json.loads(line)
                fixture["line"] = line_number
                fixtures.append(fixture)
    return fixtures


def import_registry(artifact_root):
    warnings.filterwarnings(
        "ignore",
        message="pkg_resources is deprecated as an API.*",
        category=UserWarning,
    )
    install_spacy_stub_if_needed()
    install_optional_import_stubs()
    dspy = sys.modules.setdefault("dspy", types.ModuleType("dspy"))
    dspy.Module = getattr(dspy, "Module", object)
    dspy.Example = getattr(dspy, "Example", object)

    utils_dir = os.path.join(
        artifact_root,
        "gepa_artifact",
        "benchmarks",
        "IFBench",
        "utils_ifbench",
    )
    package_name = "ifbench_upstream_utils"
    package = types.ModuleType(package_name)
    package.__path__ = [utils_dir]
    sys.modules[package_name] = package

    registry_path = os.path.join(utils_dir, "instructions_registry.py")
    spec = importlib.util.spec_from_file_location(
        f"{package_name}.instructions_registry",
        registry_path,
        submodule_search_locations=[utils_dir],
    )
    module = importlib.util.module_from_spec(spec)
    module.__package__ = package_name
    sys.modules[f"{package_name}.instructions_registry"] = module
    spec.loader.exec_module(module)

    return module.INSTRUCTION_DICT


def evaluate_fixture(registry, fixture):
    instruction_id = fixture["instruction_id"]
    instruction_cls = registry[instruction_id]
    instruction = instruction_cls(instruction_id)
    args = {key: value for key, value in fixture.get("kwargs", {}).items() if value is not None}

    instruction.build_description(**args)
    return bool(instruction.check_following(fixture["response"]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-root", required=True)
    parser.add_argument("--fixtures", required=True)
    args = parser.parse_args()

    artifact_root = os.path.abspath(args.artifact_root)
    registry = import_registry(artifact_root)
    fixtures = load_fixtures(args.fixtures)

    fixture_ids = {fixture["instruction_id"] for fixture in fixtures}
    registry_ids = set(registry.keys())

    results = []
    for fixture in fixtures:
        try:
            following = evaluate_fixture(registry, fixture)
            results.append(
                {
                    "instruction_id": fixture["instruction_id"],
                    "line": fixture["line"],
                    "upstream_following": following,
                }
            )
        except Exception as exc:
            results.append(
                {
                    "instruction_id": fixture["instruction_id"],
                    "line": fixture["line"],
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )

    print(
        json.dumps(
            {
                "registry_count": len(registry_ids),
                "fixture_count": len(fixtures),
                "missing_fixture_ids": sorted(registry_ids - fixture_ids),
                "extra_fixture_ids": sorted(fixture_ids - registry_ids),
                "results": results,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
