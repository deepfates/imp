defmodule Imp.DSPyWording do
  @moduledoc """
  DSPy prints Python type annotations where Imp names types in words
  (`Imp.Adapter.FieldType`; `decisions.md`: DSPy parity means behaviour and
  information, not text). This puts DSPy's annotations into Imp's words and
  leaves every other byte alone, so fields, order, constraints and
  instructions are still compared exactly. An annotation this does not
  recognise is left as DSPy wrote it, and the comparison fails.

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
      case Imp.Adapter.JSONRepair.decode(arguments) do
        {:ok, decoded} -> "It takes arguments #{Imp.Adapter.Chat.format_value(decoded)}."
        :error -> all
      end
    end)
  end

  def in_imp_words(value) when is_list(value), do: Enum.map(value, &in_imp_words/1)

  def in_imp_words(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, in_imp_words(v)} end)

  def in_imp_words(value), do: value

  defp regex_replace(value, regex, fun), do: Regex.replace(regex, value, fun)

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
