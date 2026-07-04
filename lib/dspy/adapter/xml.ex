defmodule DSPy.Adapter.XML do
  @moduledoc "XML-ish adapter that parses `<field>value</field>` outputs."

  @behaviour DSPy.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages = DSPy.Adapter.Chat.format(signature, inputs, opts)
    tags = signature.outputs |> Enum.map(&"<#{&1.name}>...</#{&1.name}>") |> Enum.join(" ")
    [%{role: :system, content: "Return XML fields: #{tags}"} | messages]
  end

  @impl true
  def parse(signature, raw, opts) when is_binary(raw) do
    fields =
      signature
      |> DSPy.Signature.output_names()
      |> Enum.reduce(%{}, fn name, acc ->
        pattern = ~r/<#{name}>\s*(.*?)\s*<\/#{name}>/s

        case Regex.run(pattern, raw) do
          [_all, value] -> Map.put(acc, name, String.trim(value))
          nil -> acc
        end
      end)

    if fields == %{},
      do: DSPy.Adapter.Chat.parse(signature, raw, opts),
      else: {:ok, DSPy.Prediction.new(fields)}
  end

  def parse(signature, raw, opts), do: DSPy.Adapter.Chat.parse(signature, raw, opts)
end
