defmodule Imp.Optimizer.Artifact do
  @moduledoc """
  Durable champion/challenger lifecycle for portable optimizer outputs.

  Artifacts contain checksummed `Imp.Saving` program states or explicit
  parameter-only snapshots and redacted provenance. Applying a candidate copies
  only optimizable predictor parameters onto a compatible live program,
  preserving its runtime LMs, adapters, and trusted callbacks. Persisted names
  remain strings and are resolved against that trusted live program; artifact
  bytes never create atoms or depend on unrelated modules preloading them.
  """

  import Kernel, except: [inspect: 1]

  alias Imp.Optimizer.GEPA.EvaluationCache.Codec
  alias Imp.Optimizer.Artifact.ParameterSnapshot
  alias Imp.Optimizer.Report
  alias Imp.{ProgramParameters, Redaction, Saving}

  @artifact_type "imp_optimizer_artifact"
  @schema_version 3
  @supported_schema_versions [2, 3]
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
  @common_candidate_keys MapSet.new(["id", "score", "report", "metadata"])
  @program_candidate_v2_keys MapSet.union(
                               @common_candidate_keys,
                               MapSet.new(["program", "program_sha256"])
                             )
  @program_candidate_v3_keys MapSet.put(@program_candidate_v2_keys, "kind")
  @value_candidate_keys MapSet.union(
                          @common_candidate_keys,
                          MapSet.new(["kind", "value", "value_sha256"])
                        )
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

    %{
      "id" => id,
      "kind" => "program",
      "program" => state,
      "program_sha256" => Codec.checksum(state),
      "score" => validate_score!(Keyword.get(opts, :score)),
      "report" => normalize_report(Keyword.get(opts, :report)),
      "metadata" => opts |> Keyword.get(:metadata, %{}) |> sanitize()
    }
    |> json_normalize!("optimizer candidate")
    |> validate_candidate!(3)
  end

  def candidate(id, _program, _opts),
    do:
      raise(
        ArgumentError,
        "optimizer artifact candidate id must be a non-empty string, got: #{Kernel.inspect(id)}"
      )

  @doc """
  Builds a checksummed candidate containing only named predictor parameters.

  Use this for consumer-defined multi-predictor modules that cannot and should
  not be serialized as arbitrary structs. The artifact retains each predictor's
  signature, demonstrations, and config, but never the consumer module, LM,
  adapter, callbacks, or other runtime state. Reconstruct the trusted program in
  the deploying application, then pass it to `apply/4`.
  """
  @spec parameter_candidate(String.t(), struct(), keyword()) :: candidate()
  def parameter_candidate(id, program, opts \\ [])

  def parameter_candidate(id, program, opts) when is_struct(program) and is_list(opts) do
    program
    |> ParameterSnapshot.from_program()
    |> then(&candidate(id, &1, opts))
  end

  def parameter_candidate(id, program, opts) do
    raise ArgumentError,
          "optimizer parameter candidate requires a program struct and keyword options, got: #{Kernel.inspect({id, program, opts})}"
  end

  @doc "Builds a checksummed candidate containing one canonical JSON value."
  @spec value_candidate(String.t(), term(), keyword()) :: candidate()
  def value_candidate(id, value, opts \\ [])

  def value_candidate(id, value, opts) when is_binary(id) and id != "" and is_list(opts) do
    validate_keyword!(opts, [:score, :report, :metadata], "value_candidate/3")
    value = canonical_json!(value, "optimizer artifact value")

    %{
      "id" => id,
      "kind" => "value",
      "value" => value,
      "value_sha256" => Codec.checksum(value),
      "score" => validate_score!(Keyword.get(opts, :score)),
      "report" => normalize_report(Keyword.get(opts, :report)),
      "metadata" => opts |> Keyword.get(:metadata, %{}) |> sanitize()
    }
    |> json_normalize!("optimizer value candidate")
    |> validate_candidate!(3)
  end

  def value_candidate(id, _value, _opts) do
    raise ArgumentError,
          "optimizer value candidate id must be a non-empty string, got: #{Kernel.inspect(id)}"
  end

  @doc """
  Captures the selected parameters and attached report from an optimized program.

  This is the shared durable handoff for program optimizers. The returned
  artifact contains no consumer module or runtime binding; deploying code must
  reconstruct a trusted compatible program and call `apply/4`.
  """
  @spec from_optimized_program(struct(), keyword()) :: artifact()
  def from_optimized_program(program, opts \\ [])

  def from_optimized_program(program, opts) when is_struct(program) and is_list(opts) do
    validate_keyword!(opts, [:artifact_id, :provenance], "from_optimized_program/2")

    report =
      Report.fetch(program) ||
        raise(ArgumentError, "optimized program does not carry an Imp optimizer report")

    optimizer = report.optimizer

    unless is_atom(optimizer) or (is_binary(optimizer) and optimizer != "") do
      raise ArgumentError, "optimized program report does not identify its optimizer"
    end

    id = Keyword.get(opts, :artifact_id, "#{optimizer}-champion")

    unless is_binary(id) and id != "" do
      raise ArgumentError, "optimizer artifact id must be a non-empty string"
    end

    candidate =
      parameter_candidate(id, program,
        score: report.best_score,
        report: report,
        metadata: %{optimizer: optimizer}
      )

    provenance = opts |> Keyword.get(:provenance, %{}) |> Map.put_new(:optimizer, optimizer)
    new(candidate, [], provenance: provenance)
  end

  def from_optimized_program(program, opts) do
    raise ArgumentError,
          "from_optimized_program/2 requires a program struct and keyword options, got: #{Kernel.inspect({program, opts})}"
  end

  @doc "Creates a versioned artifact from one champion and zero or more challengers."
  @spec new(candidate(), [candidate()], keyword()) :: artifact()
  def new(champion, challengers \\ [], opts \\ []) when is_list(challengers) and is_list(opts) do
    validate_keyword!(opts, [:provenance], "new/3")
    champion = validate_candidate!(champion, @schema_version)
    candidates = Enum.map([champion | challengers], &validate_candidate!(&1, @schema_version))
    ids = Enum.map(candidates, & &1["id"])
    kinds = candidates |> Enum.map(& &1["kind"]) |> Enum.uniq()

    if length(ids) != MapSet.size(MapSet.new(ids)) do
      raise ArgumentError, "optimizer artifact candidate ids must be unique"
    end

    if length(kinds) != 1 do
      raise ArgumentError, "optimizer artifact candidates must all have the same kind"
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

  @doc "Reads and validates a supported optimizer artifact schema."
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
      schema_version: artifact["schema_version"],
      revision: payload["revision"],
      champion_id: payload["champion_id"],
      challengers: Enum.reject(Map.keys(payload["candidates"]), &(&1 == payload["champion_id"])),
      candidates:
        payload["candidates"]
        |> Map.values()
        |> Enum.sort_by(& &1["id"])
        |> Enum.map(
          &Map.take(&1, [
            "id",
            "kind",
            "score",
            "report",
            "metadata",
            "program_sha256",
            "value_sha256"
          ])
        ),
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
    require_program_candidate!(left_candidate)
    require_program_candidate!(right_candidate)
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

  @doc "Applies one candidate's portable parameters and canonical report to a compatible live program."
  @spec apply(artifact(), struct(), selection(), keyword()) :: struct()
  def apply(artifact, program, selection \\ :champion, opts \\ []) do
    candidate = artifact |> validate!() |> fetch_candidate!(selection)
    require_program_candidate!(candidate)
    candidate_program = restore_program(candidate, opts)

    source = index_predictors(candidate_program)
    target = index_predictors(program)

    unless Map.keys(source) |> Enum.sort() == Map.keys(target) |> Enum.sort() do
      raise ArgumentError,
            "optimizer artifact predictor set is incompatible with the target program"
    end

    target
    |> Enum.reduce(program, fn {identity, %{name: target_name, predictor: target_predictor}},
                               acc ->
      source_predictor = source |> Map.fetch!(identity) |> Map.fetch!(:predictor)

      validate_signature_compatibility!(
        target_predictor.signature,
        source_predictor.signature,
        identity
      )

      ProgramParameters.update_predictor(acc, target_name, fn live_predictor ->
        live_predictor
        |> Imp.Predict.Predict.with_signature(
          resolve_signature(source_predictor.signature, target_predictor.signature, identity)
        )
        |> Imp.Predict.Predict.with_demos(
          resolve_demos(source_predictor.demos, target_predictor.signature, identity)
        )
        |> Map.put(:config, resolve_config(source_predictor.config, target_predictor.config))
      end)
    end)
    |> attach_candidate_report(candidate)
  end

  @doc "Returns one selected portable value without restoring executable code."
  @spec value(artifact(), selection()) :: term()
  def value(artifact, selection \\ :champion) do
    case artifact |> validate!() |> fetch_candidate!(selection) do
      %{"kind" => "value", "value" => value} ->
        value

      _program ->
        raise ArgumentError,
              "optimizer artifact candidate is a program; use apply/4 with a trusted compatible program"
    end
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

    seal(
      %{
        payload
        | "revision" => payload["revision"] + 1,
          "champion_id" => candidate_id,
          "history" => [
            %{"champion_id" => payload["champion_id"], "revision" => payload["revision"]}
            | payload["history"]
          ]
      },
      artifact["schema_version"]
    )
  end

  @doc "Restores the most recently preserved champion."
  @spec rollback(artifact()) :: artifact()
  def rollback(artifact) do
    artifact = validate!(artifact)
    payload = artifact["payload"]

    case payload["history"] do
      [%{"champion_id" => champion_id} | rest] ->
        seal(
          %{
            payload
            | "revision" => payload["revision"] + 1,
              "champion_id" => champion_id,
              "history" => rest
          },
          artifact["schema_version"]
        )

      [] ->
        raise ArgumentError, "optimizer artifact has no preserved champion to roll back to"
    end
  end

  defp seal(payload, schema_version \\ @schema_version) do
    payload = json_normalize!(payload, "optimizer artifact payload")

    %{
      "artifact_type" => @artifact_type,
      "schema_version" => schema_version,
      "payload_sha256" => Codec.checksum(payload),
      "payload" => payload
    }
    |> validate!()
  end

  defp validate!(artifact) do
    validate_envelope!(artifact)

    unless artifact["schema_version"] in @supported_schema_versions do
      raise ArgumentError,
            "unsupported optimizer artifact schema version: #{Kernel.inspect(artifact["schema_version"])}"
    end

    payload = artifact["payload"]
    exact_keys!(payload, @payload_keys, "optimizer artifact payload")
    validate_checksum!(payload, artifact["payload_sha256"])
    validate_payload!(payload, artifact["schema_version"])
    artifact
  end

  defp validate_payload!(payload, schema_version) do
    unless is_integer(payload["revision"]) and payload["revision"] > 0 do
      raise ArgumentError, "optimizer artifact revision must be a positive integer"
    end

    validate_candidates!(payload["candidates"], payload["champion_id"], schema_version)
    validate_history!(payload["history"], payload["candidates"])

    unless is_map(payload["provenance"]) do
      raise ArgumentError, "optimizer artifact provenance must be a map"
    end

    unless payload["security"] == security_proof() do
      raise ArgumentError, "optimizer artifact security proof is missing or incompatible"
    end

    reject_sensitive_keys!(payload)
  end

  defp validate_candidates!(candidates, champion_id, schema_version) do
    unless is_map(candidates) and map_size(candidates) > 0 do
      raise ArgumentError, "optimizer artifact candidates must be a non-empty map"
    end

    Enum.each(candidates, fn {id, candidate} ->
      validate_candidate!(candidate, schema_version)

      if id != candidate["id"],
        do: raise(ArgumentError, "optimizer artifact candidate key/id mismatch")
    end)

    if schema_version == 3 and
         candidates |> Map.values() |> Enum.map(& &1["kind"]) |> Enum.uniq() |> length() != 1 do
      raise ArgumentError, "optimizer artifact candidates must all have the same kind"
    end

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

  defp validate_candidate!(candidate, 2) when is_map(candidate) do
    exact_keys!(candidate, @program_candidate_v2_keys, "optimizer artifact program candidate")
    validate_program_candidate!(candidate)
  end

  defp validate_candidate!(%{"kind" => "program"} = candidate, 3) do
    exact_keys!(candidate, @program_candidate_v3_keys, "optimizer artifact program candidate")
    validate_program_candidate!(candidate)
  end

  defp validate_candidate!(%{"kind" => "value"} = candidate, 3) do
    exact_keys!(candidate, @value_candidate_keys, "optimizer artifact value candidate")
    validate_candidate_common!(candidate)
    canonical_json!(candidate["value"], "optimizer artifact value")
    validate_checksum!(candidate["value"], candidate["value_sha256"])
    candidate
  end

  defp validate_candidate!(candidate, 3) when is_map(candidate) do
    raise ArgumentError,
          "optimizer artifact candidate kind must be \"program\" or \"value\", got: #{Kernel.inspect(candidate["kind"])}"
  end

  defp validate_candidate!(candidate, _schema_version),
    do:
      raise(
        ArgumentError,
        "optimizer artifact candidate must be a map, got: #{Kernel.inspect(value_type(candidate))}"
      )

  defp validate_program_candidate!(candidate) do
    validate_candidate_common!(candidate)

    unless is_map(candidate["program"]),
      do: raise(ArgumentError, "optimizer artifact candidate program must be a map")

    validate_checksum!(candidate["program"], candidate["program_sha256"])
    candidate
  end

  defp validate_candidate_common!(candidate) do
    unless is_binary(candidate["id"]) and candidate["id"] != "",
      do: raise(ArgumentError, "optimizer artifact candidate id must be a non-empty string")

    validate_score!(candidate["score"])

    unless is_nil(candidate["report"]) or is_map(candidate["report"]),
      do: raise(ArgumentError, "optimizer artifact candidate report must be a map or nil")

    unless is_map(candidate["metadata"]),
      do: raise(ArgumentError, "optimizer artifact candidate metadata must be a map")

    reject_sensitive_keys!(candidate)
    candidate
  end

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
         "demos" => Report.encode_term(predictor.demos),
         "config" => Report.encode_term(predictor.config)
       }}
    end)
  end

  defp restore_program(candidate, opts) do
    validate_keyword!(opts, [:registry], "artifact operation")
    Saving.load(candidate["program"], saving_opts(opts))
  end

  defp require_program_candidate!(%{"kind" => "value"}) do
    raise ArgumentError,
          "optimizer artifact candidate contains a value; use value/2 instead of apply/4"
  end

  defp require_program_candidate!(_program), do: :ok

  defp normalize_report(nil), do: nil
  defp normalize_report(%Report{} = report), do: report |> Report.dump() |> sanitize()

  defp normalize_report(report) when is_map(report),
    do: report |> Report.encode_term() |> sanitize()

  defp normalize_report(report) do
    raise ArgumentError,
          "optimizer artifact report must be a Report or map, got: #{Kernel.inspect(report)}"
  end

  defp canonical_json!(value, context) do
    canonical = json_normalize!(value, context)

    unless canonical === value do
      raise ArgumentError, "#{context} must already be canonical JSON with string map keys"
    end

    canonical
  end

  defp attach_candidate_report(program, %{"report" => report}) when is_map(report) do
    expected = MapSet.new(~w(optimizer best_score candidate_count candidates errors metadata))

    if MapSet.equal?(MapSet.new(Map.keys(report)), expected) do
      Report.attach(program, Report.load_portable(report))
    else
      program
    end
  end

  defp attach_candidate_report(program, _candidate), do: program

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

  defp name_identity(name) when is_atom(name), do: Atom.to_string(name)
  defp name_identity(name) when is_binary(name), do: name

  defp resolve_signature(source, target, identity) do
    %{
      source
      | inputs: resolve_fields(source.inputs, target.inputs, identity),
        outputs: resolve_fields(source.outputs, target.outputs, identity)
    }
  end

  defp resolve_fields(source_fields, target_fields, identity) do
    trusted = Map.new(target_fields, &{canonical_identifier(&1.name), &1})

    Enum.map(source_fields, fn source ->
      case Map.fetch(trusted, canonical_identifier(source.name)) do
        {:ok, target} ->
          %{source | name: target.name, kind: target.kind, type: target.type}

        :error ->
          raise ArgumentError,
                "optimizer artifact predictor #{Kernel.inspect(identity)} names an unknown signature field #{Kernel.inspect(source.name)}"
      end
    end)
  end

  defp resolve_demos(demos, signature, identity) do
    trusted =
      (signature.inputs ++ signature.outputs)
      |> Map.new(&{canonical_identifier(&1.name), &1.name})

    Enum.map(demos, &resolve_demo(&1, trusted, identity))
  end

  defp resolve_demo(%Imp.Example{} = example, trusted, identity) do
    fields =
      example
      |> Imp.Example.to_map()
      |> Map.new(fn {name, value} ->
        canonical = canonical_identifier(name)

        case Map.fetch(trusted, canonical) do
          {:ok, trusted_name} -> {trusted_name, value}
          :error -> {canonical, value}
        end
      end)

    input_keys =
      case example.input_keys do
        nil ->
          nil

        keys ->
          Enum.map(keys, fn name ->
            Map.get_lazy(trusted, canonical_identifier(name), fn ->
              raise ArgumentError,
                    "optimizer artifact predictor #{Kernel.inspect(identity)} demo names an unknown input #{Kernel.inspect(name)}"
            end)
          end)
      end

    fields
    |> Imp.Example.new()
    |> maybe_with_inputs(input_keys)
    |> maybe_with_nested_demos(example.demos, trusted, identity)
  end

  defp resolve_config(source, target) when is_list(source) and is_list(target) do
    trusted = Map.new(target, fn {name, _value} -> {canonical_identifier(name), name} end)

    Enum.map(source, fn {name, value} ->
      {Map.get(trusted, canonical_identifier(name), canonical_identifier(name)), value}
    end)
  end

  defp resolve_config(source, _target), do: source

  defp maybe_with_inputs(example, nil), do: example
  defp maybe_with_inputs(example, keys), do: Imp.Example.with_inputs(example, keys)

  defp maybe_with_nested_demos(example, [], _trusted, _identity), do: example

  defp maybe_with_nested_demos(example, demos, trusted, identity) do
    Imp.Example.with_demos(example, Enum.map(demos, &resolve_demo(&1, trusted, identity)))
  end

  defp canonical_identifier(name) when is_atom(name), do: Atom.to_string(name)
  defp canonical_identifier(name) when is_binary(name), do: name

  defp validate_signature_compatibility!(left, right, identity) do
    shape = fn signature ->
      signature
      |> Imp.Signature.dump()
      |> Map.delete("instructions")
      |> Map.update!("outputs", fn outputs ->
        Enum.map(outputs, &Map.delete(&1, "prefix"))
      end)
      |> Jason.encode!()
      |> Jason.decode!()
    end

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
    unless MapSet.equal?(MapSet.new(Map.keys(map)), expected) do
      raise ArgumentError, "#{context} has unexpected or missing keys"
    end
  end

  defp exact_keys!(_value, _expected, context),
    do: raise(ArgumentError, "#{context} must be a map")

  defp sanitize(value) do
    value
    |> Redaction.drop_credentials()
    |> json_normalize!("optimizer artifact metadata")
  end

  defp contains_sensitive_key?(%{"__imp_type__" => "map", "entries" => entries})
       when is_list(entries) do
    Enum.any?(entries, fn
      [encoded_key, value] ->
        sensitive_entry?(encoded_key, value) or contains_sensitive_key?(value)

      value ->
        contains_sensitive_key?(value)
    end)
  end

  defp contains_sensitive_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      sensitive_entry?(key, value) or contains_sensitive_key?(value)
    end)
  end

  defp contains_sensitive_key?(list) when is_list(list),
    do: Enum.any?(list, &contains_sensitive_key?/1)

  defp contains_sensitive_key?(_value), do: false

  defp reject_sensitive_keys!(value) do
    if contains_sensitive_key?(value) do
      raise ArgumentError, "optimizer artifact contains a credential-bearing key"
    end
  end

  defp sensitive_entry?(key, value), do: Redaction.credential_entry?(key, value)

  defp security_proof do
    %{
      "credentials_absent" => true,
      "functions_absent" => true,
      "json_safe" => true,
      "redaction_policy" => "imp_default_v1"
    }
  end

  defp json_normalize!(value, context) do
    reject_json_key_collisions!(value, context)

    case Jason.encode(value) do
      {:ok, encoded} ->
        Jason.decode!(encoded)

      {:error, error} ->
        raise ArgumentError,
              "#{context} must not contain runtime functions or non-JSON values: #{Exception.message(error)}"
    end
  end

  defp reject_json_key_collisions!(value, context) when is_map(value) do
    normalized_keys = Enum.map(Map.keys(value), &normalized_json_key/1)

    if length(normalized_keys) != MapSet.size(MapSet.new(normalized_keys)) do
      raise ArgumentError, "#{context} contains map keys that collide after JSON normalization"
    end

    Enum.each(value, fn {key, nested} ->
      reject_json_key_collisions!(key, context)
      reject_json_key_collisions!(nested, context)
    end)
  end

  defp reject_json_key_collisions!(value, context) when is_list(value),
    do: Enum.each(value, &reject_json_key_collisions!(&1, context))

  defp reject_json_key_collisions!(value, context) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.each(&reject_json_key_collisions!(&1, context))

  defp reject_json_key_collisions!(_value, _context), do: :ok

  defp normalized_json_key(key) when is_atom(key), do: {:json, Atom.to_string(key)}
  defp normalized_json_key(key) when is_binary(key), do: {:json, key}
  defp normalized_json_key(key) when is_integer(key), do: {:json, Integer.to_string(key)}
  defp normalized_json_key(key), do: {:term, :erlang.term_to_binary(key, [:deterministic])}

  defp value_type(%module{}), do: module
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value), do: value
end
