# Dialyzer ignore file. Entries are `{file, warning_type}` pairs: they name a
# file and a warning class, never a line, so an edit above a known warning
# cannot turn its entry into an "unnecessary skip" and fail dialyzer.check on
# an unrelated change. The trade: a new warning of the same class in the same
# file is also skipped. Keep entries few; fix a warning at its cause when the
# fix is small and clearly right.
#
# `list_unused_filters: true` in mix.exs still reports entries that stop
# matching, so an entry is removed once its file no longer has that warning.
#
# Reason shorthands:
# - defensive clause/guard: an extra clause or guard for input shapes success
#   typing says today's callers never produce. Kept deliberately as a seam;
#   deleting it is a behavior decision, not a type fix. Warnings dialyzer pins
#   to line 1 come from such clauses inside macro-generated code.
# - MapSet opacity: OTP 28's stricter opacity analysis flags MapSets whose
#   inferred type is a literal struct (module-attribute sets, sets typed
#   through JSON dump/load). The MapSet API usage itself is correct.
# - :rand seed format: {:exsss, [i | j]} improper list is :rand's own exsss
#   export shape; the construction is intentional and correct.
[
  # --- bench/ research control plane

  # defensive clause
  {"bench/imp/benchmark_truth/failure_campaign.ex", :pattern_match_cov},
  # MapSet opacity on option-key and metric sets
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :call_without_opaque},
  # defensive clause: remaining_timeout/2 accepts nil and :infinity deadlines
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :pattern_match},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque},
  # defensive guard
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :guard_fail},
  # defensive clause (line 1)
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :pattern_match},
  # MapSet opacity on the stopword set
  {"bench/imp/benchmark_truth/hover_bm25.ex", :call_without_opaque},
  # defensive guard
  {"bench/imp/benchmark_truth/hover_bm25.ex", :guard_fail},
  # defensive clause
  {"bench/imp/benchmark_truth/multimodal_runner.ex", :pattern_match_cov},
  # defensive clauses for non-covered audit and request shapes
  {"bench/imp/benchmark_truth/openrouter_free_guard.ex", :pattern_match_cov},
  # defensive clause (line 1)
  {"bench/imp/benchmark_truth/optimize_anything/pricing_policy.ex", :pattern_match},
  # MapSet opacity: MapSet.equal? against a literal-typed expected set
  {"bench/imp/benchmark_truth/optimize_anything/scheduling_heuristic.ex", :call_without_opaque},
  # defensive clause for non-covered differential rows
  {"bench/imp/benchmark_truth/optimize_anything/upstream_differential.ex", :pattern_match_cov},
  # MapSet opacity on case-id sets typed through campaign JSON
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :call_without_opaque},
  # defensive clause for non-covered campaign rows
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :pattern_match_cov},
  # helper reached only from a branch success typing considers dead
  {"bench/imp/benchmark_truth/rlm_protocol.ex", :unused_fun},
  # defensive guard
  {"bench/imp/benchmark_truth/runner.ex", :guard_fail},

  # --- lib/

  # defensive fallback clause
  {"lib/imp/adapter/chat.ex", :pattern_match_cov},
  # defensive fallback clause
  {"lib/imp/adapter/xml.ex", :pattern_match_cov},
  # defensive clause (line 1)
  {"lib/imp/clients/mlx_lm_deployment.ex", :pattern_match},
  # defensive guard: ReqLLM.Response types provider_meta as map() with a %{}
  # default, but the struct does not enforce it (a caller can build one with
  # nil), and ReqLLM's own OpenTelemetry attributes guard it with is_map/1.
  {"lib/imp/clients/req_llm.ex", :guard_fail},
  # defensive error clauses on always-ok internal calls
  {"lib/imp/clients/training.ex", :pattern_match},
  # defensive fallbacks paired with those clauses
  {"lib/imp/clients/training.ex", :pattern_match_cov},
  # defensive error clause
  {"lib/imp/clients/trl_trainer.ex", :pattern_match_cov},
  # MapSet opacity: MapSet.equal? against literal-typed key sets
  {"lib/imp/optimizer/artifact.ex", :call_without_opaque},
  # defensive error clauses on always-ok internal calls
  {"lib/imp/optimizer/better_together.ex", :pattern_match},
  # defensive fallback paired with those clauses
  {"lib/imp/optimizer/better_together.ex", :pattern_match_cov},
  # URI.parse/1's success type makes the ordinary-port rejection branch look
  # unreachable; keep the public URL validator defensive at this trust boundary.
  {"lib/imp/optimizer/budget.ex", :pattern_match},
  # defensive clause for already-handled pending-validation states
  {"lib/imp/optimizer/gepa/engine.ex", :pattern_match_cov},
  # defensive clause (line 1)
  {"lib/imp/optimizer/gepa/evaluation.ex", :pattern_match},
  # MapSet opacity: MapSet.equal? against a literal-typed key set
  {"lib/imp/optimizer/gepa/evaluation_cache/disk.ex", :call_without_opaque},
  # :rand seed format
  {"lib/imp/optimizer/gepa/random.ex", :improper_list_constr},
  # defensive error clause on an always-ok proposal call
  {"lib/imp/optimizer/instruction_proposer.ex", :pattern_match},
  # defensive clause for non-list trainsets
  {"lib/imp/optimizer/knn_few_shot.ex", :pattern_match_cov},
  # MapSet opacity: the recursive sampler threads a MapSet accumulator whose
  # initial literal type dialyzer refuses to unify with the opaque internal
  {"lib/imp/optimizer/mipro_v2/python_random.ex", :call_with_opaque},
  {"lib/imp/optimizer/mipro_v2/python_random.ex", :call_without_opaque},
  # defensive fallback clause
  {"lib/imp/optimizer/playbook.ex", :pattern_match_cov},
  # MapSet opacity: MapSet.equal? against a literal-typed set
  {"lib/imp/optimizer/report.ex", :call_without_opaque},
  # :rand seed format
  {"lib/imp/optimizer/sampling.ex", :improper_list_constr},
  # defensive clause for non-covered bucket shapes
  {"lib/imp/optimizer/simba.ex", :pattern_match_cov},
  # defensive clause for non-covered trace entries
  {"lib/imp/optimizer/trajectory.ex", :pattern_match_cov},
  # defensive error clause on an always-ok retriever call
  {"lib/imp/retrieve.ex", :pattern_match},
  # defensive fallback paired with that clause
  {"lib/imp/retrieve.ex", :pattern_match_cov},
  # defensive fallback clause
  {"lib/imp/schema.ex", :pattern_match_cov},
  # MapSet opacity on run-id sets typed through MLflow JSON
  {"lib/imp/tracking/mlflow.ex", :call_without_opaque},
  # defensive clause (line 1)
  {"lib/mix/tasks/imp.benchmark.fast_slow.ex", :pattern_match},
  # MapSet opacity on the run-index set from parity JSON
  {"lib/mix/tasks/imp.benchmark.parity.aggregate.ex", :call_without_opaque},
  # defensive nil-fallback clause for env maps the task always populates
  {"lib/mix/tasks/imp.benchmark.parity.ex", :pattern_match}
]
