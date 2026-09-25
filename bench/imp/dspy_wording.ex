defmodule Imp.DSPyWording do
  @moduledoc """
  DSPy's prompts carry Python spellings where Imp's use neutral ones
  (`decisions.md`: DSPy parity means behaviour and information, not text):
  type annotations (`Imp.Adapter.FieldType`), `None`/`True`/`False` as field
  values, a `repr(Example)` dataset summary, a Python dict of tool arguments,
  and a structured-output schema named after DSPy's pydantic class. This
  puts those into Imp's words and leaves every other byte alone, so fields,
  order, constraints and instructions are still compared exactly. A spelling
  this does not recognise is left as DSPy wrote it, and the comparison fails.

  Used by the DSPy differentials that compare rendered prompts: the golden
  trace (`mix imp.benchmark.trace`) and the MIPROv2 proposer differential.
  """

  @doc "Puts DSPy's type annotations in `value` (text, or lists and maps of it) into Imp's words."
  def in_imp_words(value) when is_binary(value) do
    value
    |> regex_replace(~r/(\d+\. `[^`\n]+` )\((.+?)\):/, fn _all, lead, annotation ->
      lead <> "(" <> Imp.Adapter.FieldType.label(dspy_field(annotation)) <> "):"
    end)
    |> regex_replace(
      ~r/ \(must be formatted as a valid Python (.+?)\)(?=, then |, and then |\.)/,
      fn _all, annotation ->
        Imp.Adapter.Chat.output_type_info(dspy_field(annotation))
      end
    )
    |> String.replace("must be a single int value", Imp.Adapter.FieldType.note(dspy_field("int")))
    |> String.replace(
      "must be a single float value",
      Imp.Adapter.FieldType.note(dspy_field("float"))
    )
    |> String.replace("must be True or False", Imp.Adapter.FieldType.note(dspy_field("bool")))
    |> regex_replace(~r/Type description of Code_\w+: /, fn _all -> "Type description: " end)
    |> regex_replace(~r/It takes arguments (\{.*\})\.$/m, fn all, arguments ->
      case python_literal(arguments) do
        {:ok, decoded} -> "It takes arguments #{Imp.Adapter.Chat.format_value(plain(decoded))}."
        :error -> all
      end
    end)
    |> regex_replace(~r/^(True|False|None)$/m, fn _all, value -> json_scalar(value) end)
    |> regex_replace(~r/^([^\n:]+: )(True|False|None)$/m, fn _all, lead, value ->
      lead <> json_scalar(value)
    end)
    |> regex_replace(~r/Example\((\{.*?\})\) \(input_keys=\{(.*?)\}\)/, fn all, fields, inputs ->
      with {:ok, %Jason.OrderedObject{values: fields}} <- python_literal(fields) do
        input_names = Regex.scan(~r/'([^']*)'|"([^"]*)"/, inputs) |> Enum.map(&Enum.at(&1, -1))
        example_text(fields, input_names)
      else
        _other -> all
      end
    end)
  end

  def in_imp_words(value) when is_list(value), do: Enum.map(value, &in_imp_words/1)

  def in_imp_words(value) when is_map(value) do
    Map.new(value, fn
      {"name", "DSPyProgramOutputs"} -> {"name", "outputs"}
      {"title", "DSPyProgramOutputs"} -> {"title", "Outputs"}
      {k, v} -> {k, in_imp_words(v)}
    end)
  end

  def in_imp_words(value), do: value

  # One DSPy example as Imp's dataset summary shows it: `{"inputs": {...},
  # "outputs": {...}}`, each group's fields in lexical order, nested dicts in
  # DSPy's order. Encoded here rather than through Imp's renderer, so the
  # proposer differential compares two independent renderings.
  defp example_text(fields, input_names) do
    {inputs, outputs} =
      fields
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.split_with(fn {name, _value} -> name in input_names end)

    json(%Jason.OrderedObject{
      values: [
        {"inputs", %Jason.OrderedObject{values: inputs}},
        {"outputs", %Jason.OrderedObject{values: outputs}}
      ]
    })
  end

  # JSON with `", "` and `": "` separators; numbers keep Python's spelling,
  # which is valid JSON for the finite numbers a repr carries.
  defp json(%Jason.OrderedObject{values: values}),
    do:
      "{" <>
        Enum.map_join(values, ", ", fn {k, v} -> Jason.encode!(k) <> ": " <> json(v) end) <> "}"

  defp json(values) when is_list(values), do: "[" <> Enum.map_join(values, ", ", &json/1) <> "]"
  defp json({:number, text}), do: text
  defp json(value), do: Jason.encode!(value)

  defp regex_replace(value, regex, fun), do: Regex.replace(regex, value, fun)

  # A Python literal (`repr` of dicts, lists, strings, numbers, True, False,
  # None) as JSON-shaped terms, dicts as `Jason.OrderedObject` so their
  # insertion order survives.
  defp python_literal(text) do
    case literal(String.trim(text)) do
      {:ok, value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  defp literal("{" <> rest), do: pairs(skip(rest), [])
  defp literal("[" <> rest), do: items(skip(rest), [])
  defp literal("'" <> rest), do: string(rest, ?', [])
  defp literal("\"" <> rest), do: string(rest, ?", [])
  defp literal("True" <> rest), do: {:ok, true, rest}
  defp literal("False" <> rest), do: {:ok, false, rest}
  defp literal("None" <> rest), do: {:ok, nil, rest}

  defp literal(text) do
    case Regex.run(~r/\A-?[0-9][0-9.eE+-]*/, text) do
      [number] ->
        rest = binary_part(text, byte_size(number), byte_size(text) - byte_size(number))

        {:ok, {:number, number}, rest}

      nil ->
        :error
    end
  end

  defp pairs("}" <> rest, acc), do: {:ok, %Jason.OrderedObject{values: Enum.reverse(acc)}, rest}

  defp pairs(text, acc) do
    with {:ok, key, rest} <- literal(text),
         ":" <> rest <- skip(rest),
         {:ok, value, rest} <- literal(skip(rest)) do
      case skip(rest) do
        "," <> rest -> pairs(skip(rest), [{key, value} | acc])
        rest -> pairs(rest, [{key, value} | acc])
      end
    else
      _other -> :error
    end
  end

  defp items("]" <> rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp items(text, acc) do
    with {:ok, value, rest} <- literal(text) do
      case skip(rest) do
        "," <> rest -> items(skip(rest), [value | acc])
        rest -> items(rest, [value | acc])
      end
    end
  end

  defp string(<<quote, rest::binary>>, quote, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string("\\x" <> <<hex::binary-size(2), rest::binary>>, quote, acc),
    do: string(rest, quote, [<<String.to_integer(hex, 16)::utf8>> | acc])

  defp string("\\u" <> <<hex::binary-size(4), rest::binary>>, quote, acc),
    do: string(rest, quote, [<<String.to_integer(hex, 16)::utf8>> | acc])

  defp string("\\U" <> <<hex::binary-size(8), rest::binary>>, quote, acc),
    do: string(rest, quote, [<<String.to_integer(hex, 16)::utf8>> | acc])

  defp string("\\n" <> rest, quote, acc), do: string(rest, quote, ["\n" | acc])
  defp string("\\t" <> rest, quote, acc), do: string(rest, quote, ["\t" | acc])
  defp string("\\r" <> rest, quote, acc), do: string(rest, quote, ["\r" | acc])
  defp string(<<?\\, char, rest::binary>>, quote, acc), do: string(rest, quote, [char | acc])

  defp string(<<char::utf8, rest::binary>>, quote, acc),
    do: string(rest, quote, [<<char::utf8>> | acc])

  defp string("", _quote, _acc), do: :error

  defp skip(text), do: String.trim_leading(text)

  # Imp renders tool arguments from a map, so DSPy's dict order does not carry.
  defp plain(%Jason.OrderedObject{values: values}),
    do: Map.new(values, fn {k, v} -> {k, plain(v)} end)

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)

  defp plain({:number, text}) do
    case Integer.parse(text) do
      {integer, ""} -> integer
      _other -> text |> Float.parse() |> elem(0)
    end
  end

  defp plain(value), do: value

  defp json_scalar("True"), do: "true"
  defp json_scalar("False"), do: "false"
  defp json_scalar("None"), do: "null"

  # An output field of the type a DSPy annotation names.
  defp dspy_field(annotation) do
    {type, constraints, language} = dspy_type(String.trim(annotation))

    %Imp.Signature.Field{
      name: :field,
      kind: :output,
      type: type,
      metadata: %{constraints: constraints, language: language}
    }
  end

  defp dspy_type("str"), do: {:string, %{}, nil}
  defp dspy_type("int"), do: {:integer, %{}, nil}
  defp dspy_type("float"), do: {:float, %{}, nil}
  defp dspy_type("bool"), do: {:boolean, %{}, nil}
  defp dspy_type("datetime"), do: {:datetime, %{}, nil}
  defp dspy_type("dict[str, Any]"), do: {:object, %{}, nil}
  defp dspy_type("list"), do: {:array, %{}, nil}
  defp dspy_type("Code_" <> language), do: {:code, %{}, language}

  defp dspy_type("list[" <> rest) do
    {type, constraints, _language} = rest |> String.slice(0..-2//1) |> dspy_type()
    {:array, %{items: Map.put(constraints, :type, type)}, nil}
  end

  defp dspy_type("Literal[" <> rest) do
    case Imp.Adapter.JSONRepair.decode("[" <> rest) do
      {:ok, members} when is_list(members) -> {:string, %{enum: members}, nil}
      :error -> {"Literal[" <> rest, %{}, nil}
    end
  end

  defp dspy_type(other), do: {other, %{}, nil}
end
