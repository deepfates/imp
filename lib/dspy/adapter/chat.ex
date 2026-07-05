defmodule DSPy.Adapter.Chat do
  @moduledoc "Plain chat adapter: instructions plus field-labelled user content."

  @behaviour DSPy.Adapter

  @impl true
  def format(signature, inputs, opts) do
    demos = Keyword.get(opts, :demos, [])

    [
      %{role: :system, content: signature.instructions},
      %{role: :user, content: render_demos(demos) <> render_inputs(signature, inputs)}
    ]
  end

  @impl true
  def parse(_signature, %DSPy.Prediction{} = prediction, _opts), do: {:ok, prediction}
  def parse(signature, map, _opts) when is_map(map), do: build_prediction(signature, map)

  def parse(signature, text, _opts) when is_binary(text) do
    outputs = DSPy.Signature.output_names(signature)
    parsed = parse_labelled_text(text)

    fields =
      if parsed == %{} and length(outputs) == 1 do
        %{hd(outputs) => String.trim(text)}
      else
        Map.take(parsed, outputs)
      end

    build_prediction(signature, fields)
  end

  def parse(_signature, raw, _opts), do: {:error, {:unsupported_lm_output, raw}}

  defp build_prediction(signature, fields) do
    fields = Map.new(fields, fn {key, value} -> {normalize_key(key), value} end)

    required =
      signature.outputs
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(& &1.name)

    output_names = DSPy.Signature.output_names(signature)
    missing = Enum.reject(required, &Map.has_key?(fields, &1))

    if missing == [] do
      {:ok, DSPy.Prediction.new(coerce_fields(signature, Map.take(fields, output_names)))}
    else
      {:error, {:missing_output_fields, missing}}
    end
  end

  defp coerce_fields(signature, fields) do
    signature.outputs
    |> Enum.reduce(fields, fn field, acc ->
      if Map.has_key?(acc, field.name),
        do: Map.update!(acc, field.name, &coerce_value(&1, field.type)),
        else: acc
    end)
  end

  defp coerce_value(value, :integer) when is_binary(value),
    do: String.to_integer(String.trim(value))

  defp coerce_value(value, :float) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      {_float, _rest} -> value
      :error -> value
    end
  end

  defp coerce_value(value, :boolean) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["true", "yes", "1"]

  defp coerce_value(value, _type), do: value

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp render_inputs(signature, inputs) do
    signature.inputs
    |> Enum.map(fn field -> "#{field.prefix} #{format_value(Map.get(inputs, field.name))}" end)
    |> Enum.join("\n")
  end

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp format_value(value), do: inspect(value)

  defp render_demos([]), do: ""

  defp render_demos(demos) do
    demos
    |> Enum.map(fn demo ->
      demo
      |> DSPy.Example.to_map()
      |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\n")
    end)
    |> Enum.join("\n---\n")
    |> Kernel.<>("\n\n")
  end

  defp parse_labelled_text(text) do
    Regex.scan(~r/^([A-Za-z][A-Za-z0-9_ ]*):\s*(.*)$/m, text)
    |> Map.new(fn [_line, key, value] ->
      key =
        key |> String.trim() |> String.downcase() |> String.replace(" ", "_") |> String.to_atom()

      {key, String.trim(value)}
    end)
  end
end
