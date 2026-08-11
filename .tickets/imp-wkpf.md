---
id: imp-wkpf
status: open
deps: []
links: []
created: 2026-08-11T04:53:24Z
type: bug
priority: 1
assignee: deepfates
parent: imp-yme4
---
# GEPA Pareto remove_dominated diverges from upstream on tied scores

lib/imp/optimizer/gepa/pareto.ex:41 breaks ties with inspect/1 (lexicographic on the PRINTED id): Enum.sort_by(&{Map.get(aggregate_scores, &1, 1), inspect(&1)}). Upstream gepa v0.1.4 gepa_utils.py:49 does sorted(programs, key=lambda x: scores[x]) — Python's sort is STABLE, so ties preserve list(freq.keys()) i.e. candidate DISCOVERY order. Because remove_until_stable greedily removes in list order, the walk order decides which of two equally-covering candidates survives.

VERIFIED REPRODUCTION (both run against the pinned sources):
  mapping = %{0 => #{2,10}, 1 => #{2,10}, 2 => #{5}}, scores = %{2 => 0.5, 10 => 0.5, 5 => 0.9}
  upstream survivors: [5, 10]
  imp survivors:      [2, 5]
Scripts: scratchpad/pareto_diff2.{py,exs}.

REACHABILITY IS HIGH, not theoretical: (a) ties in aggregate valset score are pervasive because the IFBench metric is near-binary per row on small valsets; (b) inspect/1 orders ids lexicographically so '10' < '2' — any run reaching 10+ candidates can trip it, and the rehearsal's GEPA arms produced 17-39 candidates. Divergent Pareto survival changes the parent pool for the next mutation, so the whole search trajectory can separate.

WHY IT WAS NEVER CAUGHT: the matched end-to-end campaign has a measured per-cell noise of sd 0.063 (SE 0.089 on a paired difference), so a trajectory divergence of this kind is invisible to it at 1 seed; the existing GEPA component tape (test/gepa_component_parity_test.exs) covers reflective datasets, reflection prompts, module rotation and stopping — but not Pareto tie ordering.

FIX: reproduce upstream's stable-sort-over-discovery-order semantics (carry an explicit insertion index rather than inspect/1), and add a differential test over tie-heavy score matrices, including ids spanning 1 and 2 digits. Check pareto.ex:90 (Enum.sort_by(fn {key,_} -> inspect(key) end)) for the same defect class.

