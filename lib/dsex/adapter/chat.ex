defmodule DSEx.Adapter.Chat do
  @moduledoc "Plain chat adapter: instructions plus field-labelled user content."

  @behaviour DSEx.Adapter

  @format_option_schema [
    demos: [type: {:list, :any}, default: []],
    response_instruction: [type: :boolean, default: true]
  ]

  @impl true
  def format(signature, inputs, opts) do
    opts = validate_format_opts!(opts, "#{inspect(__MODULE__)}.format/3")
    demos = opts[:demos]
    response_instruction? = opts[:response_instruction]

    [%{role: :system, content: render_system(signature)}] ++
      render_demos(signature, demos) ++
      [
        %{
          role: :user,
          content:
            render_inputs(signature, inputs) <>
              render_response_instruction(signature, response_instruction?)
        }
      ]
  end

  @impl true
  def parse(signature, raw, opts) do
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")
    do_parse(signature, raw)
  end

  defp do_parse(_signature, %DSEx.Prediction{} = prediction), do: {:ok, prediction}
  defp do_parse(signature, map) when is_map(map), do: build_prediction(signature, map)

  defp do_parse(signature, text) when is_binary(text) do
    outputs = DSEx.Signature.output_names(signature)
    parsed = parse_labelled_text(signature, text)

    fields =
      if parsed == %{} and length(outputs) == 1 do
        %{hd(outputs) => String.trim(text)}
      else
        Map.take(parsed, outputs)
      end

    case build_prediction(signature, fields) do
      {:ok, prediction} ->
        {:ok, prediction}

      {:error, _reason} = error ->
        parse_json_fallback(signature, text, error)
    end
  end

  defp do_parse(_signature, raw), do: {:error, {:unsupported_lm_output, raw}}

  defp build_prediction(signature, fields) do
    required =
      signature.outputs
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(& &1.name)

    output_names = DSEx.Signature.output_names(signature)

    fields =
      Map.new(output_names, fn name ->
        {name, fetch_field(fields, name)}
      end)
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.new()

    missing = Enum.reject(required, &Map.has_key?(fields, &1))

    with true <- missing == [],
         fields <- coerce_fields(signature, Map.take(fields, output_names)),
         :ok <- DSEx.Schema.validate_fields(signature.outputs, fields) do
      {:ok, DSEx.Prediction.new(fields)}
    else
      false ->
        {:error, {:missing_output_fields, missing}}

      {:error, errors} ->
        {:error,
         %DSEx.AdapterParseError{
           message: DSEx.Schema.retry_feedback(errors),
           reason: fields
         }}
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

  defp coerce_value(value, :string) when not is_binary(value), do: to_string(value)

  defp coerce_value(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp coerce_value(value, :float) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      {_float, _rest} -> value
      :error -> value
    end
  end

  defp coerce_value(value, :number) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      {_float, _rest} -> value
      :error -> value
    end
  end

  defp coerce_value(value, :boolean) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      value when value in ["true", "yes", "1"] -> true
      value when value in ["false", "no", "0"] -> false
      _other -> value
    end
  end

  defp coerce_value(value, _type), do: value

  defp fetch_field(fields, name) do
    string_name = to_string(name)

    cond do
      Map.has_key?(fields, name) ->
        Map.fetch!(fields, name)

      Map.has_key?(fields, string_name) ->
        Map.fetch!(fields, string_name)

      (is_binary(name) and existing_atom(name)) && Map.has_key?(fields, existing_atom(name)) ->
        Map.fetch!(fields, existing_atom(name))

      true ->
        nil
    end
  end

  defp render_inputs(signature, inputs, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")

    signature.inputs
    |> Enum.reduce([], fn field, acc ->
      value = fetch_field(inputs, field.name)

      if is_nil(value) do
        acc
      else
        [
          """
          [[ ## #{field.name} ## ]]
          #{format_value(value)}
          """
          |> String.trim()
          | acc
        ]
      end
    end)
    |> Enum.reverse()
    |> then(fn sections ->
      case prefix do
        "" -> sections
        _prefix -> [prefix | sections]
      end
    end)
    |> Enum.join("\n\n")
  end

  defp render_outputs(signature, outputs, opts) do
    missing_field_message = Keyword.get(opts, :missing_field_message)

    signature.outputs
    |> Enum.map(fn field ->
      value = fetch_field(outputs, field.name) || missing_field_message

      """
      [[ ## #{field.name} ## ]]
      #{format_value(value)}
      """
      |> String.trim()
    end)
    |> Enum.join("\n\n")
  end

  defp render_system(signature) do
    """
    Your input fields are:
    #{render_field_list(signature.inputs)}
    Your output fields are:
    #{render_field_list(signature.outputs)}
    All interactions will be structured in the following way, with the appropriate values filled in.

    #{render_interaction_template(signature)}
    In adhering to this structure, your objective is: #{objective_text(signature.instructions)}
    """
    |> String.trim()
  end

  defp objective_text(instructions) do
    instructions
    |> to_string()
    |> String.split("\n")
    |> then(fn lines -> [""] ++ lines end)
    |> Enum.join("\n        ")
  end

  defp render_field_list(fields) do
    fields
    |> Enum.with_index(1)
    |> Enum.map(fn {field, index} ->
      desc = field_description(field)
      "#{index}. `#{field.name}` (#{field_type(field.type)}):#{desc}"
    end)
    |> Enum.join("\n")
  end

  defp field_description(field) do
    parts =
      [field.desc, answer_shape_instruction(field)]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    case parts do
      [] -> ""
      parts -> " " <> Enum.join(parts, " ")
    end
  end

  defp answer_shape_instruction(field) do
    constraints =
      field.metadata
      |> fetch_meta(:constraints, %{})
      |> normalize_constraints()

    case fetch_meta(constraints, :answer_shape) do
      nil ->
        nil

      :yes_no ->
        "Must be exactly yes or no."

      "yes_no" ->
        "Must be exactly yes or no."

      :numeric_span ->
        "Must be only the numeric answer span, with no words or explanation."

      "numeric_span" ->
        "Must be only the numeric answer span, with no words or explanation."

      :short_span ->
        "Must be a concise exact answer span; preserve complete names, titles, locations, dates, and quantities when the task asks for them, and do not add aliases, abbreviations, conversions, or parentheticals unless explicitly requested."

      "short_span" ->
        "Must be a concise exact answer span; preserve complete names, titles, locations, dates, and quantities when the task asks for them, and do not add aliases, abbreviations, conversions, or parentheticals unless explicitly requested."

      other ->
        "Must satisfy answer shape #{inspect(other)}."
    end
  end

  defp render_interaction_template(signature) do
    (signature.inputs ++ signature.outputs)
    |> Enum.map(fn field ->
      """
      [[ ## #{field.name} ## ]]
      {#{field.name}}
      """
      |> String.trim()
    end)
    |> Kernel.++(["[[ ## completed ## ]]"])
    |> Enum.join("\n\n")
  end

  defp field_type(:string), do: "str"
  defp field_type(:integer), do: "int"
  defp field_type(:float), do: "float"
  defp field_type(:number), do: "number"
  defp field_type(:boolean), do: "bool"
  defp field_type(type), do: to_string(type)

  defp fetch_meta(map, key, default \\ nil)

  defp fetch_meta(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_meta(map, key, default), do: Map.get(map, key, default)

  defp normalize_constraints(%{} = constraints) do
    Map.new(constraints, fn
      {"answerShape", value} -> {:answer_shape, value}
      {key, value} when is_binary(key) -> {existing_atom_or_key(key), value}
      pair -> pair
    end)
  end

  defp normalize_constraints(other), do: other

  defp existing_atom_or_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp render_response_instruction(_signature, false), do: ""

  defp render_response_instruction(signature, true) do
    outputs = Enum.map(signature.outputs, &"`[[ ## #{&1.name} ## ]]`")

    final =
      case outputs do
        [] -> "the output fields"
        [one] -> "the field #{one}"
        many -> "the fields " <> Enum.join(many, ", then ")
      end

    "\n\nRespond with the corresponding output fields, starting with #{final}, and then ending with the marker for `[[ ## completed ## ]]`."
  end

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp format_value(value), do: inspect(value)

  defp render_demos(_signature, []), do: []

  defp render_demos(signature, demos) do
    {complete, incomplete} =
      demos
      |> Enum.map(&DSEx.Example.to_map/1)
      |> Enum.reduce({[], []}, fn demo, {complete, incomplete} ->
        cond do
          complete_demo?(signature, demo) ->
            {[demo | complete], incomplete}

          usable_incomplete_demo?(signature, demo) ->
            {complete, [demo | incomplete]}

          true ->
            {complete, incomplete}
        end
      end)

    incomplete
    |> Enum.reverse()
    |> Enum.flat_map(&render_demo(signature, &1, :incomplete))
    |> Kernel.++(
      complete
      |> Enum.reverse()
      |> Enum.flat_map(&render_demo(signature, &1, :complete))
    )
  end

  defp complete_demo?(signature, demo) do
    (signature.inputs ++ signature.outputs)
    |> Enum.all?(fn field -> not is_nil(fetch_field(demo, field.name)) end)
  end

  defp usable_incomplete_demo?(signature, demo) do
    Enum.any?(signature.inputs, fn field -> not is_nil(fetch_field(demo, field.name)) end) and
      Enum.any?(signature.outputs, fn field -> not is_nil(fetch_field(demo, field.name)) end)
  end

  defp render_demo(signature, demo, :incomplete) do
    [
      %{
        role: :user,
        content:
          render_inputs(signature, demo,
            prefix:
              "This is an example of the task, though some input or output fields are not supplied."
          )
      },
      %{
        role: :assistant,
        content:
          render_outputs(signature, demo,
            missing_field_message: "Not supplied for this particular example. "
          )
      }
    ]
  end

  defp render_demo(signature, demo, :complete) do
    [
      %{role: :user, content: render_inputs(signature, demo)},
      %{
        role: :assistant,
        content:
          render_outputs(signature, demo,
            missing_field_message: "Not supplied for this conversation history message. "
          )
      }
    ]
  end

  defp parse_labelled_text(signature, text) do
    allowed =
      signature
      |> DSEx.Signature.output_names()
      |> Map.new(fn name -> {name |> to_string() |> String.downcase(), name} end)

    delimiter_fields =
      Regex.scan(
        ~r/\[\[\s*##\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:##)?\s*\]\]\s*(.*?)(?=\s*\[\[\s*##|\z)/s,
        text
      )
      |> Enum.reduce(%{}, fn [_line, key, value], acc ->
        key = key |> String.trim() |> String.downcase()

        case Map.fetch(allowed, key) do
          {:ok, field_name} -> Map.put(acc, field_name, String.trim(value))
          :error -> acc
        end
      end)

    labelled_fields =
      Regex.scan(~r/^([A-Za-z][A-Za-z0-9_ ]*):\s*(.*)$/m, text)
      |> Enum.reduce(%{}, fn [_line, key, value], acc ->
        key =
          key |> String.trim() |> String.downcase() |> String.replace(" ", "_")

        case Map.fetch(allowed, key) do
          {:ok, field_name} -> Map.put(acc, field_name, String.trim(value))
          :error -> acc
        end
      end)

    Map.merge(labelled_fields, delimiter_fields)
  end

  defp parse_json_fallback(signature, text, original_error) do
    with {:ok, decoded} <- Jason.decode(String.trim(text)),
         true <- is_map(decoded) do
      build_prediction(signature, decoded)
    else
      _other -> original_error
    end
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp validate_format_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.take(Keyword.keys(@format_option_schema))
      |> DSEx.Options.validate!(@format_option_schema, context)
    else
      raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_format_opts!(opts, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end

  defp validate_opts!(opts, _context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)}.parse/3 expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end
end
