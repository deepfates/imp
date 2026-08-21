---
id: imp-wkpf
status: closed
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


## Notes

**2026-08-11T05:52:40Z**

PARTIALLY FIXED + BOUNDARY FOUND (2026-08-11). Fix: pareto.ex remove_dominated no longer tie-breaks on inspect/1 (printed id, '10' < '2'); it now uses discovery order (rows in key order, ids ascending within a row), matching upstream's stable-sort-over-freq-insertion for the well-defined cases. Verified against pinned gepa v0.1.4 by executing both.

BUT the new differential test immediately falsified the fix on a third input, revealing the real boundary: upstream's tie order is NOT a semantic, it is CPython set-iteration order. {1,9,10} iterates as [1,10,9] because 9 and 10 collide (9 rem 8 == 1 rem 8) and open-addressing probing reorders them. Bit-exact agreement under collisions would require emulating CPython's probe sequence.

Disposition taken: fix the indefensible part (printed-string ordering), assert parity on non-colliding ties, and encode the collision case as an EXPLICIT bounded divergence that fails loudly if it ever starts agreeing (so the exemption cannot go stale). test/gepa_pareto_tie_order_differential_test.exs, 2 tests.

OWNER SCOPE CALL NEEDED: whether to emulate CPython set iteration for bit-exact Pareto parity. Precedent exists — the repo already emulates CPython MT19937 (lib/imp/optimizer/gepa/random.ex) for RNG parity — but this is a separate, larger commitment. Reachability is high: GEPA runs reach 17-39 candidates, so colliding id sets are common.

**2026-08-11T05:57:18Z**

SCOPE RESOLVED FROM SOURCE (2026-08-11), not from inference. gepa_utils.py select_program_candidate_from_pareto_front selects the next candidate via rng.choice(sampling_list) over Pareto survivors weighted by coverage frequency — the algorithm DELIBERATELY randomizes among survivors. And remove_dominated_programs' expressed intent is exactly its sort key, scores[x]: remove the lower-scoring redundant program first. Ordering among EQUAL scores is unspecified by that intent and merely falls out of CPython set/dict iteration.

DECISION: match the SEMANTICS (dominance rule + score-ordered removal + coverage-weighted sampling); do NOT emulate CPython hash-container iteration. Consequence, stated plainly so it is never over-claimed: bit-exact GEPA TRAJECTORY parity with gepa v0.1.4 is unattainable in imp without emulating CPython set/dict iteration order throughout — rng.choice indexes into a list whose order comes from that iteration, so even the bit-exact MT19937 (rng_algorithm: :python_v3) cannot deliver identical draws by itself. imp should therefore claim behavioural/semantic fidelity, never trajectory reproduction.

Fix stands (inspect/1 printed-id ordering was indefensible regardless). Tie exemption is encoded as a test that FAILS if it ever starts agreeing, so it cannot go stale.

**2026-08-21T03:22:16Z**

Verified the recorded semantic disposition against pinned gepa v0.1.4: `mix test test/gepa_pareto_tie_order_differential_test.exs --include dspy_parity` passes 2/2. Imp matches dominance and stable discovery semantics for defined cases; CPython hash-container collision order remains an explicit, tested non-semantic divergence, so no bit-exact trajectory claim is made.
