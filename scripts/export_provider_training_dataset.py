#!/usr/bin/env python3
"""Export a small pinned BANKING77 slice for the paid SFT campaign."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from datasets import load_dataset


DATASET = "PolyAI/banking77"
REVISION = "90d4e2ee5521c04fc1488f065b8b083658768c57"
PAPER = "https://arxiv.org/abs/2003.04807v2"
ROUTES = {
    "card_payment_fee_charged": "R17",
    "card_payment_not_recognised": "R42",
    "pending_card_payment": "R68",
    "reverted_card_payment?": "R93",
}


def digest(value: object) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def select_rows(dataset, split: str, per_label: int) -> list[dict[str, str]]:
    names = dataset[split].features["label"].names
    wanted = {names.index(label): (label, route) for label, route in ROUTES.items()}
    counts = {label: 0 for label in ROUTES}
    rows: list[dict[str, str]] = []

    for source_index, row in enumerate(dataset[split]):
        if row["label"] not in wanted:
            continue

        label, route = wanted[row["label"]]
        if counts[label] >= per_label:
            continue

        rows.append(
            {
                "id": f"banking77-{split}-{source_index}",
                "utterance": row["text"].strip(),
                "route": route,
                "source_label": label,
            }
        )
        counts[label] += 1

    missing = {label: per_label - count for label, count in counts.items() if count < per_label}
    if missing:
        raise RuntimeError(f"insufficient rows for labels: {missing}")

    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--train-per-label", type=int, default=20)
    parser.add_argument("--held-out-per-label", type=int, default=10)
    args = parser.parse_args()

    dataset = load_dataset(DATASET, revision=REVISION)
    train = select_rows(dataset, "train", args.train_per_label)
    held_out = select_rows(dataset, "test", args.held_out_per_label)

    train_text = {row["utterance"].casefold() for row in train}
    held_out_text = {row["utterance"].casefold() for row in held_out}
    overlap = sorted(train_text & held_out_text)
    if overlap:
        raise RuntimeError(f"train/held-out text overlap: {overlap}")

    payload = {
        "artifact_type": "imp_provider_training_dataset",
        "schema_version": 1,
        "task": "opaque-route adaptation over natural BANKING77 customer queries",
        "source": {
            "dataset": DATASET,
            "revision": REVISION,
            "paper": PAPER,
            "license": "cc-by-4.0",
        },
        "route_codes": sorted(ROUTES.values()),
        "selection": {
            "strategy": "first rows in canonical source order per selected label",
            "train_per_label": args.train_per_label,
            "held_out_per_label": args.held_out_per_label,
            "selected_source_labels": sorted(ROUTES),
            "train_held_out_overlap": overlap,
        },
        "train": train,
        "held_out": held_out,
        "digests": {"train": digest(train), "held_out": digest(held_out)},
    }
    payload["payload_sha256"] = digest(payload)

    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
