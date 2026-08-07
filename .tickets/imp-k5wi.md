---
id: imp-k5wi
status: open
deps: []
links: []
created: 2026-08-07T17:12:13Z
type: task
priority: 2
assignee: deepfates
parent: imp-yme4
tags: [docs, coherence]
---
# Reconcile terminology drift across docs

Cold-reader findings: GLOSSARY says dev/train/test, API_GUIDE says training/selection/test (no bridge); two Artifact meanings (saved program vs Imp.Optimizer.Artifact parameter state) with one glossary entry; save!/2 vs save!/3 arity conflict; API_GUIDE leaks internal 'schema 2/3/4' result-file versioning; Metric glossary lists 4 return shapes with no when-to-use and no consumer for 'maps with feedback'; Imp.get/2 vs prediction.field never motivated; livebook 02 uses deprecated map LM shape while API_GUIDE uses Static.new (also covered by imp-86as); livebook 02 calls Imp.Adapter.JSON.parse/3 mid-tutorial without introducing it.

## Acceptance Criteria

One vocabulary used everywhere or explicit bridges; both artifact kinds in GLOSSARY; arities corrected; schema-N bookkeeping moved to internal docs; metric return-shape guidance written.

