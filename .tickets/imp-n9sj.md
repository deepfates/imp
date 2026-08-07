---
id: imp-n9sj
status: open
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

