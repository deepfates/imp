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
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: :completed,
          selected: :baseline | :optimized,
          program: struct(),
          artifact: map(),
          baseline_selection: EvaluationResult.t(),
          optimized_selection: EvaluationResult.t(),
          test: EvaluationResult.t(),
          provenance: map()
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
      "test" => evaluation_map(result.test, include_rows?),
      "artifact" => result.artifact,
      "provenance" => Imp.Optimizer.Report.json_safe(result.provenance)
    }

    %{
      "result_type" => "imp_experiment_result",
      "schema_version" => 1,
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
             result["result_type"] == "imp_experiment_result" and result["schema_version"] == 1 and
             is_binary(result["payload_sha256"]) and is_map(payload) and
             result["payload_sha256"] == Imp.Experiment.Data.digest(payload) do
      raise ArgumentError, "invalid Imp experiment result envelope"
    end

    validate_payload!(payload)
    result
  end

  defp validate_payload!(payload) do
    expected =
      MapSet.new(["status", "detail", "selected", "selection", "test", "artifact", "provenance"])

    selection = payload["selection"]

    valid? =
      MapSet.new(Map.keys(payload)) == expected and payload["status"] == "completed" and
        payload["detail"] in ["summary", "rows"] and
        payload["selected"] in ["baseline", "optimized"] and is_map(selection) and
        MapSet.new(Map.keys(selection)) == MapSet.new(["baseline", "optimized"]) and
        valid_evaluation?(selection["baseline"], payload["detail"]) and
        valid_evaluation?(selection["optimized"], payload["detail"]) and
        valid_evaluation?(payload["test"], payload["detail"]) and is_map(payload["provenance"])

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

  defp evaluation_map(%EvaluationResult{} = result, include_rows?) do
    summary = %{
      "score" => result.score,
      "row_count" => length(result.rows),
      "error_count" => length(result.errors)
    }

    if include_rows? do
      Map.merge(summary, %{
        "rows" => result |> EvaluationResult.output_rows() |> Imp.Optimizer.Report.json_safe(),
        "errors" => Imp.Optimizer.Report.json_safe(result.errors)
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
