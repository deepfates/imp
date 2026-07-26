defmodule MatchedInstructionOptimizersTREC.ResponseEvidence do
  @moduledoc false

  def from_result!({:ok, value}) do
    with {:ok, output, metadata} <- Imp.LM.Result.split(value),
         req_llm when is_map(req_llm) <- map_get(metadata, :req_llm) do
      usage = map_get(req_llm, :usage) || %{}

      %{
        output: output,
        metadata: metadata,
        model: map_get(req_llm, :model),
        route: map_get(req_llm, :provider),
        input_tokens: map_get(usage, :input_tokens) || map_get(usage, :prompt_tokens),
        output_tokens: map_get(usage, :output_tokens) || map_get(usage, :completion_tokens),
        finish_reason: normalize_finish_reason(map_get(req_llm, :finish_reason)),
        content: map_get(req_llm, :content),
        provider_cost: map_get(usage, :total_cost) || map_get(usage, :cost)
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

  defp map_get(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, found} -> found
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp map_get(_value, _key), do: nil
end
