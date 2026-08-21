---
id: imp-n9sj
status: closed
deps: []
links: []
created: 2026-08-07T17:13:23Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [datasets, docs]
---
# Datasets: stop implying parity with DSPy auto-download

Imp.Datasets.gsm8k/1 etc. parse local files only (datasets.ex:78-90); DSPy auto-downloads from HF. Docs imply built-in datasets. Also CONFORMANCE retrieval.data marked satisfied while its own rationale says ColBERTv2 intentionally omitted — satisfied-by-redefinition.

## Acceptance Criteria

Docs state local-file contract + fetch instructions (or add fetching); conformance rows reworded to declare rather than redefine.


## Notes

**2026-08-21T03:27:59Z**

API_GUIDE and Imp.Datasets moduledoc now state that named dataset loaders require existing local files and never auto-download, with an explicit source-checkout fetch command. The conformance rationale and invariant declare both that DSPy difference and the intentional embedded-ColBERT omission instead of redefining them away. Dataset, conformance, and docs contracts pass.
