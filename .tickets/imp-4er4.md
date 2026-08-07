---
id: imp-4er4
status: open
deps: []
links: []
created: 2026-08-07T17:08:17Z
type: bug
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [docs]
---
# Fix two broken ADVANCED.md snippets

HTTP retriever response_mapper example is arity-2 where schema requires {:fun, 1} (http.ex:45); Imp.Retrievers.Databricks.new/3 documented but only new/2 exists (http.ex:449); module error messages also reference new/3.

## Acceptance Criteria

Both snippets construct successfully when pasted; error-message references reconciled.

