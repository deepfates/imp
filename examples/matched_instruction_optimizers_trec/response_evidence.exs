defmodule MatchedInstructionOptimizersTREC.ResponseEvidence do
  @moduledoc false

  def from_result!({:ok, value}) do
    with {:ok, output, metadata} <- Imp.LM.Result.split(value),
         req_llm when is_map(req_llm) <- map_get(metadata, :req_llm) do
      usage = map_get(req_llm, :usage) || %{}
      provider_meta = map_get(req_llm, :provider_meta) || %{}

      %{
        output: output,
        metadata: metadata,
        model: map_get(req_llm, :model),
        route: map_get(provider_meta, :provider),
        gateway: map_get(req_llm, :provider),
        service_tier: map_get(provider_meta, :service_tier) || map_get(req_llm, :service_tier),
        input_tokens: map_get(usage, :input_tokens) || map_get(usage, :prompt_tokens),
        output_tokens: map_get(usage, :output_tokens) || map_get(usage, :completion_tokens),
        finish_reason: normalize_finish_reason(map_get(req_llm, :finish_reason)),
        content: map_get(req_llm, :content),
        gateway_reported_cost: scalar_cost(usage, "cost", :cost),
        computed_cost: scalar_cost(usage, "total_cost", :total_cost),
        provider_cost: scalar_cost(usage, "cost", :cost)
      }
    else
      {:error, reason} -> raise "invalid LM result envelope: #{inspect(reason)}"
      _missing -> raise "successful LM result has no ReqLLM response metadata"
    end
  end

  def from_result!({:error, reason}),
    do: raise("LM transport failed before a response was available: #{inspect(reason)}")

  def from_result!(other), do: raise("invalid observed LM result: #{inspect(other)}")

  defp normalize_finish_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_finish_reason(value), do: value

  # ReqLLM retains the gateway's scalar cost under the original string key and
  # may also expose a structured adapter breakdown under the atom key. Prefer
  # the gateway scalar, but accept either representation when it is numeric.
  defp scalar_cost(usage, string_key, atom_key) when is_map(usage) do
    case Map.get(usage, string_key) do
      value when is_number(value) ->
        value

      _other ->
        case Map.get(usage, atom_key) do
          value when is_number(value) -> value
          _other -> nil
        end
    end
  end

  defp scalar_cost(_usage, _string_key, _atom_key), do: nil

  defp map_get(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, found} -> found
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp map_get(_value, _key), do: nil
end
