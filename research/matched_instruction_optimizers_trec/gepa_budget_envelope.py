#!/usr/bin/env python3
"""Pinned GEPA v0.1.4 iteration-boundary budget envelope (no network)."""

from __future__ import annotations

import json


def envelope(validation_size: int, minibatch_size: int, semantic_max_metric_calls: int) -> dict[str, int]:
    if validation_size < 0 or minibatch_size <= 0 or semantic_max_metric_calls < 0:
        raise ValueError("GEPA envelope sizes and limits must be non-negative, with a positive minibatch")

    increments = (minibatch_size, 2 * minibatch_size, 2 * minibatch_size + validation_size)
    reachable = {validation_size}
    while True:
        expanded = set(reachable)
        for count in reachable:
            if count < semantic_max_metric_calls:
                expanded.update(
                    count + increment
                    for increment in increments
                    if count + increment < semantic_max_metric_calls
                )
        if expanded == reachable:
            break
        reachable = expanded

    legal_starts = [count for count in reachable if count < semantic_max_metric_calls]
    max_metric_calls = validation_size if not legal_starts else max(legal_starts) + max(increments)
    max_iterations = (
        0
        if validation_size >= semantic_max_metric_calls
        else (semantic_max_metric_calls - validation_size + minibatch_size - 1) // minibatch_size
    )
    return {
        "max_metric_calls": max_metric_calls,
        "max_reflection_calls": 2 * max_iterations,
        "max_iterations": max_iterations,
    }


if __name__ == "__main__":
    print(json.dumps(envelope(40, 10, 280), sort_keys=True))
