defmodule DSEx.UpstreamAuthorityRegistry do
  @moduledoc false

  @registry_path Path.expand("../../benchmarks/upstream_authority_registry.json", __DIR__)
  @required_authorities ~w(dspy_stable dspy_instruction_optimizers gepa_standalone req_llm)
  @required_contracts ~w(
    dspy_stable_upstream_fidelity
    req_llm_beam_runtime_dependency
    t1_gepa_v011_structural_differential_contract
    t1_instruction_optimizer_differential_contract
  )
  @hex40 ~r/\A[0-9a-f]{40}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc false
  def path, do: @registry_path

  @doc false
  def load!(path \\ @registry_path) do
    registry =
      path
      |> File.read!()
      |> Jason.decode!()

    validate!(registry, path)
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
      raise ArgumentError,
            "invalid upstream authority registry #{Path.expand(path)}: #{Exception.message(error)}"
  end

  @doc false
  def authority!(registry, contract_id) do
    contract = registry |> Map.fetch!("contracts") |> Map.fetch!(contract_id)
    authority_id = Map.fetch!(contract, "authority")
    registry |> Map.fetch!("authorities") |> Map.fetch!(authority_id)
  rescue
    KeyError ->
      raise ArgumentError, "upstream authority registry has no contract #{inspect(contract_id)}"
  end

  defp validate!(
         %{"schema_version" => 1, "authorities" => authorities, "contracts" => contracts} =
           registry,
         path
       )
       when is_map(authorities) and is_map(contracts) and map_size(authorities) > 0 and
              map_size(contracts) > 0 do
    require_names!(authorities, @required_authorities, "authorities")
    require_names!(contracts, @required_contracts, "contracts")
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
