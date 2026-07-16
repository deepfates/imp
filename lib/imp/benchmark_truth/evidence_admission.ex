defmodule Imp.BenchmarkTruth.EvidenceAdmission do
  @moduledoc false

  alias Imp.ReproductionRegistry

  def admit!(opts) when is_list(opts) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    registry_path =
      expand(Keyword.get(opts, :registry_path, "benchmarks/reproductions.json"), root)

    authority_path =
      expand(Keyword.get(opts, :authority_path, "benchmarks/authorities.json"), root)

    artifact_path = expand(Keyword.fetch!(opts, :artifact_path), root)
    protocol_id = Keyword.fetch!(opts, :protocol_id)
    tier = Keyword.fetch!(opts, :tier)
    feature_ids = Keyword.fetch!(opts, :feature_ids)

    registry_bytes = File.read!(registry_path)
    registry = Jason.decode!(registry_bytes)
    ordered_registry = Jason.decode!(registry_bytes, objects: :ordered_objects)
    authorities = Imp.EvidenceAuthorities.load!(authority_path)
    ReproductionRegistry.validate!(registry, authorities, root)

    protocol = validate_admission!(registry, protocol_id, tier, feature_ids)
    artifact_bytes = File.read!(artifact_path)
    artifact = Jason.decode!(artifact_bytes)
    ReproductionRegistry.validate_protocol_artifact!(registry, protocol_id, artifact)

    sha256 = sha256(artifact_bytes)
    relative_path = ReproductionRegistry.admitted_path(protocol_id, sha256)
    destination = Path.join(root, relative_path)
    record = admission_record(tier, relative_path, sha256, protocol_id)
    updated_ordered = update_features!(ordered_registry, feature_ids, record)
    updated_bytes = Jason.encode!(updated_ordered, pretty: true) <> "\n"
    updated_registry = Jason.decode!(updated_bytes)

    created? = ensure_artifact!(destination, artifact_bytes)

    try do
      ReproductionRegistry.validate!(updated_registry, authorities, root)
      atomic_write!(registry_path, updated_bytes)
    rescue
      error ->
        if created?, do: File.rm(destination)
        reraise error, __STACKTRACE__
    end

    %{
      artifact: relative_path,
      artifact_sha256: sha256,
      features: feature_ids,
      max_tier: protocol["max_tier"],
      protocol_id: protocol_id,
      tier: tier
    }
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
      reraise ArgumentError,
              [message: "evidence admission failed: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp validate_admission!(
         %{"protocols" => protocols, "features" => features},
         protocol_id,
         tier,
         feature_ids
       ) do
    protocol =
      Map.get(protocols, protocol_id) ||
        raise(ArgumentError, "unknown evidence protocol #{inspect(protocol_id)}")

    unless tier in ~w(t0 t1 t2 t3),
      do: raise(ArgumentError, "admission tier must be one of t0, t1, t2, or t3")

    if tier_rank(tier) > tier_rank(protocol["max_tier"]),
      do:
        raise(
          ArgumentError,
          "admission tier #{tier} exceeds protocol maximum #{protocol["max_tier"]}"
        )

    unless is_list(feature_ids) and feature_ids != [] and feature_ids == Enum.uniq(feature_ids),
      do: raise(ArgumentError, "admission must name one or more unique feature ids")

    by_id = Map.new(features, &{&1["id"], &1})

    Enum.each(feature_ids, fn feature_id ->
      feature =
        Map.get(by_id, feature_id) ||
          raise(ArgumentError, "unknown evidence feature #{inspect(feature_id)}")

      unless protocol_id in feature["protocol_ids"] do
        raise ArgumentError,
              "feature #{feature_id} does not declare protocol #{protocol_id}"
      end

      existing_tier = get_in(feature, ["admitted_evidence", "tier"])

      if tier_rank(existing_tier) > tier_rank(tier) do
        raise ArgumentError,
              "admission would downgrade feature #{feature_id} from #{existing_tier} to #{tier}"
      end
    end)

    unless is_map(protocol["artifact_validator"]),
      do: raise(ArgumentError, "protocol #{protocol_id} has no pure artifact validator")

    protocol
  end

  defp update_features!(ordered_registry, feature_ids, record) do
    selected = MapSet.new(feature_ids)
    features = ordered_registry["features"]

    {updated, found} =
      Enum.map_reduce(features, MapSet.new(), fn feature, found ->
        feature_id = feature["id"]

        if MapSet.member?(selected, feature_id) do
          {put_in(feature["admitted_evidence"], record), MapSet.put(found, feature_id)}
        else
          {feature, found}
        end
      end)

    unless found == selected,
      do: raise(ArgumentError, "ordered registry is missing requested features")

    put_in(ordered_registry["features"], updated)
  end

  defp admission_record(tier, artifact, sha256, protocol_id) do
    Jason.OrderedObject.new([
      {"tier", tier},
      {"artifact", artifact},
      {"artifact_sha256", sha256},
      {"protocol_id", protocol_id}
    ])
  end

  defp ensure_artifact!(destination, bytes) do
    File.mkdir_p!(Path.dirname(destination))

    case File.read(destination) do
      {:ok, ^bytes} ->
        false

      {:ok, _other} ->
        raise ArgumentError, "content-addressed artifact collision at #{destination}"

      {:error, :enoent} ->
        atomic_write!(destination, bytes)
        true

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: destination
    end
  end

  defp atomic_write!(path, bytes) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, bytes, [:binary, :sync, :exclusive])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp expand(path, root) when is_binary(path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(root, path)
  end

  defp tier_rank(tier), do: Enum.find_index(~w(none t0 t1 t2 t3), &(&1 == tier)) || -1

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
