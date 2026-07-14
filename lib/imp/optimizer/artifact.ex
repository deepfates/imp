defmodule Imp.Optimizer.Artifact do
  @moduledoc """
  Durable champion/challenger lifecycle for portable optimizer outputs.

  Artifacts contain checksummed `Imp.Saving` program states and redacted
  provenance. Applying a candidate copies only optimizable predictor parameters
  onto a compatible live program, preserving its runtime LMs, adapters, and
  trusted callbacks.
  """

  import Kernel, except: [inspect: 1]

  alias Imp.Optimizer.GEPA.EvaluationCache.Codec
  alias Imp.Optimizer.Report
  alias Imp.{ProgramParameters, Redaction, Saving}

  @artifact_type "imp_optimizer_artifact"
  @schema_version 2
  @artifact_keys MapSet.new([
                   "artifact_type",
                   "schema_version",
                   "payload_sha256",
                   "payload"
                 ])
  @payload_keys MapSet.new([
                  "revision",
                  "champion_id",
                  "candidates",
                  "history",
                  "provenance",
                  "security"
                ])
  @candidate_keys MapSet.new([
                    "id",
                    "program",
                    "program_sha256",
                    "score",
                    "report",
                    "metadata"
                  ])
  @history_keys MapSet.new(["champion_id", "revision"])

  @type artifact :: %{required(String.t()) => term()}
  @type candidate :: %{required(String.t()) => term()}
  @type selection :: :champion | String.t()

  @doc "Builds a checksummed candidate from a portable optimizer output."
  @spec candidate(String.t(), struct(), keyword()) :: candidate()
  def candidate(id, program, opts \\ [])

  def candidate(id, program, opts) when is_binary(id) and is_list(opts) do
    validate_keyword!(opts, [:registry, :score, :report, :metadata], "candidate/3")

    if id == "", do: raise(ArgumentError, "optimizer artifact candidate id cannot be empty")

    registry_opts = saving_opts(opts)

    state =
      program
      |> Saving.dump(registry_opts)
      |> sanitize()
      |> json_normalize!("optimizer candidate program")

    # A dump is not accepted as portable until the saving layer can restore it.
    restored = Saving.load(state, registry_opts)
    ensure_predictors!(restored)

    report =
      case Keyword.get(opts, :report) do
        nil ->
          nil

        %Report{} = value ->
          value |> Report.dump() |> sanitize()

        value when is_map(value) ->
          value |> Report.json_safe() |> sanitize()

        value ->
          raise ArgumentError,
                "optimizer artifact report must be a Report or map, got: #{Kernel.inspect(value)}"
      end

    candidate = %{
      "id" => id,
      "program" => state,
      "program_sha256" => Codec.checksum(state),
      "score" => validate_score!(Keyword.get(opts, :score)),
      "report" => report,
      "metadata" => opts |> Keyword.get(:metadata, %{}) |> sanitize()
    }

    candidate
    |> json_normalize!("optimizer candidate")
    |> validate_candidate!()
  end

  def candidate(id, _program, _opts),
    do:
      raise(
        ArgumentError,
        "optimizer artifact candidate id must be a non-empty string, got: #{Kernel.inspect(id)}"
      )

  @doc "Creates a versioned artifact from one champion and zero or more challengers."
  @spec new(candidate(), [candidate()], keyword()) :: artifact()
  def new(champion, challengers \\ [], opts \\ []) when is_list(challengers) and is_list(opts) do
    validate_keyword!(opts, [:provenance], "new/3")
    champion = validate_candidate!(champion)
    candidates = Enum.map([champion | challengers], &validate_candidate!/1)
    ids = Enum.map(candidates, & &1["id"])

    if length(ids) != MapSet.size(MapSet.new(ids)) do
      raise ArgumentError, "optimizer artifact candidate ids must be unique"
    end

    payload = %{
      "revision" => 1,
      "champion_id" => champion["id"],
      "candidates" => Map.new(candidates, &{&1["id"], &1}),
      "history" => [],
      "provenance" => opts |> Keyword.get(:provenance, %{}) |> sanitize(),
      "security" => security_proof()
    }

    seal(payload)
  end

  @doc "Atomically writes a validated artifact as owner-readable JSON."
  @spec write!(artifact(), Path.t()) :: :ok
  def write!(artifact, path) when is_binary(path) do
    artifact = validate!(artifact)
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    io = File.open!(temporary, [:write, :binary, :exclusive])

    try do
      File.chmod!(temporary, 0o600)
      :ok = IO.binwrite(io, Jason.encode!(artifact, pretty: true) <> "\n")
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

  @doc "Reads and validates a current-schema optimizer artifact."
  @spec read!(Path.t()) :: artifact()
  def read!(path) when is_binary(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> validate!()
  end

  @doc "Returns an operational summary without rehydrating program callbacks."
  @spec inspect(artifact()) :: map()
  def inspect(artifact) do
    payload = artifact |> validate!() |> Map.fetch!("payload")

    %{
      schema_version: @schema_version,
      revision: payload["revision"],
      champion_id: payload["champion_id"],
      challengers: Enum.reject(Map.keys(payload["candidates"]), &(&1 == payload["champion_id"])),
      candidates:
        payload["candidates"]
        |> Map.values()
        |> Enum.sort_by(& &1["id"])
        |> Enum.map(&Map.take(&1, ["id", "score", "report", "metadata", "program_sha256"])),
      rollback_depth: length(payload["history"]),
      provenance: payload["provenance"],
      security: payload["security"]
    }
  end

  @doc "Compares candidate scores and named predictor parameters."
  @spec compare(artifact(), selection(), selection(), keyword()) :: map()
  def compare(artifact, left, right, opts \\ []) do
    artifact = validate!(artifact)
    left_candidate = fetch_candidate!(artifact, left)
    right_candidate = fetch_candidate!(artifact, right)
    left_parameters = parameters(left_candidate, opts)
    right_parameters = parameters(right_candidate, opts)
    names = Map.keys(left_parameters) |> Enum.concat(Map.keys(right_parameters)) |> Enum.uniq()

    %{
      left_id: left_candidate["id"],
      right_id: right_candidate["id"],
      left_score: left_candidate["score"],
      right_score: right_candidate["score"],
      score_delta: score_delta(left_candidate["score"], right_candidate["score"]),
      changed_predictors:
        Enum.filter(names, &(left_parameters[&1] != right_parameters[&1])) |> Enum.sort()
    }
  end

  @doc "Applies one candidate's portable parameters to a compatible live program."
  @spec apply(artifact(), struct(), selection(), keyword()) :: struct()
  def apply(artifact, program, selection \\ :champion, opts \\ []) do
    candidate_program =
      artifact |> validate!() |> fetch_candidate!(selection) |> restore_program(opts)

    source = index_predictors(candidate_program)
    target = index_predictors(program)

    unless Map.keys(source) |> Enum.sort() == Map.keys(target) |> Enum.sort() do
      raise ArgumentError,
            "optimizer artifact predictor set is incompatible with the target program"
    end

    Enum.reduce(target, program, fn {identity, %{name: target_name, predictor: target_predictor}},
                                    acc ->
      source_predictor = source |> Map.fetch!(identity) |> Map.fetch!(:predictor)

      validate_signature_compatibility!(
        target_predictor.signature,
        source_predictor.signature,
        identity
      )

      ProgramParameters.update_predictor(acc, target_name, fn live_predictor ->
        live_predictor
        |> Imp.Predict.Predict.with_signature(source_predictor.signature)
        |> Imp.Predict.Predict.with_demos(source_predictor.demos)
        |> Map.put(:config, source_predictor.config)
      end)
    end)
  end

  @doc "Promotes a challenger and records the prior champion for rollback."
  @spec promote(artifact(), String.t()) :: artifact()
  def promote(artifact, candidate_id) when is_binary(candidate_id) do
    artifact = validate!(artifact)
    payload = artifact["payload"]
    _candidate = fetch_candidate!(artifact, candidate_id)

    if candidate_id == payload["champion_id"] do
      raise ArgumentError,
            "optimizer artifact candidate #{Kernel.inspect(candidate_id)} is already champion"
    end

    seal(%{
      payload
      | "revision" => payload["revision"] + 1,
        "champion_id" => candidate_id,
        "history" => [
          %{"champion_id" => payload["champion_id"], "revision" => payload["revision"]}
          | payload["history"]
        ]
    })
  end

  @doc "Restores the most recently preserved champion."
  @spec rollback(artifact()) :: artifact()
  def rollback(artifact) do
    artifact = validate!(artifact)
    payload = artifact["payload"]

    case payload["history"] do
      [%{"champion_id" => champion_id} | rest] ->
        seal(%{
          payload
          | "revision" => payload["revision"] + 1,
            "champion_id" => champion_id,
            "history" => rest
        })

      [] ->
        raise ArgumentError, "optimizer artifact has no preserved champion to roll back to"
    end
  end

  defp seal(payload) do
    payload = json_normalize!(payload, "optimizer artifact payload")

    %{
      "artifact_type" => @artifact_type,
      "schema_version" => @schema_version,
      "payload_sha256" => Codec.checksum(payload),
      "payload" => payload
    }
    |> validate!()
  end

  defp validate!(artifact) do
    validate_envelope!(artifact)

    unless artifact["schema_version"] == @schema_version do
      raise ArgumentError,
            "unsupported optimizer artifact schema version: #{Kernel.inspect(artifact["schema_version"])}"
    end

    payload = artifact["payload"]
    exact_keys!(payload, @payload_keys, "optimizer artifact payload")
    validate_checksum!(payload, artifact["payload_sha256"])
    validate_payload!(payload)
    artifact
  end

  defp validate_payload!(payload) do
    unless is_integer(payload["revision"]) and payload["revision"] > 0 do
      raise ArgumentError, "optimizer artifact revision must be a positive integer"
    end

    validate_candidates!(payload["candidates"], payload["champion_id"])
    validate_history!(payload["history"], payload["candidates"])

    unless is_map(payload["provenance"]) do
      raise ArgumentError, "optimizer artifact provenance must be a map"
    end

    unless payload["security"] == security_proof() do
      raise ArgumentError, "optimizer artifact security proof is missing or incompatible"
    end

    reject_sensitive_keys!(payload)
  end

  defp validate_candidates!(candidates, champion_id) do
    unless is_map(candidates) and map_size(candidates) > 0 do
      raise ArgumentError, "optimizer artifact candidates must be a non-empty map"
    end

    Enum.each(candidates, fn {id, candidate} ->
      validate_candidate!(candidate)

      if id != candidate["id"],
        do: raise(ArgumentError, "optimizer artifact candidate key/id mismatch")
    end)

    unless Map.has_key?(candidates, champion_id) do
      raise ArgumentError, "optimizer artifact champion does not identify a candidate"
    end
  end

  defp validate_envelope!(artifact) when is_map(artifact) do
    exact_keys!(artifact, @artifact_keys, "optimizer artifact envelope")

    unless artifact["artifact_type"] == @artifact_type do
      raise ArgumentError, "invalid optimizer artifact type"
    end
  end

  defp validate_envelope!(_artifact), do: raise(ArgumentError, "optimizer artifact must be a map")

  defp validate_candidate!(candidate) when is_map(candidate) do
    exact_keys!(candidate, @candidate_keys, "optimizer artifact candidate")

    unless is_binary(candidate["id"]) and candidate["id"] != "" do
      raise ArgumentError, "optimizer artifact candidate id must be a non-empty string"
    end

    unless is_map(candidate["program"]) do
      raise ArgumentError, "optimizer artifact candidate program must be a map"
    end

    validate_checksum!(candidate["program"], candidate["program_sha256"])
    validate_score!(candidate["score"])

    unless is_nil(candidate["report"]) or is_map(candidate["report"]) do
      raise ArgumentError, "optimizer artifact candidate report must be a map or nil"
    end

    unless is_map(candidate["metadata"]) do
      raise ArgumentError, "optimizer artifact candidate metadata must be a map"
    end

    reject_sensitive_keys!(candidate)
    candidate
  end

  defp validate_candidate!(candidate),
    do:
      raise(
        ArgumentError,
        "optimizer artifact candidate must be a map, got: #{Kernel.inspect(value_type(candidate))}"
      )

  defp validate_history!(history, candidates) when is_list(history) do
    Enum.each(history, fn entry ->
      exact_keys!(entry, @history_keys, "optimizer artifact history entry")

      unless Map.has_key?(candidates, entry["champion_id"]) and is_integer(entry["revision"]) and
               entry["revision"] > 0 do
        raise ArgumentError, "invalid optimizer artifact history entry"
      end
    end)
  end

  defp validate_history!(_history, _candidates),
    do: raise(ArgumentError, "optimizer artifact history must be a list")

  defp fetch_candidate!(artifact, :champion) do
    payload = artifact["payload"]
    Map.fetch!(payload["candidates"], payload["champion_id"])
  end

  defp fetch_candidate!(artifact, id) when is_binary(id) do
    case Map.fetch(artifact["payload"]["candidates"], id) do
      {:ok, candidate} ->
        candidate

      :error ->
        raise ArgumentError, "optimizer artifact has no candidate #{Kernel.inspect(id)}"
    end
  end

  defp fetch_candidate!(_artifact, selection),
    do:
      raise(
        ArgumentError,
        "optimizer artifact selection must be :champion or a candidate id, got: #{Kernel.inspect(selection)}"
      )

  defp parameters(candidate, opts) do
    candidate
    |> restore_program(opts)
    |> index_predictors()
    |> Map.new(fn {identity, %{predictor: predictor}} ->
      {identity,
       %{
         "signature" => Imp.Signature.dump(predictor.signature),
         "demos" => Report.json_safe(predictor.demos),
         "config" => Report.json_safe(predictor.config)
       }}
    end)
  end

  defp restore_program(candidate, opts) do
    validate_keyword!(opts, [:registry], "artifact operation")
    Saving.load(candidate["program"], saving_opts(opts))
  end

  defp index_predictors(program) do
    program
    |> ProgramParameters.predictors()
    |> Map.new(fn entry -> {name_identity(entry.name), entry} end)
  end

  defp ensure_predictors!(program) do
    if ProgramParameters.predictors(program) == [] do
      raise ArgumentError,
            "optimizer artifact candidates must expose at least one named predictor through Imp.ProgramParameters"
    end
  end

  defp name_identity(name) when is_atom(name), do: "atom:" <> Atom.to_string(name)
  defp name_identity(name) when is_binary(name), do: "string:" <> name

  defp validate_signature_compatibility!(left, right, identity) do
    shape = fn signature -> signature |> Imp.Signature.dump() |> Map.delete("instructions") end

    unless shape.(left) == shape.(right) do
      raise ArgumentError,
            "optimizer artifact predictor #{Kernel.inspect(identity)} has an incompatible signature"
    end
  end

  defp score_delta(left, right) when is_number(left) and is_number(right), do: right - left
  defp score_delta(_left, _right), do: nil

  defp validate_score!(nil), do: nil
  defp validate_score!(score) when is_number(score), do: score

  defp validate_score!(score),
    do:
      raise(
        ArgumentError,
        "optimizer artifact score must be a number or nil, got: #{Kernel.inspect(score)}"
      )

  defp saving_opts(opts), do: Keyword.take(opts, [:registry])

  defp validate_keyword!(opts, allowed, context) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "#{context} expects a keyword list")
    unknown = Keyword.keys(opts) -- allowed

    if unknown != [],
      do: raise(ArgumentError, "unknown #{context} options: #{Kernel.inspect(unknown)}")
  end

  defp validate_checksum!(payload, checksum) when is_binary(checksum) do
    expected = Codec.checksum(payload)

    unless byte_size(checksum) == byte_size(expected) and :crypto.hash_equals(checksum, expected) do
      raise ArgumentError, "optimizer artifact checksum mismatch"
    end
  end

  defp validate_checksum!(_payload, _checksum),
    do: raise(ArgumentError, "optimizer artifact checksum is invalid")

  defp exact_keys!(map, expected, context) when is_map(map) do
    unless MapSet.new(Map.keys(map)) == expected do
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end
  end

  defp exact_keys!(_value, _expected, context),
    do: raise(ArgumentError, "#{context} must be a map")

  defp sanitize(value) do
    value
    |> Redaction.redact()
    |> drop_sensitive_keys()
    |> json_normalize!("optimizer artifact metadata")
  end

  defp drop_sensitive_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, drop_sensitive_keys(value)} end)
    |> Map.reject(fn {key, _value} -> sensitive_key?(key) end)
  end

  defp drop_sensitive_keys(list) when is_list(list), do: Enum.map(list, &drop_sensitive_keys/1)
  defp drop_sensitive_keys(value), do: value

  defp reject_sensitive_keys!(value) do
    if contains_sensitive_key?(value) do
      raise ArgumentError, "optimizer artifact contains a credential-bearing key"
    end
  end

  defp contains_sensitive_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> sensitive_key?(key) or contains_sensitive_key?(value) end)
  end

  defp contains_sensitive_key?(list) when is_list(list),
    do: Enum.any?(list, &contains_sensitive_key?/1)

  defp contains_sensitive_key?(_value), do: false

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase() |> String.replace("-", "_")

    Enum.any?(Redaction.default_keys(), fn sensitive ->
      sensitive = sensitive |> to_string() |> String.downcase() |> String.replace("-", "_")
      normalized == sensitive or String.ends_with?(normalized, "_#{sensitive}")
    end)
  end

  defp security_proof do
    %{
      "credentials_absent" => true,
      "functions_absent" => true,
      "json_safe" => true,
      "redaction_policy" => "imp_default_v1"
    }
  end

  defp json_normalize!(value, context) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        Jason.decode!(encoded)

      {:error, error} ->
        raise ArgumentError,
              "#{context} must not contain runtime functions or non-JSON values: #{Exception.message(error)}"
    end
  end

  defp value_type(%module{}), do: module
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value), do: value
end
