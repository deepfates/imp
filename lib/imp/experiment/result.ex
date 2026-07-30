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

  @doc "Returns the JSON-safe durable result envelope (the live program is deliberately excluded)."
  def to_map(%__MODULE__{} = result) do
    Artifact.inspect(result.artifact)

    payload = %{
      "status" => "completed",
      "selected" => Atom.to_string(result.selected),
      "selection" => %{
        "baseline" => evaluation_map(result.baseline_selection),
        "optimized" => evaluation_map(result.optimized_selection)
      },
      "test" => evaluation_map(result.test),
      "artifact" => result.artifact,
      "provenance" => Imp.Optimizer.Report.encode_term(result.provenance)
    }

    %{
      "result_type" => "imp_experiment_result",
      "schema_version" => 1,
      "payload_sha256" => Imp.Experiment.Data.digest(payload),
      "payload" => payload
    }
  end

  @doc "Atomically writes a completed result after validating its optimizer artifact."
  def write!(%__MODULE__{} = result, path) when is_binary(path) do
    payload = Jason.encode!(to_map(result), pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, payload, [:sync])
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
    expected = MapSet.new(["status", "selected", "selection", "test", "artifact", "provenance"])
    selection = payload["selection"]

    valid? =
      MapSet.new(Map.keys(payload)) == expected and payload["status"] == "completed" and
        payload["selected"] in ["baseline", "optimized"] and is_map(selection) and
        MapSet.new(Map.keys(selection)) == MapSet.new(["baseline", "optimized"]) and
        valid_evaluation?(selection["baseline"]) and valid_evaluation?(selection["optimized"]) and
        valid_evaluation?(payload["test"]) and is_map(payload["provenance"])

    unless valid?, do: raise(ArgumentError, "invalid Imp experiment result payload")
    Artifact.inspect(payload["artifact"])
    :ok
  end

  defp valid_evaluation?(evaluation) when is_map(evaluation) do
    MapSet.new(Map.keys(evaluation)) == MapSet.new(["score", "rows", "errors"]) and
      is_number(evaluation["score"]) and is_list(evaluation["rows"]) and
      is_list(evaluation["errors"])
  end

  defp valid_evaluation?(_evaluation), do: false

  defp evaluation_map(%EvaluationResult{} = result) do
    %{
      "score" => result.score,
      "rows" => EvaluationResult.output_rows(result),
      "errors" => Imp.Optimizer.Report.encode_term(result.errors)
    }
  end
end
