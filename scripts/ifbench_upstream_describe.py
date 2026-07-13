#!/usr/bin/env python3
"""Render IFBench instruction descriptions from the pinned upstream registry."""

import argparse
import json

from ifbench_upstream_eval import import_registry


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact-root", required=True)
    parser.add_argument("--payload", required=True)
    return parser.parse_args()


def describe(registry, item):
    instruction_id = item["instruction_id"]
    instruction = registry[instruction_id](instruction_id)
    kwargs = {key: value for key, value in item.get("args", {}).items() if value is not None}
    description = instruction.build_description(**kwargs)

    instruction_args = instruction.get_instruction_args()
    if instruction_args and "prompt" in instruction_args:
        description = instruction.build_description(prompt=item.get("prompt", ""))

    return description


def main():
    args = parse_args()
    registry = import_registry(args.artifact_root)

    with open(args.payload, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    descriptions = [describe(registry, item) for item in payload["instructions"]]
    print(json.dumps({"descriptions": descriptions}, ensure_ascii=False))


if __name__ == "__main__":
    main()
