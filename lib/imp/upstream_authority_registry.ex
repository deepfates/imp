defmodule Imp.UpstreamAuthorityRegistry do
  @moduledoc false

  @registry_path Path.expand("../../benchmarks/authorities.json", __DIR__)
  @required_authorities ~w(
    dspy_stable
    dspy_instruction_optimizers
    gepa_v0_1_1_contract
    optimize_anything_artifact
    req_llm
    swe_bench_verified
  )
  @required_contracts %{
    "dspy_stable_upstream_fidelity" => "dspy_stable",
    "optimize_anything_swe_bench_flask_5014_dataset" => "swe_bench_verified",
    "optimize_anything_upstream_differential_protocol" => "optimize_anything_artifact",
    "req_llm_beam_runtime_dependency" => "req_llm",
    "t1_gepa_v011_structural_differential_contract" => "gepa_v0_1_1_contract",
    "t1_instruction_optimizer_differential_contract" => "dspy_instruction_optimizers"
  }
  @hex40 ~r/\A[0-9a-f]{40}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc false
  def path, do: @registry_path

  @doc false
  def load!(path \\ @registry_path) do
    ledger =
      path
      |> File.read!()
      |> Jason.decode!()

    ledger
    |> project!(path)
    |> validate!(path)
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid upstream authority ledger #{Path.expand(path)}: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  @doc false
  def authority!(registry, contract_id) do
    contract = registry |> Map.fetch!("contracts") |> Map.fetch!(contract_id)
    authority_id = Map.fetch!(contract, "authority")
    registry |> Map.fetch!("authorities") |> Map.fetch!(authority_id)
  rescue
    KeyError ->
      reraise ArgumentError,
              [message: "upstream authority registry has no contract #{inspect(contract_id)}"],
              __STACKTRACE__
  end

  defp project!(
         %{
           "schema_version" => 1,
           "pinned_sources" => pinned_sources,
           "contracts" => contracts
         },
         path
       )
       when is_map(pinned_sources) and is_map(contracts) do
    validate_required_bindings!(contracts)

    contract_ids_by_authority =
      Enum.reduce(contracts, %{}, fn
        {contract_id, %{"authority" => authority_id}}, acc
        when is_binary(contract_id) and is_binary(authority_id) ->
          Map.update(acc, authority_id, [contract_id], &[contract_id | &1])

        _entry, _acc ->
          raise ArgumentError, "contracts in #{Path.expand(path)} must name one authority"
      end)

    authorities =
      Map.new(contract_ids_by_authority, fn {authority_id, contract_ids} ->
        source =
          Map.get(pinned_sources, authority_id) ||
            raise(ArgumentError, "contract authority #{authority_id} is not pinned")

        authority =
          source
          |> Map.put("project", project_name!(source, authority_id))
          |> Map.put("source_hashes", source_hashes!(source, authority_id))
          |> Map.put("contract_ids", Enum.sort(contract_ids))

        {authority_id, authority}
      end)

    %{
      "schema_version" => 1,
      "authorities" => authorities,
      "contracts" => contracts
    }
  end

  defp project!(_ledger, _path) do
    raise ArgumentError,
          "expected schema_version 1 with pinned_sources and canonical contract bindings"
  end

  defp source_hashes!(%{"source_hashes" => hashes}, _id)
       when is_map(hashes) and map_size(hashes) > 0,
       do: hashes

  defp source_hashes!(%{"files" => files}, id) when is_list(files) and files != [] do
    Map.new(files, fn
      %{"path" => path, "sha256" => sha256}
      when is_binary(path) and is_binary(sha256) ->
        {path, sha256}

      _file ->
        raise ArgumentError, "authority #{id} has an invalid pinned file"
    end)
  end

  defp source_hashes!(_source, id),
    do: raise(ArgumentError, "authority #{id} has no exact source hashes")

  defp project_name!(%{"repository" => repository}, id) when is_binary(repository) do
    case URI.parse(repository) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) and path != "" ->
        String.trim(path, "/")

      _uri ->
        raise ArgumentError, "authority #{id} has an invalid repository URL"
    end
  end

  defp project_name!(_source, id),
    do: raise(ArgumentError, "authority #{id} has no repository URL")

  defp validate!(
         %{"schema_version" => 1, "authorities" => authorities, "contracts" => contracts} =
           registry,
         path
       )
       when is_map(authorities) and is_map(contracts) and map_size(authorities) > 0 and
              map_size(contracts) > 0 do
    require_names!(authorities, @required_authorities, "authorities")
    require_names!(contracts, Map.keys(@required_contracts), "contracts")
    validate_required_bindings!(contracts)
    Enum.each(authorities, &validate_authority!/1)
    Enum.each(contracts, &validate_contract!(&1, authorities))

    declared =
      authorities
      |> Enum.flat_map(fn {_id, authority} -> authority["contract_ids"] end)
      |> Enum.sort()

    actual = contracts |> Map.keys() |> Enum.sort()

    if declared != actual do
      raise ArgumentError,
            "contract identifiers must be declared exactly once by their authorities in #{Path.expand(path)}"
    end

    registry
  end

  defp validate!(_registry, _path),
    do: raise(ArgumentError, "expected schema_version 1 with non-empty authorities and contracts")

  defp validate_authority!({id, authority}) when is_binary(id) and is_map(authority) do
    Enum.each(["project", "repository", "version", "git_ref", "commit"], fn key ->
      require_string!(authority, key, "authority #{id}")
    end)

    require_hash!(authority["commit"], @hex40, "authority #{id} commit")

    hashes = Map.fetch!(authority, "source_hashes")

    unless is_map(hashes) and map_size(hashes) > 0 do
      raise ArgumentError, "authority #{id} source_hashes must be a non-empty object"
    end

    Enum.each(hashes, fn {name, hash} ->
      require_hash!(hash, @hex64, "authority #{id} source hash #{inspect(name)}")
    end)

    contract_ids = Map.fetch!(authority, "contract_ids")

    unless is_list(contract_ids) and contract_ids != [] and
             Enum.all?(contract_ids, &(is_binary(&1) and &1 != "")) and
             length(contract_ids) == length(Enum.uniq(contract_ids)) do
      raise ArgumentError, "authority #{id} contract_ids must be a non-empty unique string list"
    end
  end

  defp validate_authority!(_), do: raise(ArgumentError, "authority entries must be named objects")

  defp validate_contract!({contract_id, %{"authority" => authority_id}}, authorities)
       when is_binary(contract_id) and contract_id != "" and is_binary(authority_id) do
    authority =
      Map.get(authorities, authority_id) ||
        raise(ArgumentError, "contract #{contract_id} names missing authority #{authority_id}")

    unless contract_id in authority["contract_ids"] do
      raise ArgumentError,
            "contract #{contract_id} is not declared by authority #{authority_id}"
    end
  end

  defp validate_contract!(_, _),
    do: raise(ArgumentError, "contract entries must name one authority")

  defp require_names!(entries, required, kind) do
    missing = Enum.reject(required, &Map.has_key?(entries, &1))

    if missing != [],
      do: raise(ArgumentError, "missing required #{kind}: #{Enum.join(missing, ", ")}")
  end

  defp validate_required_bindings!(contracts) do
    Enum.each(@required_contracts, fn {contract_id, expected_authority} ->
      actual_authority = get_in(contracts, [contract_id, "authority"])

      unless actual_authority == expected_authority do
        raise ArgumentError,
              "contract #{contract_id} must bind authority #{expected_authority}, got #{inspect(actual_authority)}"
      end
    end)
  end

  defp require_string!(map, key, context) do
    case Map.fetch!(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "#{context} #{key} must be a non-empty string"
    end
  end

  defp require_hash!(value, pattern, context) do
    unless is_binary(value) and Regex.match?(pattern, value) do
      raise ArgumentError, "#{context} must be a lowercase SHA digest"
    end
  end
end
