#!/usr/bin/env python3
"""Executable cross-runtime guard symmetry gate for the sealed matched runners."""

from __future__ import annotations

import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
IMP = (HERE / "run_imp.exs").read_text()
UPSTREAM = (HERE / "run_upstream.py").read_text()
IMP_RUNTIME = "\n".join(
    [
        IMP,
        (ROOT / "lib/imp/optimizer/gepa.ex").read_text(),
        (ROOT / "lib/imp/optimizer/gepa/instruction_proposal.ex").read_text(),
        (ROOT / "lib/imp/optimizer/mipro_v2/upstream_proposer.ex").read_text(),
    ]
)


CHECKS = [
    ("launch", "identical", ["launch_status", "provider launch refused"], ["launch_status", "provider launch refused"], "same sealed-launch refusal"),
    ("predispatch_reservation", "identical", ["reserve_call!", "CallBudget.reserve!", "usd_reserved"], ["capture.reserve", "projected_usd", "usd_reserved"], "same call and maximum-cost reservation before dispatch"),
    ("model_identity", "identical", ["evidence.model", "expected[\"logical\"]"], ["model_ok", "expected[\"logical\"]"], "same logical-or-pinned-runtime model allowlist"),
    ("route_identity", "identical", ["evidence.route", "endpoint_provider", "gateway == \"openrouter\""], ["route_ok", "endpoint_provider", 'evidence["gateway"] == "openrouter"'], "same exact endpoint provider and gateway"),
    ("request_seed", "identical", ["configured_seed == expected_seed"], ["seed_ok", "request_seed"], "same task seed; optimizer seed is absent by the shared sealed contract"),
    ("token_limits", "identical", ["input_tokens <= expected", "output_tokens <= expected"], ['evidence["input_tokens"] <= expected', 'evidence["output_tokens"] <= expected'], "same provider-reported input/output ceilings; no byte proxy"),
    ("cost", "identical", ["reconcile_cost!", "costs_reconcile?", "usd_reserved"], ["reconcile_cost", 'Decimal("0.000001")', "usd_reserved"], "same reservation bound and inclusive one-microdollar reconciliation tolerance"),
    ("finish_content_envelope", "intentional_difference", ["finish_reason", "is_binary(evidence.content)", "ResponseEvidence.from_result!"], ["finish_reason", 'isinstance(evidence["content"], str)', "transport_evidence"], "language-native envelope projection, with the same required finish/content evidence"),
    ("task_parser", "intentional_difference", ["{:ok, prediction}", "Imp.Prediction.get(prediction, :route)", "{:error, reason}"], ["prediction = program(text=row[\"text\"])", "typed_parse_failure", "except Exception as exc"], "language-native typed adapters; malformed task output is retained and scores zero in both"),
    ("optimizer_parser", "intentional_difference", ["InstructionProposal.normalize", "Imp.Adapter.Chat.parse", "DSPy 3.2.1 MIPRO proposer output failed to parse"], ["validate_mipro_optimizer_envelope", "exact Chat marker"], "language-native decode: GEPA accepts the pinned fenced proposal; MIPRO requires the exact typed Chat envelope and aborts in both"),
    ("retry_fallback", "identical", ["retry: false", "max_retries: 0", "json_fallback: false", "allow_fallbacks: false", "evidence.attempts == 1", "evidence.retry == false"], ["num_retries=0", "use_json_adapter_fallback=False", '"allow_fallbacks": False', 'evidence["transport_attempts"] == 1'], "same one-transport, no-retry, no-parser-fallback contract"),
    ("call_ceiling", "identical", ["register_budget", "enforce_call_ceiling!", "enforce_combined_ceiling!"], ["register_budget", "validate_call_slice", "validate_combined_ceiling"], "same per-arm and combined ceilings"),
    ("heldout_barrier", "identical", ["seal_then_load_held_out!", "wait_for_peer_selection!", "held_out_rows!"], ["SELECTION_OUTPUT", "wait_for_peer_selection", "held_out_path"], "same peer-confirmed selection barrier before held-out load"),
    ("stop_persistence", "intentional_difference", ["status: \"stopped\"", "actual_cost:", "usd_reserved:", "lm_results:", "transport_events:"], ['"status": "stopped"', '"actual_cost"', '"usd_reserved"', '"calls"', '"call_budgets"'], "language-native serialization, with the same durable accounting and response/transport evidence"),
]


def require(source: str, anchors: list[str], runtime: str, name: str) -> None:
    missing = [anchor for anchor in anchors if anchor not in source]
    if missing:
        raise SystemExit(f"{runtime} {name} guard drift; missing {missing!r}")


def main() -> None:
    if "rendered request conservative token bound" in IMP or "rendered request conservative token bound" in UPSTREAM:
        raise SystemExit("byte-as-token guard reintroduced")

    rows = []
    for name, comparison, imp_anchors, upstream_anchors, rationale in CHECKS:
        require(IMP_RUNTIME, imp_anchors, "imp", name)
        require(UPSTREAM, upstream_anchors, "upstream", name)
        rows.append(
            {
                "guard": name,
                "comparison": comparison,
                "status": "equivalent",
                "rationale": rationale,
            }
        )

    print(json.dumps({"status": "pass", "count": len(rows), "guards": rows}, sort_keys=True))


if __name__ == "__main__":
    main()
