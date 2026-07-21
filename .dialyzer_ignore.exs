# Dialyzer ignore file (de-xmi1). One `{file, warning, line}` entry per
# finding, one reason per entry — no whole-file or whole-class blankets.
# `list_unused_filters: true` in mix.exs reports entries that stop matching,
# so stale ignores surface instead of rotting silently.
#
# Reason shorthands:
# - defensive clause/guard: an extra clause or guard for input shapes success
#   typing says today's callers never produce. Kept deliberately as a seam;
#   deleting it is a behavior decision, not a type fix.
# - MapSet opacity: OTP 28's stricter opacity analysis flags MapSets whose
#   inferred type is a literal struct (module-attribute sets, sets typed
#   through JSON dump/load). The MapSet API usage itself is correct.
# - raise-only helper: the function exists to raise; no_return is by design.
# - :rand seed format: {:exsss, [i | j]} improper list is :rand's own
#   exsss export shape; the construction is intentional and correct.
[
  # defensive clause for non-covered content shapes
  {"lib/imp/adapter/chat.ex", :pattern_match_cov, {623, 8}},
  # defensive clause for non-covered budget shapes
  {"bench/imp/benchmark_truth/campaign_budget.ex", :pattern_match_cov, {359, 8}},
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/failure_campaign.ex", :guard_fail, {746, 38}},
  # defensive clause for non-covered result shapes
  {"bench/imp/benchmark_truth/failure_campaign.ex", :pattern_match_cov, {169, 13}},
  # MapSet opacity on a campaign id set
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :call_without_opaque, {1414, 50}},
  # MapSet opacity on the stopword set (this one renders only under
  # --format raw; the default formatter drops it, the count still sees it)
  {"bench/imp/benchmark_truth/hover_bm25.ex", :call_without_opaque, {191, 36}},
  # defensive clause: remaining_timeout/2 nil-deadline clause; after #80's
  # deadline inversion fix callers always pass a deadline (or :infinity)
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :pattern_match, {1824, 8}},
  # defensive nil-deadline clause kept as a seam; Imp.Deadline.resolve/1's
  # spec (new in the shallow design pass) proves callers pass resolved
  # deadlines only
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :pattern_match, {1824, 8}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {1785, 20}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {336, 31}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {348, 36}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {395, 35}},
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :guard_fail, 1926},
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :guard_fail, 2034},
  # defensive clause for non-covered task shapes
  {"bench/imp/benchmark_truth/multimodal_runner.ex", :pattern_match_cov, {343, 16}},
  # defensive clause dialyzer pins to the module head (line 1)
  {"bench/imp/benchmark_truth/optimize_anything/pricing_policy.ex", :pattern_match, 1},
  # MapSet opacity: MapSet.equal? against a literal-typed expected set
  {"bench/imp/benchmark_truth/optimize_anything/scheduling_heuristic.ex", :call_without_opaque, {232, 30}},
  # defensive clause for non-covered differential rows
  {"bench/imp/benchmark_truth/optimize_anything/upstream_differential.ex", :pattern_match_cov, {228, 10}},
  # MapSet opacity on case-id sets typed through campaign JSON (col 21)
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :call_without_opaque, {813, 21}},
  # MapSet opacity on case-id sets typed through campaign JSON (col 53)
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :call_without_opaque, {813, 53}},
  # MapSet opacity on case-id sets typed through campaign JSON
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :call_without_opaque, {816, 52}},
  # MapSet opacity on case-id sets typed through campaign JSON
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :call_without_opaque, {820, 53}},
  # defensive clause for non-covered campaign rows
  {"bench/imp/benchmark_truth/rlm_campaign.ex", :pattern_match_cov, {421, 8}},
  # helper only referenced from paths dialyzer marks no-return
  {"bench/imp/benchmark_truth/rlm_protocol.ex", :unused_fun, {133, 8}},
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/runner.ex", :guard_fail, {651, 55}},
  # defensive clause: ReqLLM.model/1 contracts to ok/error tuples only; the
  # catch-all turns any unexpected registry result into a loud error (#75)
  {"lib/imp/clients/req_llm.ex", :pattern_match_cov, {120, 7}},
  # defensive `|| %{}` on provider_meta success typing proves already a map
  {"lib/imp/clients/req_llm.ex", :guard_fail, 904},
  # defensive fallback: sanitize_usage/1 clause for usage that is neither
  # nil nor a map; success typing says those are the only shapes today
  {"lib/imp/clients/req_llm.ex", :pattern_match_cov, {932, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/clients/training.ex", :pattern_match, {1199, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/clients/training.ex", :pattern_match, {904, 13}},
  # defensive fallback paired with the 1199 clause
  {"lib/imp/clients/training.ex", :pattern_match_cov, {1200, 8}},
  # defensive fallback paired with the 904 clause
  {"lib/imp/clients/training.ex", :pattern_match_cov, {976, 7}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/lm.ex", :pattern_match, {187, 8}},
  # defensive fallback paired with the 187 clause
  {"lib/imp/lm.ex", :pattern_match_cov, {188, 8}},
  # defensive fallback: fetch_optional/3 non-atom-key clause; callers pass
  # atom keys only today
  {"lib/imp/mcp.ex", :pattern_match_cov, {1051, 8}},
  # MapSet opacity: MapSet.equal? against a literal-typed expected set
  {"lib/imp/optimizer/artifact.ex", :call_without_opaque, {501, 53}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/better_together.ex", :pattern_match, {1245, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/better_together.ex", :pattern_match, {1248, 8}},
  # defensive fallback paired with the clauses above
  {"lib/imp/optimizer/better_together.ex", :pattern_match_cov, {1260, 8}},
  # defensive guard success typing proves redundant
  {"lib/imp/optimizer/copro.ex", :guard_fail, {519, 29}},
  # defensive fallback paired with the 519 guard
  {"lib/imp/optimizer/copro.ex", :pattern_match_cov, {530, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/ensemble.ex", :pattern_match, {59, 13}},
  # defensive fallback paired with the 59 clause
  {"lib/imp/optimizer/ensemble.ex", :pattern_match_cov, {68, 7}},
  # raise-only helper: every raise_parallel_worker_error/1 clause raises
  # (engine.ex:2469-2530); the catch-all covers these shapes at runtime
  {"lib/imp/optimizer/gepa/engine.ex", :call, {3795, 35}},
  # :rand seed format ([first | second]) at the seed_s call
  {"lib/imp/optimizer/gepa/engine.ex", :improper_list_constr, {5191, 18}},
  # defensive clause for already-handled pending-validation states
  {"lib/imp/optimizer/gepa/engine.ex", :pattern_match_cov, {2994, 7}},
  # defensive clause dialyzer pins to the module head (line 1)
  {"lib/imp/optimizer/gepa/evaluation.ex", :pattern_match, 1},
  # MapSet opacity: MapSet.equal? against a literal-typed key set
  {"lib/imp/optimizer/gepa/evaluation_cache/disk.ex", :call_without_opaque, {190, 49}},
  # defensive error clause on an always-ok proposal call
  {"lib/imp/optimizer/instruction_proposer.ex", :pattern_match, {278, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/knn_few_shot.ex", :pattern_match, {55, 13}},
  # defensive clause for non-list trainsets
  {"lib/imp/optimizer/knn_few_shot.ex", :pattern_match_cov, {23, 7}},
  # defensive fallback paired with the 55 clause
  {"lib/imp/optimizer/knn_few_shot.ex", :pattern_match_cov, {61, 7}},
  # defensive clause for non-covered stage results
  {"lib/imp/optimizer/playbook.ex", :pattern_match_cov, {886, 8}},
  # MapSet opacity: MapSet.equal? against a literal-typed tag key set
  {"lib/imp/optimizer/report.ex", :call_without_opaque, {434, 55}},
  # :rand seed format ([first | second]) at the seed_s call
  {"lib/imp/optimizer/sampling.ex", :improper_list_constr, {24, 11}},
  # defensive clause for non-covered bucket shapes
  {"lib/imp/optimizer/simba.ex", :pattern_match_cov, {617, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/trajectory.ex", :pattern_match, {1226, 13}},
  # defensive fallback paired with the 1226 clause
  {"lib/imp/optimizer/trajectory.ex", :pattern_match_cov, {1228, 7}},
  # defensive clause for non-covered trace entries
  {"lib/imp/optimizer/trajectory.ex", :pattern_match_cov, {262, 8}},
  # defensive clause for non-covered task results
  {"lib/imp/predict/parallel.ex", :pattern_match_cov, {98, 7}},
  # defensive error clause on an always-ok retriever call
  {"lib/imp/predict/rag.ex", :pattern_match, {129, 13}},
  # defensive fallback paired with the 129 clause
  {"lib/imp/predict/rag.ex", :pattern_match_cov, {135, 7}},
  # defensive clause for non-covered REPL outcomes
  {"lib/imp/predict/rlm.ex", :pattern_match, {1554, 8}},
  # MapSet opacity on the redaction key set
  {"lib/imp/redaction.ex", :call_without_opaque, {483, 51}},
  # behaviour callback specs term(); impl narrows to %__MODULE__{} on
  # purpose so bad input crashes loudly
  {"lib/imp/retrieve.ex", :callback_arg_type_mismatch, {154, 9}},
  # defensive error clause on an always-ok retriever call
  {"lib/imp/retrieve.ex", :pattern_match, {106, 8}},
  # defensive fallback paired with the 106 clause
  {"lib/imp/retrieve.ex", :pattern_match_cov, {107, 8}},
  # behaviour callback specs term(); impl narrows on purpose (see retrieve.ex)
  {"lib/imp/retrievers/http.ex", :callback_arg_type_mismatch, {95, 7}},
  # defensive clause for non-covered schema nodes
  {"lib/imp/schema.ex", :pattern_match_cov, {324, 8}},
  # MapSet opacity on run-id sets typed through MLflow JSON
  {"lib/imp/tracking/mlflow.ex", :call_without_opaque, {361, 8}},
  # MapSet opacity on gate-name sets typed through evidence JSON
  {"lib/mix/tasks/imp.benchmark.dashboard.ex", :call_without_opaque, {1239, 33}},
  # MapSet opacity on gate-name sets typed through evidence JSON
  {"lib/mix/tasks/imp.benchmark.dashboard.ex", :call_without_opaque, {1739, 59}},
  # MapSet opacity on gate-name sets typed through evidence JSON
  {"lib/mix/tasks/imp.benchmark.dashboard.ex", :call_without_opaque, {1743, 22}},
  # defensive clause: policy_candidate?/3 :age policy clause; callers pass
  # a narrower policy set today
  {"lib/mix/tasks/imp.benchmark.dashboard.ex", :pattern_match, {2575, 8}},
  # defensive clause: policy_candidate?/3 :immutable_admission clause, same
  # narrowed policy set as 2575
  {"lib/mix/tasks/imp.benchmark.dashboard.ex", :pattern_match, {2580, 8}},
  # defensive clause dialyzer pins to the module head (line 1)
  {"lib/mix/tasks/imp.benchmark.fast_slow.ex", :pattern_match, 1},
  # MapSet opacity on the hop-id set from analysis JSON
  {"lib/mix/tasks/imp.benchmark.hotpotqa_analysis.ex", :call_without_opaque, {159, 24}},
  # defensive nil-result clause on an evaluate call that always scores
  {"lib/mix/tasks/imp.benchmark.optimizer_lift.ex", :pattern_match, {605, 8}},
  # MapSet opacity on the run-index set from parity JSON
  {"lib/mix/tasks/imp.benchmark.parity.aggregate.ex", :call_without_opaque, {328, 24}},
  # raise-only helper: invalid_python!/1 exists to Mix.raise
  {"lib/mix/tasks/imp.benchmark.parity.ex", :no_return, {514, 8}},
  # defensive nil-fallback clause for env maps the task always populates
  {"lib/mix/tasks/imp.benchmark.parity.ex", :pattern_match, {715, 11}},
  # MapSet opacity: MapSet.equal? against a literal-typed live-row id set
  {"lib/mix/tasks/imp.benchmark.rag_tool_agent.ex", :call_without_opaque, {1018, 31}},
  # raise-only helper: invalid_snapshot!/2 exists to Mix.raise
  {"lib/mix/tasks/imp.public_api.ex", :no_return, {838, 8}},
  # dependency code: this file ships inside the req_llm package, not this
  # repo; LLMDB.Model.t/0 is a Zoi-generated spec dialyzer cannot see
  {"lib/req_llm.ex", :unknown_type, {109, 24}}
]
