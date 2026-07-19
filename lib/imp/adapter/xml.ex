defmodule Imp.Adapter.XML do
  @moduledoc "XML-ish adapter that parses `<field>value</field>` outputs."

  @behaviour Imp.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages = Imp.Adapter.Chat.format(signature, inputs, opts)
    tags = signature.outputs |> Enum.map(&"<#{&1.name}>...</#{&1.name}>") |> Enum.join(" ")
    [%{role: :system, content: "Return XML fields: #{tags}"} | messages]
  end

  @impl true
  def parse(signature, raw, opts) when is_binary(raw) do
    output_names = Imp.Signature.output_names(signature)

    fields =
      Enum.reduce(output_names, %{}, fn name, acc ->
        pattern = ~r/<#{name}>\s*(.*?)\s*<\/#{name}>/s

        case Regex.run(pattern, raw) do
          [_all, value] -> Map.put(acc, name, String.trim(value))
          nil -> acc
        end
      end)

    # DSPy XMLAdapter.parse (dspy/adapters/xml_adapter.py) raises
    # AdapterParseError unless every output field is present in tags:
    # `if fields.keys() != signature.output_fields.keys(): raise ...`.
    # Tag-free prose must be a loud parse error (feeding the retry path),
    # never silently stuffed into an output field via the Chat fallback.
    case Enum.reject(output_names, &Map.has_key?(fields, &1)) do
      [] -> Imp.Adapter.Chat.parse(signature, fields, opts)
      missing -> {:error, {:missing_output_fields, missing}}
    end
  end

  def parse(signature, raw, opts), do: Imp.Adapter.Chat.parse(signature, raw, opts)
end
