defmodule DSPy.Adapter.JSON do
  @moduledoc """
  JSON-oriented adapter.

  This dependency-free adapter accepts map outputs directly and parses a small
  flat JSON object subset for local tests and simple providers.
  """

  @behaviour DSPy.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages = DSPy.Adapter.Chat.format(signature, inputs, opts)
    schema = signature.outputs |> Enum.map(&Atom.to_string(&1.name)) |> Enum.join(", ")
    [%{role: :system, content: "Return a JSON object with keys: #{schema}"} | messages]
  end

  @impl true
  def parse(signature, raw, opts) when is_map(raw),
    do: DSPy.Adapter.Chat.parse(signature, raw, opts)

  def parse(signature, raw, opts) when is_binary(raw) do
    case flat_json_object(raw) do
      {:ok, map} -> DSPy.Adapter.Chat.parse(signature, map, opts)
      :error -> DSPy.Adapter.Chat.parse(signature, raw, opts)
    end
  end

  def parse(signature, raw, opts), do: DSPy.Adapter.Chat.parse(signature, raw, opts)

  defp flat_json_object(raw) do
    trimmed = String.trim(raw)

    if String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") do
      pairs =
        Regex.scan(~r/"([^"]+)"\s*:\s*"([^"]*)"/, trimmed)
        |> Map.new(fn [_all, key, value] -> {String.to_atom(key), value} end)

      if pairs == %{}, do: :error, else: {:ok, pairs}
    else
      :error
    end
  end
end
