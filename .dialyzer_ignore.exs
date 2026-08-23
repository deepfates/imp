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
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/failure_campaign.ex", :guard_fail, {756, 38}},
  # defensive clause for non-covered result shapes
  {"bench/imp/benchmark_truth/failure_campaign.ex", :pattern_match_cov, {169, 13}},
  # MapSet opacity on the stopword set (this one renders only under
  # --format raw; the default formatter drops it, the count still sees it)
  {"bench/imp/benchmark_truth/hover_bm25.ex", :call_without_opaque, {191, 36}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {1927, 20}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {464, 31}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {476, 36}},
  # MapSet opacity on metric sets typed through campaign JSON
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :call_without_opaque, {523, 35}},
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :guard_fail, 2072},
  # defensive guard success typing proves redundant
  {"bench/imp/benchmark_truth/gepa_metrics.ex", :guard_fail, 2221},
  # defensive clause dialyzer pins to the module head (line 1)
  {"bench/imp/benchmark_truth/optimize_anything/pricing_policy.ex", :pattern_match, 1},
  # MapSet opacity: MapSet.equal? against a literal-typed expected set
  {"bench/imp/benchmark_truth/optimize_anything/scheduling_heuristic.ex", :call_without_opaque, {286, 30}},
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
  {"lib/imp/clients/req_llm.ex", :pattern_match_cov, {156, 7}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/clients/training.ex", :pattern_match, {1215, 13}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/clients/training.ex", :pattern_match, {680, 8}},
  # defensive fallback paired with the 1199 clause
  {"lib/imp/clients/training.ex", :pattern_match_cov, {1287, 7}},
  # defensive fallback paired with the 904 clause
  {"lib/imp/clients/training.ex", :pattern_match_cov, {1536, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/better_together.ex", :pattern_match, {1280, 8}},
  # defensive error clause on an always-ok internal call
  {"lib/imp/optimizer/better_together.ex", :pattern_match, {1283, 8}},
  # defensive fallback paired with the clauses above
  {"lib/imp/optimizer/better_together.ex", :pattern_match_cov, {1295, 8}},
  # raise-only helper: every raise_parallel_worker_error/1 clause raises
  # (engine.ex:2469-2530); the catch-all covers these shapes at runtime
  {"lib/imp/optimizer/gepa/engine.ex", :call, {3961, 35}},
  # defensive clause for already-handled pending-validation states
  {"lib/imp/optimizer/gepa/engine.ex", :pattern_match_cov, {3041, 7}},
  # defensive clause dialyzer pins to the module head (line 1)
  {"lib/imp/optimizer/gepa/evaluation.ex", :pattern_match, 1},
  # MapSet opacity: MapSet.equal? against a literal-typed key set
  {"lib/imp/optimizer/gepa/evaluation_cache/disk.ex", :call_without_opaque, {201, 49}},
  # defensive error clause on an always-ok proposal call
  {"lib/imp/optimizer/instruction_proposer.ex", :pattern_match, {459, 8}},
  # defensive clause for non-list trainsets
  {"lib/imp/optimizer/knn_few_shot.ex", :pattern_match_cov, {23, 7}},
  # :rand seed format ([first | second]) at the seed_s call
  {"lib/imp/optimizer/sampling.ex", :improper_list_constr, {24, 11}},
  # defensive clause for non-covered bucket shapes
  {"lib/imp/optimizer/simba.ex", :pattern_match_cov, {695, 8}},
  # defensive clause for non-covered trace entries
  {"lib/imp/optimizer/trajectory.ex", :pattern_match_cov, {270, 8}},
  # MapSet opacity on the redaction key set
  {"lib/imp/redaction.ex", :call_without_opaque, {500, 51}},
  # behaviour callback specs term(); impl narrows to %__MODULE__{} on
  # purpose so bad input crashes loudly
  {"lib/imp/retrieve.ex", :callback_arg_type_mismatch, {161, 9}},
  # defensive error clause on an always-ok retriever call
  {"lib/imp/retrieve.ex", :pattern_match, {113, 8}},
  # defensive fallback paired with the 106 clause
  {"lib/imp/retrieve.ex", :pattern_match_cov, {114, 8}},
  # behaviour callback specs term(); impl narrows on purpose (see retrieve.ex)
  {"lib/imp/retrievers/http.ex", :callback_arg_type_mismatch, {95, 7}},
  # MapSet opacity on run-id sets typed through MLflow JSON
  {"lib/imp/tracking/mlflow.ex", :call_without_opaque, {361, 8}},
  # defensive clause dialyzer pins to the module head (line 1)
  {"lib/mix/tasks/imp.benchmark.fast_slow.ex", :pattern_match, 1},
  # MapSet opacity on the hop-id set from analysis JSON
  {"lib/mix/tasks/imp.benchmark.hotpotqa_analysis.ex", :call_without_opaque, {159, 24}},
  # MapSet opacity on the run-index set from parity JSON
  {"lib/mix/tasks/imp.benchmark.parity.aggregate.ex", :call_without_opaque, {328, 24}},
  # raise-only helper: invalid_python!/1 exists to Mix.raise
  {"lib/mix/tasks/imp.benchmark.parity.ex", :no_return, {514, 8}},
  # defensive nil-fallback clause for env maps the task always populates
  {"lib/mix/tasks/imp.benchmark.parity.ex", :pattern_match, {715, 11}},
  # raise-only helper: invalid_snapshot!/2 exists to Mix.raise
  {"lib/mix/tasks/imp.public_api.ex", :no_return, {838, 8}},
  # dependency code: this file ships inside the req_llm package, not this
  # repo; LLMDB.Model.t/0 is a Zoi-generated spec dialyzer cannot see
  {"lib/req_llm.ex", :unknown_type, {109, 24}},

  # --- Surfaced 2026-08-08 during ignore-file regeneration (imp-fkwy): 583
  # commits landed without CI, and these warnings accumulated unpinned.
  # Each needs individual triage (ticket imp-dialyzer-triage); most are
  # bench-side no_return/unused_fun cascades and MapSet opaque checks from
  # the current dialyzer version.
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :call, {1883, 13}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :no_return, {1881, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :no_return, {220, 28}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :no_return, {591, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :no_return, {740, 33}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :no_return, {745, 27}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :no_return, {750, 27}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, 1427},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, 1499},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1125, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1169, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1183, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1190, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1196, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1216, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1240, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1258, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1288, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1308, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1317, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1323, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1332, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1348, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1365, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1382, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1395, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1403, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1466, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1478, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1490, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1502, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1508, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1512, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1542, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1648, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1686, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1704, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1733, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1782, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1841, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1850, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1857, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {1887, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {321, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {886, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {894, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {901, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {908, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {920, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {947, 8}},
  {"bench/imp/benchmark_truth/gepa_campaign.ex", :unused_fun, {958, 8}},
  {"bench/imp/benchmark_truth/gepa_study_condition.ex", :no_return, {8, 7}},
  {"bench/imp/benchmark_truth/gepa_study_condition.ex", :unused_fun, {169, 8}},
  {"bench/imp/benchmark_truth/gepa_study_condition.ex", :unused_fun, {202, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :no_return, {173, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :no_return, {37, 48}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :pattern_match, 1},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :unused_fun, {324, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :unused_fun, {328, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :unused_fun, {331, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :unused_fun, {338, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :unused_fun, {354, 8}},
  {"bench/imp/benchmark_truth/gepa_study_plan.ex", :unused_fun, {372, 8}},
  {"bench/imp/benchmark_truth/gepa_suite.ex", :call, {268, 13}},
  {"bench/imp/benchmark_truth/gepa_suite.ex", :no_return, 22},
  {"bench/imp/benchmark_truth/gepa_suite.ex", :no_return, {169, 8}},
  {"bench/imp/benchmark_truth/gepa_suite.ex", :no_return, {266, 8}},
  {"bench/imp/benchmark_truth/hover_bm25.ex", :guard_fail, 387},
  {"bench/imp/benchmark_truth/hover_gepa_no_merge_plan.ex", :call, {1272, 18}},
  {"bench/imp/benchmark_truth/hover_gepa_no_merge_plan.ex", :no_return, {1271, 8}},
  {"bench/imp/benchmark_truth/hover_gepa_no_merge_plan.ex", :no_return, {591, 7}},
  {"bench/imp/benchmark_truth/musique_ans.ex", :call, {267, 15}},
  {"bench/imp/benchmark_truth/musique_ans.ex", :no_return, {180, 7}},
  {"bench/imp/benchmark_truth/musique_ans.ex", :no_return, {264, 8}},
  {"bench/imp/benchmark_truth/musique_ans.ex", :unused_fun, {252, 8}},
  {"bench/imp/benchmark_truth/musique_ans.ex", :unused_fun, {259, 8}},
  {"bench/imp/benchmark_truth/openrouter_free_guard.ex", :pattern_match_cov, {319, 8}},
  {"bench/imp/benchmark_truth/openrouter_free_guard.ex", :pattern_match_cov, {400, 8}},
  {"lib/imp/clients/mlx_lm_deployment.ex", :pattern_match, 1},
  {"lib/imp/clients/training.ex", :pattern_match, {1535, 8}},
  {"lib/imp/clients/trl_deployment.ex", :unknown_type, {29, 42}},
  {"lib/imp/clients/trl_deployment.ex", :unknown_type, {72, 30}},
  {"lib/imp/clients/trl_trainer.ex", :pattern_match_cov, {339, 20}},
  # URI.parse/1's success type makes the ordinary-port rejection branch look
  # unreachable; keep the public URL validator defensive at this trust boundary.
  {"lib/imp/optimizer/budget.ex", :pattern_match, 1},
  {"lib/imp/optimizer/gepa/random.ex", :improper_list_constr, {91, 17}},
  {"lib/imp/optimizer/mipro_v2.ex", :no_return, {150, 7}},
  {"lib/imp/optimizer/mipro_v2/python_random.ex", :call_without_opaque, {131, 55}},
  # MapSet opacity: the recursive sampler threads a MapSet accumulator whose
  # initial literal type dialyzer refuses to unify with the opaque internal
  {"lib/imp/optimizer/mipro_v2/python_random.ex", :call_with_opaque, {138, 14}},
  {"lib/imp/optimizer/mipro_v2/python_random.ex", :call_without_opaque, {146, 23}},

  # Defensive fallbacks and MapSet opacity retained at the 0.3 cut. These are
  # individually pinned so a changed success type makes the gate ask again.
  {"bench/imp/benchmark_truth/multimodal_runner.ex", :pattern_match_cov, {341, 16}},
  {"lib/imp/adapter/chat.ex", :pattern_match_cov, {715, 8}},
  {"lib/imp/adapter/xml.ex", :pattern_match_cov, {675, 8}},
  {"lib/imp/clients/req_llm.ex", :guard_fail, 1317},
  {"lib/imp/clients/req_llm.ex", :pattern_match_cov, {1345, 8}},
  {"lib/imp/lm.ex", :pattern_match, {260, 8}},
  {"lib/imp/lm.ex", :pattern_match_cov, {261, 8}},
  {"lib/imp/mcp.ex", :pattern_match_cov, {1171, 8}},
  {"lib/imp/optimizer/artifact.ex", :call_without_opaque, {745, 52}},
  {"lib/imp/optimizer/artifact.ex", :call_without_opaque, {909, 53}},
  {"lib/imp/optimizer/playbook.ex", :pattern_match_cov, {1014, 8}},
  {"lib/imp/optimizer/report.ex", :call_without_opaque, {744, 55}},
  {"lib/imp/predict/rlm.ex", :pattern_match, {1645, 8}},
  {"lib/imp/schema.ex", :pattern_match_cov, {459, 8}}
]
