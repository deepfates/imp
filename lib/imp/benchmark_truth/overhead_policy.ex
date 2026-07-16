defmodule Imp.BenchmarkTruth.OverheadPolicy do
  @moduledoc false

  @dspy_version "3.2.1"
  @script_sha256 "18bcfb4f3d7165c0f21e0ba8a5bb162a02c0b92e6a78ff50d4606b40e665ced9"

  @budgets (
             budget = fn max_imp_median_us, max_ratio, rationale ->
               %{
                 "max_imp_median_us" => max_imp_median_us,
                 "max_median_ratio_to_reference" => max_ratio,
                 "rationale" => rationale,
                 "policy" => "regression_guard_not_speed_claim"
               }
             end

             %{
               "signature_parse" =>
                 budget.(
                   50.0,
                   1.0,
                   "Cold signature construction is bounded to interactive-scale work."
                 ),
               "adapter_format" =>
                 budget.(
                   50.0,
                   1.0,
                   "One fixed single-turn message-format operation must remain sub-50us."
                 ),
               "adapter_parse" =>
                 budget.(
                   50.0,
                   5.0,
                   "One fixed Chat response parse allows runtime-specific parser dispatch."
                 ),
               "schema_validate" =>
                 budget.(
                   25.0,
                   5.0,
                   "The same two-field string/number object is validated in both runtimes."
                 ),
               "evaluation_loop" =>
                 budget.(
                   5_000.0,
                   1.0,
                   "Eight fixed provider-free predictions must remain below 5ms."
                 ),
               "metric_normalization" =>
                 budget.(
                   250.0,
                   10.0,
                   "Eight matched normalized exact-match calls allow runtime dispatch while remaining below 250us."
                 ),
               "optimizer_trial_scheduling" =>
                 budget.(
                   2_000.0,
                   2.0,
                   "Matched one-bootstrap/one-labeled compilation remains below 2ms."
                 ),
               "trace_redaction_serialization" =>
                 budget.(
                   250.0,
                   20.0,
                   "One nested credential-shaped trace is redacted and JSON encoded."
                 ),
               "cache_hit" =>
                 budget.(
                   10.0,
                   10.0,
                   "Both stores are preseeded; the measured operation is one lookup."
                 ),
               "cache_miss" =>
                 budget.(
                   100.0,
                   250.0,
                   "Both stores allocate and insert one value; the reference median is near the timer floor, so the relative guard permits expected ETS owner-policy overhead while the 100us absolute guard bounds user-visible cost."
                 ),
               "concurrent_orchestration" =>
                 budget.(
                   3_000.0,
                   2.0,
                   "Both runtimes schedule and collect 32 squares with eight workers."
                 )
             }
           )

  @contracts %{
    "signature_parse" => "construct question -> answer signature",
    "adapter_format" => "format one fixed question with no demonstrations",
    "adapter_parse" => "parse one fixed Chat answer field",
    "schema_validate" => "validate fixed label:string and score:number object",
    "evaluation_loop" => "evaluate eight fixed examples through one static response program",
    "metric_normalization" => "score eight fixed examples with exact match",
    "optimizer_trial_scheduling" =>
      "compile two examples with max_bootstrapped_demos=1 and max_labeled_demos=1",
    "trace_redaction_serialization" => "redact and JSON encode the same nested trace shape",
    "cache_hit" => "preseed outside timing and perform one timed lookup",
    "cache_miss" => "allocate one unique key, insert one fixed response, and return it",
    "concurrent_orchestration" => "schedule and collect 32 integer squares with eight workers"
  }

  def budgets, do: @budgets
  def expected_case_ids, do: Map.keys(@budgets) |> Enum.sort()
  def dspy_version, do: @dspy_version
  def script_sha256, do: @script_sha256

  def evaluate!(id, imp, reference) do
    budget =
      @budgets |> Map.fetch!(id) |> Map.put("operation_contract", Map.fetch!(@contracts, id))

    imp_median = Map.fetch!(imp, "median_us")
    reference_median = max(Map.fetch!(reference, "median_us"), 0.001)
    ratio = Float.round(imp_median / reference_median, 4)

    checks = %{
      "absolute_median" => imp_median <= budget["max_imp_median_us"],
      "reference_relative_median" => ratio <= budget["max_median_ratio_to_reference"]
    }

    %{
      "id" => id,
      "passing" => Enum.all?(Map.values(checks)),
      "checks" => checks,
      "budget" => budget,
      "measurements" => %{
        "median_ratio_imp_over_dspy" => ratio,
        "ratio_is_speed_claim" => false
      },
      "imp" => imp,
      "dspy" => reference
    }
  end

  def complete?(cases) when is_list(cases) do
    length(cases) == map_size(@budgets) and
      MapSet.new(Enum.map(cases, & &1["id"])) == MapSet.new(Map.keys(@budgets)) and
      Enum.all?(cases, fn row ->
        row["passing"] == true and is_map(row["budget"]) and
          is_binary(get_in(row, ["budget", "rationale"])) and
          is_binary(get_in(row, ["budget", "operation_contract"])) and
          get_in(row, ["measurements", "ratio_is_speed_claim"]) == false
      end)
  end

  def artifact_valid?(artifact) when is_map(artifact) do
    artifact["schema_version"] == 2 and
      artifact["runner"] == "imp-dspy-overhead-regression-guard" and
      get_in(artifact, ["policy", "id"]) == "named_per_operation_v1" and
      get_in(artifact, ["policy", "ratios_are_measurements_not_speed_claims"]) == true and
      get_in(artifact, ["policy", "budgets"]) == @budgets and
      complete?(artifact["cases"] || []) and
      artifact["summary"]["all_passing"] == true and
      artifact["summary"]["total"] == map_size(@budgets) and
      artifact["summary"]["passing"] == map_size(@budgets) and
      valid_environment?(get_in(artifact, ["imp", "environment"])) and
      get_in(artifact, ["imp", "environment"]) == get_in(artifact, ["run_context", "environment"]) and
      valid_reference?(artifact["dspy"]) and
      get_in(artifact, ["run_context", "inputs", "policy"]) == @budgets and
      get_in(artifact, ["run_context", "inputs", "protocol_id"]) ==
        "provider_free_overhead_regression_guard_v2"
  rescue
    _error -> false
  end

  def artifact_valid?(_artifact), do: false

  defp valid_reference?(reference) when is_map(reference) do
    reference["runner"] == "python-dspy-overhead" and
      reference["dspy_version"] == @dspy_version and
      valid_reference_environment?(reference["environment"]) and
      get_in(reference, ["environment", "script_sha256"]) == @script_sha256
  end

  defp valid_reference?(_reference), do: false

  defp valid_reference_environment?(environment) when is_map(environment) do
    Enum.all?(
      ~w(system release machine python_implementation python_executable script_sha256),
      fn key ->
        is_binary(environment[key]) and environment[key] != ""
      end
    )
  end

  defp valid_reference_environment?(_environment), do: false

  defp valid_environment?(environment) when is_map(environment),
    do: map_size(environment) > 0

  defp valid_environment?(_environment), do: false
end
