defmodule Imp.BenchmarkTruth.ReproductionArtifactValidator do
  @moduledoc false

  alias Imp.BenchmarkTruth.{AutoEvaluationContract, CampaignBudget}
  alias Imp.BenchmarkTruth.LocalMLXCampaign
  alias Imp.BenchmarkTruth.OptimizeAnything.Artifact, as: OptimizeAnythingArtifact
  alias Imp.BenchmarkTruth.OptimizeAnything.PricingPolicy
  alias Imp.BenchmarkTruth.RunContext

  @instruction_scope "matched one-seed AIME research preflight; not T3 effectiveness or parity"
  @instruction_identity_sha256 "sha256:18820f43f5c0a66a974f6efd333a8a92bc35cd609a24233f1bbf578e61b38140"
  @instruction_manifest_sha256 "sha256:f9837ae3d09eed6b5460470725e610bd87071801d134db7516705e61c643f0bf"
  @instruction_dspy_commit "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
  @multimodal_campaign "ds" <>
                         "ex-multimodal-quality-openai-gpt-4.1-mini-2025-04-14-responses-v3"
  @multimodal_sample_set_sha256 "4adcd95c8a4c89a855d6d37481839cb4fe26d55c31319bcc2af90c496cf9db4e"
  @multimodal_sample_ids ~w(
    image_ocr_batch_code
    image_ocr_bin
    image_shape_count_blue_circles
    image_shape_spatial_relation
    native_pdf_cross_page_join
    native_pdf_september_subtotal
  )

  # This dispatcher is intentionally pure: registry admission must never rerun a task.
  def validate!("auto_evaluation_contract", artifact) do
    AutoEvaluationContract.validate_artifact!(artifact)
    :ok
  end

  def validate!("local_mlx", artifact) do
    case LocalMLXCampaign.validate_artifact(artifact) do
      {:ok, _} -> :ok
      {:error, errors} -> raise ArgumentError, "invalid local MLX artifact: #{inspect(errors)}"
    end
  end

  def validate!("rag_failure_differential", artifact) do
    Mix.Tasks.Imp.Benchmark.RagToolFailureDifferential.validate_artifact!(artifact)
    :ok
  end

  def validate!("bfcl_shaped_scorer", artifact) do
    Mix.Tasks.Imp.Benchmark.BfclAdapted.validate_artifact!(artifact,
      require_clean: true,
      replay_reference: false
    )

    :ok
  end

  def validate!("copro_isolation", artifact) do
    Mix.Tasks.Imp.Benchmark.CoproIsolation.validate_artifact!(artifact)
    :ok
  end

  def validate!(protocol, artifact)
      when protocol in ["bootstrap_few_shot_differential", "random_search_differential"] do
    Mix.Tasks.Imp.Benchmark.ClassicalOptimizerDifferential.validate_artifact!(protocol, artifact)
    :ok
  end

  def validate!("avatar_actor_differential" = protocol, artifact) do
    Mix.Tasks.Imp.Benchmark.AvatarActorDifferential.validate_artifact!(protocol, artifact)
    :ok
  end

  def validate!("avatar_optimizer_differential" = protocol, artifact) do
    Mix.Tasks.Imp.Benchmark.AvatarOptimizerDifferential.validate_artifact!(protocol, artifact)
    :ok
  end

  def validate!("bootstrap_finetune_differential", artifact) do
    Mix.Tasks.Imp.Benchmark.WeightCompositionDifferential.validate_artifact!(
      "bootstrap_finetune",
      artifact
    )

    :ok
  end

  def validate!("better_together_differential", artifact) do
    Mix.Tasks.Imp.Benchmark.WeightCompositionDifferential.validate_artifact!(
      "better_together",
      artifact
    )

    :ok
  end

  def validate!("ensemble_differential" = protocol, artifact) do
    Mix.Tasks.Imp.Benchmark.EnsembleDifferential.validate_artifact!(protocol, artifact)
    :ok
  end

  def validate!("mmgrpo_differential" = protocol, artifact) do
    Mix.Tasks.Imp.Benchmark.MmgrpoDifferential.validate_artifact!(protocol, artifact)
    :ok
  end

  def validate!("optimize_anything", artifact) do
    validation = OptimizeAnythingArtifact.validate_rows(artifact["rows"], mode: :full)

    case artifact["runner"] do
      "imp-optimize-anything-replication" ->
        validate_current_optimize_anything!(artifact, validation)

      runner ->
        if runner == "ds" <> "ex-optimize-anything-replication" do
          validate_historical_optimize_anything!(artifact, validation)
        else
          raise ArgumentError, "invalid optimize-anything runner #{inspect(runner)}"
        end
    end
  end

  def validate!("multimodal_live", artifact) do
    rows = artifact["rows"]

    require!(
      artifact["artifact_schema"] == "ds" <> "ex.multimodal_quality.v2",
      "wrong multimodal schema"
    )

    require!(artifact["mode"] == "live", "wrong multimodal mode")
    require!(artifact["runner"] == multimodal_runner(), "wrong multimodal runner")
    require!(artifact["campaign_id"] == @multimodal_campaign, "wrong multimodal campaign")

    require!(
      Map.take(artifact["provider"] || %{}, ["name", "model", "api", "profile", "req_llm_model"]) ==
        %{
          "name" => "openai",
          "model" => "gpt-4.1-mini-2025-04-14",
          "api" => "responses",
          "profile" => "openai-gpt-4.1-mini-2025-04-14-responses",
          "req_llm_model" => "openai:gpt-4.1-mini-2025-04-14"
        },
      "wrong multimodal provider identity"
    )

    require!(
      get_in(artifact, ["manifest", "payload_sha256"]) == multimodal_manifest_sha256(),
      "wrong multimodal source"
    )

    require!(
      get_in(artifact, ["claim_gate", "eligible"]) == true,
      "multimodal claim gate is not eligible"
    )

    require!(
      get_in(artifact, ["claims", "multimodal_quality"]) == true,
      "multimodal claim is not admitted"
    )

    require!(is_list(rows) and length(rows) == 6, "wrong multimodal row contract")

    sample_ids =
      rows
      |> Enum.map(&get_in(&1, ["manifest_sample", "sample_id"]))
      |> Enum.sort()

    require!(sample_ids == @multimodal_sample_ids, "wrong multimodal sample set")

    Enum.each(rows, fn row ->
      require!(row["outcome"] == "passed" and row["score"] == 1.0, "invalid multimodal row")

      require!(
        row["dispatch"]["evidence"] == "post_serialization_req_request_step",
        "invalid multimodal dispatch evidence"
      )

      require!(
        is_binary(get_in(row, ["audit", "response", "provider_response_id"])),
        "missing multimodal provider response id"
      )

      require!(
        get_in(row, ["checkpoint_campaign_identity", "campaign_id"]) == @multimodal_campaign and
          get_in(row, ["checkpoint_campaign_identity", "manifest_sha256"]) ==
            multimodal_manifest_sha256() and
          get_in(row, ["checkpoint_campaign_identity", "sample_set_sha256"]) ==
            @multimodal_sample_set_sha256,
        "wrong multimodal checkpoint identity"
      )
    end)
  end

  def validate!("instruction_live", artifact) do
    RunContext.verify!(artifact)
    require!(artifact["schema_version"] == 1, "wrong instruction artifact schema")

    require!(
      artifact["runner"] == "imp-dspy-instruction-optimizer-experiment",
      "wrong instruction runner"
    )

    require!(
      artifact["evidence_level"] == "research_preflight",
      "wrong instruction evidence level"
    )

    require!(artifact["claim_scope"] == @instruction_scope, "wrong instruction claim contract")

    require!(
      get_in(artifact, ["identity", "identity_sha256"]) == @instruction_identity_sha256 and
        get_in(artifact, ["identity", "manifest_sha256"]) == @instruction_manifest_sha256 and
        get_in(artifact, ["identity", "dspy_authority", "commit"]) ==
          @instruction_dspy_commit,
      "wrong instruction experiment identity"
    )

    require!(
      artifact["scope"] == %{
        "evidence_tier" => "research_preflight",
        "not_t3" => true,
        "one_seed" => true,
        "research_preflight" => true
      },
      "wrong instruction scope"
    )

    require!(
      artifact["summary"] == %{
        "arms" => ["baseline", "mipro_v2", "simba"],
        "global_winner_selected" => false,
        "multi_seed" => false,
        "research_preflight" => true,
        "t3_complete" => false
      },
      "wrong instruction summary contract"
    )

    require!(
      get_in(artifact, ["identity", "dspy_authority", "contract_id"]) ==
        "t1_instruction_optimizer_differential_contract",
      "wrong instruction source contract"
    )

    require!(
      Map.keys(artifact["comparisons_to_baseline"] || %{}) |> Enum.sort() == ["dspy", "imp"],
      "wrong instruction comparison contract"
    )

    require!(
      Map.keys(artifact["runtimes"] || %{}) |> Enum.sort() == ["dspy", "imp"],
      "wrong instruction runtime contract"
    )
  end

  def validate!(protocol_id, _artifact),
    do: raise(ArgumentError, "no artifact contract for protocol #{protocol_id}")

  defp validate_current_optimize_anything!(artifact, validation) do
    RunContext.verify!(artifact)
    source = artifact["source"] || %{}
    seeds = source["seeds"]
    gepa_commit = current_gepa_commit!()
    rows = artifact["rows"] || []
    campaign_budget = rows |> List.first() |> then(&(&1 && &1["campaign_budget"]))

    require!(
      credential_safe_artifact?(artifact) and OptimizeAnythingArtifact.full_artifact?(artifact) and
        valid_current_optimize_anything_source?(source) and
        artifact["summary"] == optimize_anything_summary(validation) and
        get_in(artifact, ["run_context", "inputs"]) == source and
        get_in(artifact, ["run_context", "source_commits", "gepa"]) ==
          "gepa-ai/gepa@#{gepa_commit}" and
        Enum.all?(rows, fn row ->
          row["provider"] == source["provider"] and row["model"] == source["model"] and
            valid_optimize_anything_budget?(row["campaign_budget"], source["budget"]) and
            row["campaign_budget"] == campaign_budget and
            get_in(row, ["reproducibility", "budget"]) == row["campaign_budget"] and
            nonempty_string?(get_in(row, ["provenance", "budget_checkpoint"])) and
            get_in(row, ["provenance", "git_sha"]) == artifact["git_sha"] and
            get_in(row, ["reproducibility", "source_commits"]) == %{
              "imp" => artifact["git_sha"],
              "gepa" => gepa_commit
            } and run_seeds(row) == Enum.sort(seeds) and
            valid_optimize_anything_row_accounting?(row)
        end) and
        valid_optimize_anything_campaign_accounting?(rows, campaign_budget) and
        valid_optimize_anything_checkpoint?(artifact["budget_checkpoint"], campaign_budget),
      "invalid current optimize-anything artifact"
    )
  end

  defp validate_historical_optimize_anything!(artifact, validation) do
    require!(
      artifact["schema_version"] == 1 and
        artifact["runner"] == "ds" <> "ex-optimize-anything-replication" and
        artifact["source"] == %{
          "max_proposals" => 5,
          "mode" => "live_campaign",
          "model" => "gpt-5.4-2026-03-05",
          "provider" => "openai",
          "run_id" => "oa-20260713T092708Z-3042",
          "seeds" => [17, 23, 31]
        } and
        artifact["summary"] == %{
          "all_passing" => true,
          "duplicate_classes" => [],
          "effectiveness_authorized" => true,
          "evidence_level" => "full",
          "invalid_rows" => [],
          "missing_classes" => [],
          "unknown_classes" => []
        } and validation.authorizes_effectiveness,
      "invalid optimize-anything artifact"
    )
  end

  defp valid_current_optimize_anything_source?(source) do
    seeds = source["seeds"]

    Enum.sort(Map.keys(source)) == ~w(budget max_proposals mode model provider run_id seeds) and
      source["mode"] == "live_campaign" and nonempty_string?(source["run_id"]) and
      nonempty_string?(source["provider"]) and nonempty_string?(source["model"]) and
      is_integer(source["max_proposals"]) and source["max_proposals"] > 0 and
      valid_optimize_anything_budget_source?(
        source["budget"],
        source["provider"],
        source["model"]
      ) and
      is_list(seeds) and length(seeds) >= 3 and seeds == Enum.uniq(seeds) and
      Enum.all?(seeds, &is_integer/1)
  end

  defp valid_optimize_anything_budget_source?(
         %{
           "limits" => limits,
           "max_output_tokens_per_request" => per_request,
           "pricing" => pricing,
           "pricing_profile" => profile,
           "request_policy" => request_policy
         } = budget_source,
         provider,
         model
       ) do
    Enum.sort(Map.keys(budget_source)) ==
      ~w(limits max_output_tokens_per_request pricing pricing_profile request_policy) and
      Enum.sort(Map.keys(limits)) == ~w(input_tokens output_tokens requests usd) and
      Enum.sort(Map.keys(pricing)) == ~w(input_per_million output_per_million source_url) and
      is_integer(limits["requests"]) and limits["requests"] > 0 and
      is_integer(limits["input_tokens"]) and limits["input_tokens"] > 0 and
      is_integer(limits["output_tokens"]) and limits["output_tokens"] > 0 and
      finite_positive?(limits["usd"]) and is_integer(per_request) and per_request > 0 and
      per_request <= limits["output_tokens"] and
      request_policy == %{"cache" => false, "max_retries" => 0} and
      PricingPolicy.valid?(
        provider,
        model,
        profile,
        Map.take(pricing, ["input_per_million", "output_per_million"]),
        pricing["source_url"]
      )
  end

  defp valid_optimize_anything_budget_source?(_source, _provider, _model), do: false

  defp valid_optimize_anything_budget?(budget, source) when is_map(budget) do
    budget["reservation_ledger_version"] == 2 and budget["limits"] == source["limits"] and
      budget["pricing"] == source["pricing"] and is_integer(budget["requests"]) and
      budget["requests"] > 0 and budget["active_reservations"] == 0 and
      budget["reservations"] == [] and is_nil(budget["exhausted"]) and
      optimize_anything_usage_within_limits?(budget) and
      finite_positive?(get_in(budget, ["usage", "usd"])) and
      is_integer(get_in(budget, ["usage", "input_tokens"])) and
      get_in(budget, ["usage", "input_tokens"]) > 0 and
      is_integer(get_in(budget, ["usage", "output_tokens"])) and
      get_in(budget, ["usage", "output_tokens"]) > 0
  end

  defp valid_optimize_anything_budget?(_budget, _source), do: false

  defp optimize_anything_usage_within_limits?(budget) do
    limits = budget["limits"]
    usage = budget["usage"]

    budget["requests"] <= limits["requests"] and
      usage["input_tokens"] <= limits["input_tokens"] and
      usage["output_tokens"] <= limits["output_tokens"] and usage["usd"] <= limits["usd"]
  end

  defp finite_positive?(value) when is_number(value),
    do: value > 0 and match?({:ok, _}, Jason.encode(value))

  defp finite_positive?(_value), do: false

  defp valid_optimize_anything_row_accounting?(row) do
    runs = get_in(row, ["reproducibility", "runs"])

    with true <- is_list(runs) and runs != [],
         true <- Enum.all?(runs, &valid_optimize_anything_run?(&1, row)),
         input_tokens <- Enum.sum(Enum.map(runs, & &1["input_tokens"])),
         output_tokens <- Enum.sum(Enum.map(runs, & &1["output_tokens"])),
         cost_usd <- Enum.sum(Enum.map(runs, & &1["cost_usd"])),
         metric_calls <- Enum.sum(Enum.map(runs, & &1["metric_calls"])),
         wall_time_ms <- Enum.sum(Enum.map(runs, & &1["wall_time_ms"])),
         representative <- Enum.max_by(runs, & &1["optimized_score"]) do
      row["input_tokens"] == input_tokens and row["output_tokens"] == output_tokens and
        close_number?(row["cost_usd"], cost_usd) and row["metric_calls"] == metric_calls and
        row["wall_time_ms"] == wall_time_ms and row["seed"] == representative["seed"] and
        get_in(row, ["optimized", "score"]) == representative["optimized_score"] and
        representative["artifact_digest"] ==
          CampaignBudget.evidence_digest(get_in(row, ["optimized", "artifact"]))
    else
      _ -> false
    end
  end

  defp valid_optimize_anything_run?(run, row) when is_map(run) do
    baseline = get_in(row, ["baseline", "score"])

    is_integer(run["request_count"]) and run["request_count"] > 0 and
      is_integer(run["input_tokens"]) and run["input_tokens"] > 0 and
      is_integer(run["output_tokens"]) and run["output_tokens"] > 0 and
      finite_positive?(run["cost_usd"]) and is_integer(run["metric_calls"]) and
      run["metric_calls"] > 0 and is_integer(run["wall_time_ms"]) and
      run["wall_time_ms"] > 0 and close_number?(run["baseline_score"], baseline) and
      close_number?(run["lift"], run["optimized_score"] - baseline)
  end

  defp valid_optimize_anything_run?(_run, _row), do: false

  defp valid_optimize_anything_campaign_accounting?(rows, budget) when is_map(budget) do
    runs = Enum.flat_map(rows, &get_in(&1, ["reproducibility", "runs"]))

    budget["requests"] == Enum.sum(Enum.map(runs, & &1["request_count"])) and
      get_in(budget, ["usage", "input_tokens"]) ==
        Enum.sum(Enum.map(runs, & &1["input_tokens"])) and
      get_in(budget, ["usage", "output_tokens"]) ==
        Enum.sum(Enum.map(runs, & &1["output_tokens"])) and
      close_number?(
        get_in(budget, ["usage", "usd"]),
        Enum.sum(Enum.map(runs, & &1["cost_usd"]))
      ) and budget["reserved"] == %{"input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}
  end

  defp valid_optimize_anything_campaign_accounting?(_rows, _budget), do: false

  defp valid_optimize_anything_checkpoint?(
         %{"payload" => payload, "payload_sha256" => digest} = envelope,
         budget
       ) do
    Enum.sort(Map.keys(envelope)) == ~w(payload payload_sha256) and
      payload == %{
        "schema_version" => 1,
        "kind" => "optimize_anything_campaign_budget",
        "budget" => budget
      } and digest == CampaignBudget.evidence_digest(payload)
  end

  defp valid_optimize_anything_checkpoint?(_checkpoint, _budget), do: false

  defp close_number?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) <= 1.0e-12 * max(1.0, max(abs(left), abs(right)))

  defp close_number?(_left, _right), do: false

  defp credential_safe_artifact?(artifact) do
    Imp.Redaction.redact(artifact) == artifact and
      Imp.Redaction.drop_credentials(artifact) == artifact and credential_safe_value?(artifact)
  end

  defp credential_safe_value?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      not Imp.Redaction.credential_entry?(key, value) and credential_safe_value?(value)
    end)
  end

  defp credential_safe_value?(list) when is_list(list),
    do: Enum.all?(list, &credential_safe_value?/1)

  defp credential_safe_value?(value) when is_binary(value) do
    if match?(%URI{scheme: scheme} when scheme in ["http", "https"], URI.parse(value)) do
      PricingPolicy.validate_source_url!(value)
    end

    Imp.Redaction.redact(value) == value
  rescue
    ArgumentError -> false
  end

  defp credential_safe_value?(_value), do: true

  defp optimize_anything_summary(validation) do
    %{
      "all_passing" => true,
      "duplicate_classes" => validation.duplicate_classes,
      "effectiveness_authorized" => true,
      "evidence_level" => "full",
      "invalid_rows" => validation.invalid_rows,
      "missing_classes" => validation.missing_classes,
      "unknown_classes" => validation.unknown_classes
    }
  end

  defp current_gepa_commit! do
    "benchmarks/authorities.json"
    |> Imp.EvidenceAuthorities.load!()
    |> get_in(["pinned_sources", "gepa_standalone", "commit"])
    |> case do
      commit when is_binary(commit) and byte_size(commit) == 40 -> commit
      value -> raise ArgumentError, "invalid canonical GEPA authority #{inspect(value)}"
    end
  end

  defp run_seeds(row) do
    row
    |> get_in(["reproducibility", "runs"])
    |> Enum.map(& &1["seed"])
    |> Enum.sort()
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp multimodal_runner do
    %{
      "dispatch" => "DS" <> "Ex.Clients.ReqLLM.generate/3",
      "max_concurrency" => 2,
      "request_audit" => "Req request step after provider serialization and before transport",
      "resumable" => true
    }
  end

  defp multimodal_manifest_sha256,
    do: "04daa155d3f97edfff62e329dfdca1248855f22b2271f7e954228432f1ae39d8"

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
