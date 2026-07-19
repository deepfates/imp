#!/usr/bin/env python3
"""Generate the pinned answer-metric parity fixture from REAL DSPy 3.2.1.

Runs dspy.evaluate.metrics (normalize_text / em_score / f1_score /
hotpot_f1_score / _passage_match) from the pinned parity venv on a table of
adversarial inputs and writes the expected values to
test/fixtures/metrics_parity/cases.json. The Elixir side
(test/metrics_dspy_parity_test.exs) asserts Imp.Metrics computes byte-identical
normalizations and equal scores.

Regenerate (from the repo root, after scripts/setup_dspy_parity_env.sh):

    tmp/dspy-parity-venv/bin/python scripts/dspy_metrics_differential.py

Ticket: dee-c2ur / dee-j11u (epic dee-zobd).
"""

from __future__ import annotations

import importlib.metadata
import json
import sys
from pathlib import Path

from dspy.evaluate.metrics import (
    _passage_match,
    em_score,
    f1_score,
    hotpot_f1_score,
    normalize_text,
)

OUT_PATH = Path(__file__).resolve().parent.parent / "test" / "fixtures" / "metrics_parity" / "cases.json"

# Adversarial normalization inputs: punctuated, unicode NFC/NFD, accented,
# hyphenated, quoted (ASCII + smart), articles, numerics, currency, symbols,
# CJK, whitespace variants, empty/blank.
NORMALIZE_CASES = [
    ("us_abbreviation", "U.S."),
    ("apostrophe_contraction", "don't"),
    ("docstring_example", "The,  Eiffel  Tower!"),
    ("accented_nfc", "café"),
    ("accented_nfd", "café"),
    ("accented_words_nfc", "naïve résumé"),
    ("hyphenated_compound", "state-of-the-art"),
    ("ascii_double_quotes", '"quoted" answer'),
    ("leading_apostrophe", "'Til Death"),
    ("smart_quotes", "“smart quotes”"),
    ("articles_only", "A An The a an the"),
    ("article_like_prefixes", "another antenna theory"),
    ("decimal_number", "3.14"),
    ("comma_grouped_number", "1,000,000"),
    ("currency_parenthetical", "$100 (approx.)"),
    ("percentage", "50%"),
    ("email_address", "e-mail@example.com"),
    ("mixed_whitespace", "  leading\tand\ntrailing  "),
    ("accented_city", "México City"),
    ("accented_hyphenated_name", "Beyoncé Knowles-Carter"),
    ("article_plus_abbreviation", "the U.S. Congress"),
    ("article_then_combining_mark", "thé"),
    ("non_decomposable_l_stroke", "Łódź, Poland"),
    ("cjk", "北京大学"),
    ("numero_sign_em_dash", "№5 — result"),
    ("bracket_zoo", "AC/DC; [Back] {in} <Black>"),
    ("empty_string", ""),
    ("blank_spaces", "   "),
    ("article_sentence", "The answer is 42."),
    ("ring_and_diaeresis", "Ångström"),
    ("colon_semicolon", "semi;colon:test"),
    ("nbsp_separator", "a b"),
]

# (pred, gold) pairs for em_score / f1_score / hotpot_f1_score.
PAIR_CASES = [
    ("us_vs_dotted", "US", "U.S."),
    ("dont_vs_apostrophe", "dont", "don't"),
    ("ticket_probe_congress", "the US congress", "U.S. congress"),
    ("nfc_vs_ascii", "café", "cafe"),
    ("nfc_vs_nfd", "café", "café"),
    ("docstring_f1_third", "Eiffel Tower is in Paris", "Paris"),
    ("hotpot_yes_vs_no", "yes", "no"),
    ("hotpot_yes_vs_yes", "yes", "yes"),
    ("hotpot_noanswer_vs_spaced", "noanswer", "no answer"),
    ("hotpot_spaced_vs_noanswer", "no answer", "noanswer"),
    ("comma_number", "1,000", "1000"),
    ("comma_locality", "Paris, France", "Paris France"),
    ("empty_prediction", "", "answer"),
    ("articles_normalize_empty", "a", "the"),
    ("leading_article_team", "San Francisco 49ers", "the San Francisco 49ers"),
    ("middle_initial", "Barack H. Obama", "Barack Obama"),
    ("span_vs_sentence", "42", "The answer is 42."),
    ("hotpot_yes_vs_punctuated_yes", "yes", "Yes."),
    ("hotpot_no_vs_yes", "no", "yes"),
]

# (answers, passages) pairs for _passage_match (DPR has_answer semantics).
PASSAGE_CASES = [
    ("substring_inside_word", ["art"], ["Many participated in the event"]),
    ("plain_hit_first_passage", ["Eiffel Tower"], ["The Eiffel Tower is in Paris.", "Nothing else"]),
    ("dotted_abbreviation", ["U.S."], ["the US economy grew"]),
    ("hit_in_second_passage", ["Paris"], ["nothing here", "He lives in Paris now"]),
    ("concat_seam", ["bc"], ["a b", "c d"]),
    ("accented_answer", ["café"], ["They met at the café."]),
    ("answer_spanning_passages", ["New York City"], ["He moved to New York", "City taxes are high"]),
    ("empty_answer_quirk", [""], ["any passage"]),
    ("no_passages", ["yes"], []),
    ("multi_answer_list", ["Louvre", "Paris"], ["The Louvre is in Paris"]),
    ("whole_word_hit", ["participated"], ["Many participated in the event"]),
    ("punctuated_phrase", ["don't stop"], ["They said don't stop believing"]),
]


def main() -> int:
    out_path = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT_PATH
    fixture = {
        "generator": "scripts/dspy_metrics_differential.py",
        "command": "tmp/dspy-parity-venv/bin/python scripts/dspy_metrics_differential.py",
        "dspy_version": importlib.metadata.version("dspy"),
        "python_version": sys.version.split()[0],
        "normalize_cases": [
            {"id": case_id, "input": text, "expected": normalize_text(text)}
            for case_id, text in NORMALIZE_CASES
        ],
        "pair_cases": [
            {
                "id": case_id,
                "prediction": pred,
                "gold": gold,
                "em": bool(em_score(pred, gold)),
                "f1": float(f1_score(pred, gold)),
                "hotpot_f1": float(hotpot_f1_score(pred, gold)),
            }
            for case_id, pred, gold in PAIR_CASES
        ],
        "passage_cases": [
            {
                "id": case_id,
                "answers": answers,
                "passages": passages,
                "match": bool(_passage_match(passages, answers)),
            }
            for case_id, answers, passages in PASSAGE_CASES
        ],
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(fixture, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(f"wrote {out_path}")
    print(f"dspy=={fixture['dspy_version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
