defmodule Imp.Persistence.Legacy do
  @moduledoc false

  alias Imp.Optimizer.GEPA.EvaluationCache.Codec

  @legacy_tag "__dsex_type__"
  @current_tag "__imp_type__"

  @wire_values %{
    "dsex_program_artifact" => "imp_program_artifact",
    "dsex_optimizer_artifact" => "imp_optimizer_artifact",
    "dsex_optimizer_trajectory" => "imp_optimizer_trajectory",
    "dsex_mipro_v2_run" => "imp_mipro_v2_run",
    "dsex_simba_run" => "imp_simba_run",
    "dsex_fast_slow_training" => "imp_fast_slow_training",
    "dsex_training_job" => "imp_training_job",
    "dsex_training_job_checkpoint" => "imp_training_job_checkpoint",
    "dsex_optimize_anything_config" => "imp_optimize_anything_config"
  }

  @gepa_environment_values %{
    "DSEX_GEPA_PYTHON" => "IMP_GEPA_PYTHON",
    "DSEX_GEPA_ROOT" => "IMP_GEPA_ROOT"
  }

  def legacy_value?(value), do: is_binary(value) and Map.has_key?(@wire_values, value)

  def normalize(value) when is_map(value) do
    value
    |> normalize_tag_key!()
    |> Map.new(fn {key, nested} -> {key, normalize(nested)} end)
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_binary(value), do: Map.get(@wire_values, value, value)
  def normalize(value), do: value

  def optimizer_artifact!(%{"artifact_type" => "dsex_optimizer_artifact"} = artifact) do
    exact_keys!(artifact, ~w(artifact_type schema_version payload_sha256 payload))
    payload = Map.fetch!(artifact, "payload")
    verify_checksum!(payload, artifact["payload_sha256"], "legacy optimizer artifact")

    normalized_payload =
      payload
      |> normalize()
      |> Map.update!("candidates", fn candidates ->
        Map.new(candidates, fn {id, candidate} ->
          program = Map.fetch!(candidate, "program")
          {id, Map.put(candidate, "program_sha256", Codec.checksum(program))}
        end)
      end)

    %{
      artifact
      | "artifact_type" => "imp_optimizer_artifact",
        "payload" => normalized_payload,
        "payload_sha256" => Codec.checksum(normalized_payload)
    }
  end

  def optimizer_artifact!(artifact), do: artifact

  def rlm_manifest(manifest) when is_map(manifest) do
    manifest
    |> update_in(["models"], fn models ->
      Map.new(models, fn {role, settings} -> {role, rename_key!(settings, "dsex", "imp")} end)
    end)
    |> update_in(["approaches"], fn approaches ->
      Map.new(approaches, fn {id, approach} ->
        runtimes = Enum.map(approach["runtimes"], &if(&1 == "dsex", do: "imp", else: &1))
        {id, Map.put(approach, "runtimes", runtimes)}
      end)
    end)
  end

  def instruction_manifest(manifest) when is_map(manifest) do
    manifest
    |> maybe_rename_nested_key("model", "dsex", "imp")
    |> maybe_rename_nested_key("runtime_models", "dsex", "imp")
    |> maybe_rename_nested_key("source_commits", "dsex", "imp")
  end

  def gepa_manifest(manifest) when is_map(manifest) do
    manifest
    |> Map.update("campaign_id", nil, &replace_prefix(&1, "dsex-", "imp-"))
    |> Map.update("environment", nil, fn environment ->
      Map.new(environment, fn {key, value} ->
        {key, Map.get(@gepa_environment_values, value, value)}
      end)
    end)
  end

  def rlm_contract_fixture(fixture) when is_map(fixture) do
    Map.update(fixture, "cases", [], fn cases ->
      Enum.map(cases, fn contract ->
        Map.update(contract, "id", nil, &replace_prefix(&1, "dsex_", "imp_"))
      end)
    end)
  end

  def rlm_contract_result(result) when is_map(result) do
    Map.update(result, "rows", [], fn rows ->
      Enum.map(rows, fn row ->
        Map.update(row, "id", nil, &replace_prefix(&1, "dsex_", "imp_"))
      end)
    end)
  end

  def verify_checksum!(payload, checksum, context) do
    unless is_binary(checksum) and :crypto.hash_equals(checksum, Codec.checksum(payload)) do
      raise ArgumentError, "#{context} payload checksum mismatch"
    end

    :ok
  end

  defp normalize_tag_key!(%{@legacy_tag => _legacy, @current_tag => _current}) do
    raise ArgumentError, "legacy payload contains both #{@legacy_tag} and #{@current_tag}"
  end

  defp normalize_tag_key!(%{@legacy_tag => value} = map) do
    map
    |> Map.delete(@legacy_tag)
    |> Map.put(@current_tag, value)
  end

  defp normalize_tag_key!(map), do: map

  defp maybe_rename_nested_key(map, parent, from, to) do
    case map[parent] do
      nested when is_map(nested) -> Map.put(map, parent, rename_key!(nested, from, to))
      _ -> map
    end
  end

  defp rename_key!(map, from, to) do
    case {Map.has_key?(map, from), Map.has_key?(map, to)} do
      {true, true} -> raise ArgumentError, "legacy payload contains both #{from} and #{to} keys"
      {true, false} -> map |> Map.put(to, map[from]) |> Map.delete(from)
      _ -> map
    end
  end

  defp replace_prefix(value, from, to) when is_binary(value) do
    if String.starts_with?(value, from),
      do: to <> String.replace_prefix(value, from, ""),
      else: value
  end

  defp replace_prefix(value, _from, _to), do: value

  defp exact_keys!(map, expected) do
    unless MapSet.new(Map.keys(map)) == MapSet.new(expected) do
      raise ArgumentError, "legacy optimizer artifact envelope keys do not match"
    end
  end
end
