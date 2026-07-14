defmodule DSEx.ReproductionRegistry do
  @moduledoc false

  @tiers ~w(none t0 t1 t2 t3)
  @states ~w(red yellow green)
  @classifications ~w(replication adaptation native_extension)
  @protocol_modes ~w(provider_free live)

  def load!(path \\ "benchmarks/reproductions.json", opts \\ []) do
    registry = path |> File.read!() |> Jason.decode!()
    authority_path = Keyword.get(opts, :authority_path, "benchmarks/authorities.json")
    root = Keyword.get(opts, :root, File.cwd!())
    validate!(registry, DSEx.EvidenceAuthorities.load!(authority_path), root)
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
      raise ArgumentError,
            "invalid reproduction registry #{Path.expand(path)}: #{Exception.message(error)}"
  end

  def validate!(
        %{"schema_version" => 1, "protocols" => protocols, "features" => features} = registry,
        %{"families" => families},
        root
      )
      when is_map(protocols) and map_size(protocols) > 0 and is_list(features) and features != [] do
    authority_by_id = Map.new(families, &{Map.fetch!(&1, "id"), &1})

    validate_unique_ids!(features)
    validate_exact_authority_coverage!(features, authority_by_id)
    validate_surface_token_coverage!(features, authority_by_id)
    Enum.each(protocols, &validate_protocol!(&1, root))
    Enum.each(features, &validate_feature!(&1, authority_by_id, protocols, root))
    registry
  end

  def validate!(_registry, _authorities, _root),
    do: raise(ArgumentError, "expected schema_version 1 with protocols and features")

  def render(%{"features" => features}) do
    header = [
      "| Feature | Class | Tier | State | Protocols | Blocking constraints |",
      "| --- | --- | --- | --- | --- | --- |"
    ]

    rows =
      Enum.map(features, fn feature ->
        evidence = feature["evidence"]

        values = [
          feature["name"],
          feature["classification"],
          String.upcase(evidence["tier"]),
          evidence["claim_state"],
          Enum.join(feature["protocol_ids"], "<br>"),
          constraint_summary(feature["constraints"])
        ]

        "| " <> Enum.map_join(values, " | ", &escape_cell/1) <> " |"
      end)

    Enum.join(header ++ rows, "\n")
  end

  def replace_summary!(body, table) do
    start_marker = "<!-- reproduction-registry:start -->"
    end_marker = "<!-- reproduction-registry:end -->"
    pattern = ~r/#{Regex.escape(start_marker)}.*?#{Regex.escape(end_marker)}/s

    unless Regex.match?(pattern, body),
      do: raise(ArgumentError, "reproduction registry summary markers are missing")

    Regex.replace(pattern, body, Enum.join([start_marker, table, end_marker], "\n"))
  end

  defp validate_unique_ids!(features) do
    ids = Enum.map(features, &Map.fetch!(&1, "id"))
    public_surfaces = Enum.flat_map(features, &Map.fetch!(&1, "public_surfaces"))

    unless ids == Enum.uniq(ids), do: raise(ArgumentError, "feature ids must be unique")

    unless public_surfaces == Enum.uniq(public_surfaces),
      do: raise(ArgumentError, "public surfaces must be owned exactly once")
  end

  defp validate_exact_authority_coverage!(features, authority_by_id) do
    covered = features |> Enum.map(& &1["authority_family"]) |> Enum.uniq() |> Enum.sort()
    expected = authority_by_id |> Map.keys() |> Enum.sort()

    unless covered == expected do
      raise ArgumentError,
            "reproduction coverage differs from authority ledger: missing=#{inspect(expected -- covered)} extra=#{inspect(covered -- expected)}"
    end
  end

  defp validate_surface_token_coverage!(features, authority_by_id) do
    Enum.each(authority_by_id, fn {family_id, authority} ->
      covered =
        features
        |> Enum.filter(&(&1["authority_family"] == family_id))
        |> Enum.flat_map(& &1["surface_tokens"])
        |> Enum.uniq()
        |> Enum.sort()

      expected = Enum.sort(authority["surface_tokens"])

      unless covered == expected do
        raise ArgumentError,
              "surface token coverage differs for #{family_id}: missing=#{inspect(expected -- covered)} extra=#{inspect(covered -- expected)}"
      end
    end)
  end

  defp validate_protocol!({id, protocol}, root) when is_binary(id) and is_map(protocol) do
    require_nonempty!(id, "protocol id")
    require_member!(protocol["mode"], @protocol_modes, "protocol #{id} mode")
    require_member!(protocol["max_tier"], @tiers -- ["none"], "protocol #{id} max_tier")
    require_task!(protocol["task"], "protocol #{id}")

    unless is_list(protocol["args"]),
      do: raise(ArgumentError, "protocol #{id} args must be a list")

    case protocol["manifest"] do
      nil -> :ok
      path -> require_file!(path, root, "protocol #{id} manifest")
    end

    validate_artifact_validator!(protocol["artifact_validator"], id)
  end

  defp validate_protocol!(_, _root),
    do: raise(ArgumentError, "protocol entries must be named objects")

  defp validate_artifact_validator!(%{"mode" => "task", "task" => task}, id),
    do: require_task!(task, "protocol #{id} artifact validator")

  defp validate_artifact_validator!(
         %{"mode" => "module", "module" => module_name, "function" => function, "arity" => arity},
         id
       ) do
    module =
      try do
        String.to_existing_atom(module_name)
      rescue
        ArgumentError -> raise ArgumentError, "protocol #{id} validator module does not exist"
      end

    function_atom =
      try do
        String.to_existing_atom(function)
      rescue
        ArgumentError -> raise ArgumentError, "protocol #{id} validator function does not exist"
      end

    unless is_integer(arity) and arity >= 0 and Code.ensure_loaded?(module) and
             function_exported?(module, function_atom, arity) do
      raise ArgumentError, "protocol #{id} artifact validator is not exported"
    end
  end

  defp validate_artifact_validator!(_, id),
    do: raise(ArgumentError, "protocol #{id} must declare an executable artifact validator")

  defp validate_feature!(feature, authority_by_id, protocols, root) do
    id = feature["id"]
    require_nonempty!(id, "feature id")
    require_nonempty!(feature["name"], "feature #{id} name")
    require_member!(feature["classification"], @classifications, "feature #{id} classification")

    authority =
      Map.get(authority_by_id, feature["authority_family"]) ||
        raise(ArgumentError, "feature #{id} names an unknown authority family")

    public_surfaces = feature["public_surfaces"]

    unless is_list(public_surfaces) and public_surfaces != [] and
             Enum.all?(public_surfaces, &(is_binary(&1) and &1 != "")) and
             public_surfaces == Enum.uniq(public_surfaces) do
      raise ArgumentError, "feature #{id} must uniquely name public surfaces"
    end

    tokens = feature["surface_tokens"]

    unless is_list(tokens) and Enum.all?(tokens, &(&1 in authority["surface_tokens"])) do
      raise ArgumentError, "feature #{id} surface tokens are outside its authority family"
    end

    paths = feature["implementation_paths"]

    unless is_list(paths) and paths != [],
      do: raise(ArgumentError, "feature #{id} must name implementation paths")

    Enum.each(paths, &require_file!(&1, root, "feature #{id} implementation"))

    protocol_ids = feature["protocol_ids"]

    unless is_list(protocol_ids) and protocol_ids != [] and
             protocol_ids == Enum.uniq(protocol_ids),
           do: raise(ArgumentError, "feature #{id} must name unique protocols")

    Enum.each(protocol_ids, fn protocol_id ->
      unless Map.has_key?(protocols, protocol_id),
        do: raise(ArgumentError, "feature #{id} names unknown protocol #{protocol_id}")
    end)

    validate_constraints!(feature["constraints"], id)
    validate_evidence!(feature["evidence"], feature, protocols, root)
  end

  defp validate_constraints!(constraints, id) do
    unless is_list(constraints) and
             Enum.all?(constraints, fn constraint ->
               is_map(constraint) and constraint["status"] in ~w(open resolved) and
                 is_binary(constraint["kind"]) and constraint["kind"] != "" and
                 is_binary(constraint["detail"]) and constraint["detail"] != ""
             end) do
      raise ArgumentError, "feature #{id} has invalid constraints"
    end
  end

  defp validate_evidence!(evidence, feature, protocols, root) when is_map(evidence) do
    id = feature["id"]
    tier = evidence["tier"]
    state = evidence["claim_state"]
    require_member!(tier, @tiers, "feature #{id} evidence tier")
    require_member!(state, @states, "feature #{id} claim state")

    expected_state =
      if(tier == "none", do: "red", else: if(tier == "t3", do: "green", else: "yellow"))

    unless state == expected_state,
      do: raise(ArgumentError, "feature #{id} claim state overstates tier #{tier}")

    open_constraints = Enum.filter(feature["constraints"], &(&1["status"] == "open"))

    if state == "green" and open_constraints != [],
      do: raise(ArgumentError, "feature #{id} cannot be green with open constraints")

    case {tier, evidence["artifact"], evidence["protocol_id"]} do
      {"none", nil, nil} ->
        if evidence["artifact_sha256"] not in [nil, ""],
          do: raise(ArgumentError, "feature #{id} none evidence cannot name an artifact digest")

        :ok

      {"none", _, _} ->
        raise ArgumentError, "feature #{id} none evidence cannot name an artifact or protocol"

      {_, artifact, protocol_id} when is_binary(artifact) and is_binary(protocol_id) ->
        if String.contains?(artifact, ["*", "?"]),
          do:
            raise(ArgumentError, "feature #{id} admitted artifact must be immutable, not a glob")

        require_file!(artifact, root, "feature #{id} admitted artifact")
        expected_sha256 = evidence["artifact_sha256"]

        unless is_binary(expected_sha256) and Regex.match?(~r/^[0-9a-f]{64}$/, expected_sha256),
          do: raise(ArgumentError, "feature #{id} admitted artifact must have a SHA-256 digest")

        actual_sha256 =
          root
          |> Path.join(artifact)
          |> File.read!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        unless actual_sha256 == expected_sha256,
          do: raise(ArgumentError, "feature #{id} admitted artifact digest mismatch")

        protocol =
          Map.get(protocols, protocol_id) ||
            raise(ArgumentError, "feature #{id} evidence names unknown protocol")

        unless protocol_id in feature["protocol_ids"],
          do:
            raise(ArgumentError, "feature #{id} evidence protocol is not assigned to the feature")

        if tier_rank(tier) > tier_rank(protocol["max_tier"]),
          do: raise(ArgumentError, "feature #{id} evidence exceeds protocol tier")

      _ ->
        raise ArgumentError,
              "feature #{id} admitted evidence must name both artifact and protocol"
    end
  end

  defp validate_evidence!(_, feature, _protocols, _root),
    do: raise(ArgumentError, "feature #{feature["id"]} has invalid evidence")

  defp require_task!(task, context) do
    require_nonempty!(task, "#{context} task")
    Mix.Task.load_all()

    unless Mix.Task.get(task),
      do: raise(ArgumentError, "#{context} task #{task} does not resolve")
  end

  defp require_file!(path, root, context) do
    require_nonempty!(path, context)

    if Path.type(path) == :absolute or String.contains?(path, ["..", "*", "?"]),
      do: raise(ArgumentError, "#{context} must be a literal project-relative path")

    unless File.regular?(Path.join(root, path)),
      do: raise(ArgumentError, "#{context} does not exist: #{path}")
  end

  defp require_member!(value, allowed, context) do
    unless value in allowed,
      do: raise(ArgumentError, "#{context} must be one of #{Enum.join(allowed, ", ")}")
  end

  defp require_nonempty!(value, context) do
    unless is_binary(value) and value != "",
      do: raise(ArgumentError, "#{context} must be non-empty")
  end

  defp tier_rank(tier), do: Enum.find_index(@tiers, &(&1 == tier))
  defp escape_cell(value), do: value |> to_string() |> String.replace("|", "\\|")

  defp constraint_summary([]), do: "none"

  defp constraint_summary(constraints) do
    constraints
    |> Enum.filter(&(&1["status"] == "open"))
    |> case do
      [] -> "none"
      open -> Enum.map_join(open, "<br>", & &1["kind"])
    end
  end
end
