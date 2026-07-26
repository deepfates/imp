defmodule Imp.Adapter.SingleField do
  @moduledoc """
  Concise, strict adapter for programs with exactly one output field.

  `Imp.Adapter.Chat` deliberately mirrors DSPy's labelled `[[ ## field ## ]]`
  protocol. That is the right compatibility surface for general signatures,
  but it is needlessly difficult for small local policies performing ordinary
  classification or scalar generation. `SingleField` is an Imp-native adapter
  for that narrower job: it asks for only the output value and maps that value
  to the one declared field before applying the normal Imp schema validation.

  The parser is intentionally not a repair heuristic. It trims outer
  whitespace, but does not strip labels, brackets, quotes, code fences, or
  prose. An enum-constrained output therefore accepts an exact enum member and
  rejects `[member]` or `The answer is member`.

  Multi-output signatures are rejected before an LM call. Demonstrations must
  contain every input and the output so the adapter never silently drops
  partial training context.

  LMs that explicitly advertise `choice_values` support receive the declared
  enum members as a content-bound generation constraint. For Imp's local TRL
  runtime's deployed greedy mode, the real causal policy scores every declared
  token sequence and selects the most likely exact value. Sampled TRL training
  deliberately does not advertise this capability: choice-normalized sampling
  needs a different policy objective and must not masquerade as ordinary GRPO.

  When choice scoring is unavailable but the LM advertises exact response
  schemas, `SingleField` sends the same one-field schema as `Imp.Adapter.JSON`.
  The provider may then return a map, which this adapter validates through the
  ordinary typed parser. This is transport constraint, not text repair: an LM
  with neither capability still receives only the concise prompt and remains
  subject to the exact-value parser.
  """

  @behaviour Imp.Adapter

  @option_schema [
    demos: [
      type: {:custom, __MODULE__, :validate_demos, []},
      default: []
    ]
  ]

  @impl true
  def format(signature, inputs, opts) do
    output = single_output!(signature, "format/3")
    opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.format/3")
    demos = validate_complete_demos!(signature, opts[:demos])

    [
      %{role: :system, content: render_system(signature, output)}
      | Enum.flat_map(demos, &render_demo(signature, output, &1)) ++
          [%{role: :user, content: render_inputs(signature, inputs)}]
    ]
  end

  @impl true
  def parse(signature, raw, opts) when is_list(opts) do
    output = single_output!(signature, "parse/3")

    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.parse/3 expects keyword options, got: #{inspect(opts)}"
    end

    case raw do
      %Imp.Prediction{} ->
        Imp.Adapter.Chat.parse(signature, raw, opts)

      map when is_map(map) ->
        Imp.Adapter.Chat.parse(signature, map, opts)

      text when is_binary(text) ->
        case String.trim(text) do
          "" -> {:error, {:missing_output_fields, [output.name]}}
          value -> parse_text_value(signature, output, value, opts)
        end

      other ->
        {:error, {:unsupported_lm_output, other}}
    end
  end

  def parse(_signature, _raw, opts) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.parse/3 expects keyword options, got: #{inspect(opts)}"
  end

  @doc false
  def lm_opts(signature, _opts, %Imp.LM.Capability{choice_values: true}) do
    output = single_output!(signature, "lm_opts/3")

    case enum_values(output) do
      values when is_list(values) and values != [] -> [allowed_values: values]
      _unconstrained -> []
    end
  end

  def lm_opts(signature, opts, %Imp.LM.Capability{response_schema: true} = capability) do
    Imp.Adapter.JSON.lm_opts(signature, opts, capability)
  end

  def lm_opts(_signature, _opts, %Imp.LM.Capability{}), do: []

  @doc false
  def validate_demos(demos) do
    {:ok, Imp.Example.normalize_demos!(demos, "#{inspect(__MODULE__)}.format/3")}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp single_output!(%Imp.Signature{outputs: [output]}, _operation), do: output

  defp single_output!(%Imp.Signature{outputs: outputs}, operation) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.#{operation} requires exactly one output field, got: " <>
            inspect(Enum.map(outputs, & &1.name))
  end

  defp render_system(signature, output) do
    input_lines =
      signature.inputs
      |> Enum.map_join("\n", fn field ->
        "- #{field.name} (#{Imp.Adapter.CompositeType.annotation_name(field)})#{description(field)}"
      end)

    """
    You are solving a task with exactly one output value.
    Objective: #{String.trim(to_string(signature.instructions || ""))}
    Input fields:
    #{input_lines}
    Output value: #{output.name} (#{Imp.Adapter.CompositeType.annotation_name(output)})#{description(output)}
    Return only the value for #{output.name}. Do not include a field label, quotes, brackets, a code fence, or an explanation.
    """
    |> String.trim()
  end

  defp description(%{desc: desc}) when desc in [nil, ""], do: ""
  defp description(%{desc: desc}), do: ": #{desc}"

  defp render_demo(signature, output, demo) do
    [
      %{role: :user, content: render_inputs(signature, demo)},
      %{role: :assistant, content: demo |> fetch!(output.name) |> Imp.Adapter.Chat.format_value()}
    ]
  end

  defp render_inputs(signature, inputs) do
    Enum.map_join(signature.inputs, "\n", fn field ->
      "#{field.name}: #{inputs |> fetch!(field.name) |> Imp.Adapter.Chat.format_value()}"
    end)
  end

  defp validate_complete_demos!(signature, demos) do
    required = Enum.map(signature.inputs ++ signature.outputs, & &1.name)

    Enum.map(demos, fn demo ->
      missing = Enum.reject(required, &present?(demo, &1))

      if missing == [] do
        demo
      else
        raise ArgumentError,
              "#{inspect(__MODULE__)} demonstrations must be complete; missing fields: " <>
                inspect(missing)
      end
    end)
  end

  # ChatAdapter's faithful Literal coercion intentionally accepts quoted and
  # `Literal[...]`-wrapped values. This adapter's contract is stricter: an enum
  # completion is the exact wire value. Keep Chat as the shared type/schema
  # validator only after this adapter-specific boundary is satisfied.
  defp parse_text_value(signature, output, value, opts) do
    case enum_values(output) do
      values when is_list(values) ->
        if value in values do
          Imp.Adapter.Chat.parse(signature, %{output.name => value}, opts)
        else
          Imp.Adapter.Chat.parse(signature, %{output.name => value}, opts)
          |> reject_coerced_enum(value)
        end

      _unconstrained ->
        Imp.Adapter.Chat.parse(signature, %{output.name => value}, opts)
    end
  end

  defp reject_coerced_enum({:ok, _prediction}, value),
    do: {:error, %Imp.AdapterParseError{message: "expected an exact enum value", reason: value}}

  defp reject_coerced_enum(error, _value), do: error

  defp enum_values(output) do
    output.metadata
    |> Map.get(:constraints, Map.get(output.metadata, "constraints", %{}))
    |> case do
      constraints when is_map(constraints) ->
        Map.get(constraints, :enum, Map.get(constraints, "enum"))

      _other ->
        nil
    end
  end

  defp fetch!(%Imp.Example{} = example, name), do: Imp.Example.fetch!(example, name)

  defp fetch!(map, name) when is_map(map) do
    case fetch(map, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required adapter field #{inspect(name)}"
    end
  end

  defp present?(%Imp.Example{} = example, name),
    do:
      Map.has_key?(Imp.Example.to_map(example), name) or
        Map.has_key?(Imp.Example.to_map(example), to_string(name))

  defp present?(map, name), do: match?({:ok, _value}, fetch(map, name))

  defp fetch(map, name) do
    case Map.fetch(map, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(map, to_string(name))
    end
  end
end
