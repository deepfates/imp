defmodule Imp.Experiment.Result do
  @moduledoc "Durable result of a fail-closed `Imp.Experiment.check/5` lifecycle."

  alias Imp.Evaluate.Result, as: EvaluationResult
  alias Imp.Optimizer.Artifact

  @enforce_keys [
    :status,
    :selected,
    :program,
    :artifact,
    :baseline_selection,
    :optimized_selection,
    :test,
    :provenance
  ]
  defstruct @enforce_keys ++ [baseline_test: nil, repetition_summary: nil]

  @type t :: %__MODULE__{
          status: :completed,
          selected: :baseline | :optimized,
          program: struct(),
          artifact: map(),
          baseline_selection: EvaluationResult.t(),
          optimized_selection: EvaluationResult.t(),
          baseline_test: EvaluationResult.t() | nil,
          test: EvaluationResult.t(),
          provenance: map(),
          repetition_summary: map() | nil
        }

  @doc "Returns the redacted durable result envelope; row contents are excluded by default."
  def to_map(%__MODULE__{} = result, opts \\ []) when is_list(opts) do
    include_rows? = result_options!(opts)
    Artifact.inspect(result.artifact)

    payload = %{
      "status" => "completed",
      "detail" => if(include_rows?, do: "rows", else: "summary"),
      "selected" => Atom.to_string(result.selected),
      "selection" => %{
        "baseline" => evaluation_map(result.baseline_selection, include_rows?),
        "optimized" => evaluation_map(result.optimized_selection, include_rows?)
      },
      "baseline_test" => evaluation_map(result.baseline_test, include_rows?),
      "test" => evaluation_map(result.test, include_rows?),
      "artifact" => result.artifact,
      "provenance" => Imp.Optimizer.Report.json_safe(result.provenance)
    }

    {schema_version, payload} =
      case result.repetition_summary do
        nil -> {2, payload}
        summary -> {3, Map.put(payload, "repetitions", repetition_map(summary, include_rows?))}
      end

    %{
      "result_type" => "imp_experiment_result",
      "schema_version" => schema_version,
      "payload_sha256" => Imp.Experiment.Data.digest(payload),
      "payload" => payload
    }
  end

  @doc "Atomically writes a completed result after validating its optimizer artifact."
  def write!(%__MODULE__{} = result, path, opts \\ []) when is_binary(path) and is_list(opts) do
    payload = Jason.encode!(to_map(result, opts), pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    io = File.open!(temporary, [:write, :binary, :exclusive])

    try do
      File.chmod!(temporary, 0o600)
      :ok = IO.binwrite(io, payload)
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    try do
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  @doc "Reads and structurally validates a durable result without restoring executable code."
  def read!(path) when is_binary(path) do
    result = path |> File.read!() |> Jason.decode!()

    expected = MapSet.new(["result_type", "schema_version", "payload_sha256", "payload"])
    payload = result["payload"]

    unless MapSet.new(Map.keys(result)) == expected and
             result["result_type"] == "imp_experiment_result" and
             result["schema_version"] in [1, 2, 3] and
             is_binary(result["payload_sha256"]) and is_map(payload) and
             result["payload_sha256"] == Imp.Experiment.Data.digest(payload) do
      raise ArgumentError, "invalid Imp experiment result envelope"
    end

    validate_payload!(payload, result["schema_version"])
    result
  end

  defp validate_payload!(payload, schema_version) do
    expected =
      MapSet.new(["status", "detail", "selected", "selection", "test", "artifact", "provenance"])
      |> then(fn keys ->
        if schema_version in [2, 3], do: MapSet.put(keys, "baseline_test"), else: keys
      end)
      |> then(fn keys ->
        if schema_version == 3, do: MapSet.put(keys, "repetitions"), else: keys
      end)

    selection = payload["selection"]

    valid? =
      MapSet.new(Map.keys(payload)) == expected and payload["status"] == "completed" and
        payload["detail"] in ["summary", "rows"] and
        payload["selected"] in ["baseline", "optimized"] and is_map(selection) and
        MapSet.new(Map.keys(selection)) == MapSet.new(["baseline", "optimized"]) and
        valid_evaluation?(selection["baseline"], payload["detail"]) and
        valid_evaluation?(selection["optimized"], payload["detail"]) and
        valid_optional_evaluation?(payload["baseline_test"], payload["detail"], schema_version) and
        valid_evaluation?(payload["test"], payload["detail"]) and is_map(payload["provenance"])

    valid? =
      valid? and valid_repetitions?(payload["repetitions"], payload["detail"], schema_version)

    unless valid?, do: raise(ArgumentError, "invalid Imp experiment result payload")
    Artifact.inspect(payload["artifact"])
    :ok
  end

  defp valid_evaluation?(evaluation, "summary") when is_map(evaluation) do
    MapSet.new(Map.keys(evaluation)) == MapSet.new(["score", "row_count", "error_count"]) and
      is_number(evaluation["score"]) and is_integer(evaluation["row_count"]) and
      is_integer(evaluation["error_count"])
  end

  defp valid_evaluation?(evaluation, "rows") when is_map(evaluation) do
    MapSet.new(Map.keys(evaluation)) ==
      MapSet.new(["score", "row_count", "error_count", "rows", "errors"]) and
      is_number(evaluation["score"]) and is_integer(evaluation["row_count"]) and
      is_integer(evaluation["error_count"]) and is_list(evaluation["rows"]) and
      is_list(evaluation["errors"])
  end

  defp valid_evaluation?(_evaluation, _detail), do: false

  defp valid_optional_evaluation?(_evaluation, _detail, 1), do: true

  defp valid_optional_evaluation?(nil, _detail, schema_version) when schema_version in [2, 3],
    do: true

  defp valid_optional_evaluation?(evaluation, detail, schema_version)
       when schema_version in [2, 3],
       do: valid_evaluation?(evaluation, detail)

  defp valid_repetitions?(_repetitions, _detail, schema_version) when schema_version in [1, 2],
    do: true

  defp valid_repetitions?(repetitions, detail, 3) when is_map(repetitions) do
    expected =
      MapSet.new([
        "count",
        "aggregation",
        "outer_row_evaluations",
        "stages",
        "paired_deltas"
      ])

    stages = repetitions["stages"]
    deltas = repetitions["paired_deltas"]
    opportunity = repetitions["outer_row_evaluations"]

    MapSet.new(Map.keys(repetitions)) == expected and
      is_integer(repetitions["count"]) and repetitions["count"] > 1 and
      repetitions["aggregation"] == "mean" and
      valid_opportunity?(opportunity) and is_map(stages) and
      MapSet.new(Map.keys(stages)) ==
        MapSet.new(~w(baseline_selection optimized_selection baseline_test test)) and
      valid_repetition_stage?(stages["baseline_selection"], detail, repetitions["count"]) and
      valid_repetition_stage?(stages["optimized_selection"], detail, repetitions["count"]) and
      valid_optional_repetition_stage?(stages["baseline_test"], detail, repetitions["count"]) and
      valid_repetition_stage?(stages["test"], detail, repetitions["count"]) and
      is_map(deltas) and MapSet.new(Map.keys(deltas)) == MapSet.new(~w(selection test)) and
      valid_deltas?(deltas["selection"], repetitions["count"]) and
      valid_optional_deltas?(deltas["test"], repetitions["count"])
  end

  defp valid_repetitions?(_repetitions, _detail, _schema_version), do: false

  defp valid_opportunity?(%{"stages" => stages, "total" => total})
       when is_map(stages) and is_integer(total) and total > 0 do
    Enum.all?(stages, fn {stage, count} ->
      stage in ~w(baseline_selection optimized_selection baseline_test test) and
        is_integer(count) and count > 0
    end) and Enum.sum(Map.values(stages)) == total
  end

  defp valid_opportunity?(_opportunity), do: false

  defp valid_repetition_stage?(stage, detail, count) when is_map(stage) do
    MapSet.new(Map.keys(stage)) == MapSet.new(~w(aggregate_score runs)) and
      is_number(stage["aggregate_score"]) and is_list(stage["runs"]) and
      length(stage["runs"]) == count and
      Enum.with_index(stage["runs"], 1)
      |> Enum.all?(fn {run, index} -> valid_repetition_run?(run, detail, index) end)
  end

  defp valid_repetition_stage?(_stage, _detail, _count), do: false

  defp valid_optional_repetition_stage?(nil, _detail, _count), do: true

  defp valid_optional_repetition_stage?(stage, detail, count),
    do: valid_repetition_stage?(stage, detail, count)

  defp valid_repetition_run?(run, "summary", index) when is_map(run) do
    MapSet.new(Map.keys(run)) == MapSet.new(~w(index score row_count error_count)) and
      run["index"] == index and is_number(run["score"]) and
      is_integer(run["row_count"]) and run["row_count"] >= 0 and
      is_integer(run["error_count"]) and run["error_count"] >= 0
  end

  defp valid_repetition_run?(run, "rows", index) when is_map(run) do
    MapSet.new(Map.keys(run)) ==
      MapSet.new(~w(index score row_count error_count rows errors)) and
      valid_repetition_run?(Map.drop(run, ~w(rows errors)), "summary", index) and
      is_list(run["rows"]) and is_list(run["errors"])
  end

  defp valid_repetition_run?(_run, _detail, _index), do: false

  defp valid_deltas?(deltas, count) when is_list(deltas) and length(deltas) == count,
    do: Enum.all?(deltas, &is_number/1)

  defp valid_deltas?(_deltas, _count), do: false
  defp valid_optional_deltas?(nil, _count), do: true
  defp valid_optional_deltas?(deltas, count), do: valid_deltas?(deltas, count)

  defp evaluation_map(%EvaluationResult{} = result, include_rows?) do
    summary = %{
      "score" => result.score,
      "row_count" => length(result.rows),
      "error_count" => length(result.errors)
    }

    if include_rows? do
      Map.merge(summary, %{
        "rows" => result |> EvaluationResult.output_rows() |> Imp.Optimizer.Report.json_safe(),
        "errors" =>
          result.errors
          |> Imp.Redaction.redact()
          |> Imp.Optimizer.Report.json_safe()
      })
    else
      summary
    end
  end

  defp evaluation_map(nil, _include_rows?), do: nil

  defp repetition_map(summary, include_rows?) do
    %{
      "count" => summary.count,
      "aggregation" => Atom.to_string(summary.aggregation),
      "outer_row_evaluations" => %{
        "stages" =>
          Map.new(summary.outer_row_evaluations.stages, fn {stage, count} ->
            {Atom.to_string(stage), count}
          end),
        "total" => summary.outer_row_evaluations.total
      },
      "stages" =>
        Map.new(summary.stages, fn {stage, value} ->
          {Atom.to_string(stage), repetition_stage_map(value, include_rows?)}
        end),
      "paired_deltas" => %{
        "selection" => summary.paired_deltas.selection,
        "test" => summary.paired_deltas.test
      }
    }
  end

  defp repetition_stage_map(nil, _include_rows?), do: nil

  defp repetition_stage_map(stage, include_rows?) do
    %{
      "aggregate_score" => stage.aggregate_score,
      "runs" => Enum.map(stage.runs, &repetition_run_map(&1, include_rows?))
    }
  end

  defp repetition_run_map(run, include_rows?) do
    evaluation = run.evaluation

    summary = %{
      "index" => run.index,
      "score" => evaluation.score,
      "row_count" => length(evaluation.rows),
      "error_count" => length(evaluation.errors)
    }

    if include_rows? do
      Map.merge(summary, %{
        "rows" =>
          evaluation |> EvaluationResult.output_rows() |> Imp.Optimizer.Report.json_safe(),
        "errors" =>
          evaluation.errors
          |> Imp.Redaction.redact()
          |> Imp.Optimizer.Report.json_safe()
      })
    else
      summary
    end
  end

  defp result_options!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "experiment result options must be keyword options")

    unknown = Keyword.keys(opts) -- [:include_rows]

    if unknown != [],
      do: raise(ArgumentError, "unknown experiment result options: #{inspect(unknown)}")

    include_rows? = Keyword.get(opts, :include_rows, false)
    unless is_boolean(include_rows?), do: raise(ArgumentError, ":include_rows must be boolean")
    include_rows?
  end
end
