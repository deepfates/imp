defmodule DSEx.Adapter.XML do
  @moduledoc "XML-ish adapter that parses `<field>value</field>` outputs."

  @behaviour DSEx.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages = DSEx.Adapter.Chat.format(signature, inputs, opts)
    tags = signature.outputs |> Enum.map(&"<#{&1.name}>...</#{&1.name}>") |> Enum.join(" ")
    [%{role: :system, content: "Return XML fields: #{tags}"} | messages]
  end

  @impl true
  def parse(signature, raw, opts) when is_binary(raw) do
    fields =
      signature
      |> DSEx.Signature.output_names()
      |> Enum.reduce(%{}, fn name, acc ->
        pattern = ~r/<#{name}>\s*(.*?)\s*<\/#{name}>/s

        case Regex.run(pattern, raw) do
          [_all, value] -> Map.put(acc, name, String.trim(value))
          nil -> acc
        end
      end)

    if fields == %{},
      do: DSEx.Adapter.Chat.parse(signature, raw, opts),
      else: DSEx.Adapter.Chat.parse(signature, fields, opts)
  end

  def parse(signature, raw, opts), do: DSEx.Adapter.Chat.parse(signature, raw, opts)
end
