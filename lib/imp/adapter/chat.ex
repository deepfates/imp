defmodule Imp.Adapter.Chat do
  @moduledoc "Plain chat adapter: instructions plus field-labelled user content."

  @behaviour Imp.Adapter

  @format_option_schema [
    demos: [
      type: {:custom, __MODULE__, :validate_demos, []},
      default: []
    ],
    response_instruction: [type: :boolean, default: true]
  ]

  @impl true
  def format(signature, inputs, opts) do
    opts = validate_format_opts!(opts, "#{inspect(__MODULE__)}.format/3")
    demos = opts[:demos]
    response_instruction? = opts[:response_instruction]
    {history_messages, history_fields} = extract_history(signature, inputs)

    [%{role: :system, content: render_system(signature)}] ++
      render_demos(signature, demos) ++
      history_messages ++
      [
        %{
          role: :user,
          content:
            append_content(
              render_inputs(signature, inputs, skip: history_fields),
              render_response_instruction(signature, response_instruction?)
            )
        }
      ]
  end

  @impl true
  def parse(signature, raw, opts) do
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")
    do_parse(signature, raw)
  end

  defp do_parse(_signature, %Imp.Prediction{} = prediction), do: {:ok, prediction}
  defp do_parse(signature, map) when is_map(map), do: build_prediction(signature, map)

  defp do_parse(signature, text) when is_binary(text) do
    outputs = Imp.Signature.output_names(signature)
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

  @doc false
  def validate_demos(demos) do
    {:ok, Imp.Example.normalize_demos!(demos, "#{inspect(__MODULE__)}.format/3")}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp build_prediction(signature, fields) do
    required =
      signature.outputs
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(& &1.name)

    output_names = Imp.Signature.output_names(signature)

    fields =
      Map.new(output_names, fn name ->
        {name, fetch_field(fields, name)}
      end)
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.new()

    missing = Enum.reject(required, &Map.has_key?(fields, &1))

    with true <- missing == [],
         fields <- coerce_fields(signature, Map.take(fields, output_names)),
         :ok <- Imp.Schema.validate_fields(signature.outputs, fields) do
      {:ok, Imp.Prediction.new(fields)}
    else
      false ->
        {:error, {:missing_output_fields, missing}}

      {:error, errors} ->
        {:error,
         %Imp.AdapterParseError{
           message: Imp.Schema.retry_feedback(errors),
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

  defp coerce_value(value, :string) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp coerce_value(value, :string), do: value

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
    skip = opts |> Keyword.get(:skip, MapSet.new()) |> MapSet.new()

    sections =
      signature.inputs
      |> Enum.reduce([], fn field, acc ->
        value = fetch_field(inputs, field.name)

        if is_nil(value) or MapSet.member?(skip, field.name) do
          acc
        else
          [render_input_section(field, value) | acc]
        end
      end)
      |> Enum.reverse()
      |> then(fn sections ->
        case prefix do
          "" -> sections
          _prefix -> [prefix | sections]
        end
      end)

    if Enum.any?(sections, &is_list/1) do
      sections
      |> Enum.intersperse("\n\n")
      |> List.flatten()
      |> merge_adjacent_text_parts()
    else
      Enum.join(sections, "\n\n")
    end
  end

  defp render_input_section(field, value) do
    if native_content?(value) do
      ["[[ ## #{field.name} ## ]]\n" | native_content_parts(value)]
    else
      "[[ ## #{field.name} ## ]]\n#{format_value(value)}"
    end
  end

  defp native_content?(value) when is_list(value), do: Enum.any?(value, &native_content?/1)
  defp native_content?(%Imp.Adapters.Types.Image{}), do: true
  defp native_content?(%Imp.Adapters.Types.Audio{}), do: true
  defp native_content?(%Imp.Adapters.Types.File{}), do: true
  defp native_content?(%Imp.Adapters.Types.Document{}), do: true
  defp native_content?(%Imp.Adapters.Types.Code{}), do: true
  defp native_content?(%Imp.Adapters.Types.Reasoning{}), do: true
  defp native_content?(%Imp.Adapters.Types.Citation{}), do: true
  defp native_content?(%Imp.Adapters.Types.Type{}), do: true
  defp native_content?(_value), do: false

  defp native_content_parts(values) when is_list(values),
    do: Enum.flat_map(values, &native_content_parts/1)

  defp native_content_parts(value) do
    if native_content?(value), do: [value], else: [format_value(value)]
  end

  defp merge_adjacent_text_parts(parts) do
    parts
    |> Enum.reduce([], fn
      text, [previous | rest] when is_binary(text) and is_binary(previous) ->
        [previous <> text | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
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
    # Byte-faithful to DSPy's get_field_description_string (dspy/adapters/
    # utils.py): each field renders `N. \`name\` (type): {desc}` with the
    # colon-space always present, then the whole group is stripped — so a
    # field with no description keeps its trailing space only when it is not
    # the last line in its group. (epic dee-8zev / dee-l9vm, dee-qtzk)
    fields
    |> Enum.with_index(1)
    |> Enum.map(fn {field, index} ->
      "#{index}. `#{field.name}` (#{field_type(field.type)}): #{field_description(field)}"
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp field_description(field) do
    # DSPy renders a description equal to the "${name}" placeholder (the
    # ChainOfThought reasoning sentinel) as empty; match that exactly.
    desc = if field.desc == "${#{field.name}}", do: nil, else: field.desc

    [desc, answer_shape_instruction(field)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
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
    # DSPy 3.2.1 ChatAdapter.format_field_structure renders each field's value
    # placeholder via translate_field_type: input fields (and str/Reasoning
    # outputs) get no note; typed OUTPUT fields get an 8-space-indented
    # "# note: the value you produce ..." suffix. Match it exactly (dee-3zun).
    input_lines = Enum.map(signature.inputs, &interaction_field_line(&1, ""))
    output_lines = Enum.map(signature.outputs, &interaction_field_line(&1, structure_type_note(&1)))

    (input_lines ++ output_lines)
    |> Kernel.++(["[[ ## completed ## ]]"])
    |> Enum.join("\n\n")
  end

  defp interaction_field_line(field, note) do
    """
    [[ ## #{field.name} ## ]]
    {#{field.name}}#{note}
    """
    |> String.trim()
  end

  # Faithful to DSPy 3.2.1 dspy/adapters/utils.py translate_field_type: the note
  # text keyed on the field's Python type. Emitted only for output fields.
  defp structure_type_note(field) do
    case field_type(field.type) do
      "str" -> ""
      "bool" -> structure_note("must be True or False")
      "int" -> structure_note("must be a single int value")
      "float" -> structure_note("must be a single float value")
      # Imp's scalar type system stops here; enum/Literal/pydantic notes (DSPy's
      # remaining branches) arrive when Imp grows those types (dee-3zun follow-up).
      _ -> ""
    end
  end

  defp structure_note(desc), do: String.duplicate(" ", 8) <> "# note: the value you produce " <> desc

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
    # Byte-faithful to DSPy 3.2.1 ChatAdapter.user_message_output_requirements:
    # always singular "the field ", then every output marker joined with
    # ", then ", each carrying a Python-type note for non-str fields.
    # (epic dee-8zev / dee-l9vm, dee-3zun)
    markers =
      signature.outputs
      |> Enum.map(fn field -> "`[[ ## #{field.name} ## ]]`" <> output_type_info(field) end)
      |> Enum.join(", then ")

    "\n\nRespond with the corresponding output fields, starting with the field " <>
      markers <> ", and then ending with the marker for `[[ ## completed ## ]]`."
  end

  defp output_type_info(field) do
    case field_type(field.type) do
      "str" -> ""
      type_name -> " (must be formatted as a valid Python #{type_name})"
    end
  end

  defp append_content(content, ""), do: content
  defp append_content(content, suffix) when is_binary(content), do: content <> suffix

  defp append_content(content, suffix) when is_list(content),
    do: merge_adjacent_text_parts(content ++ [suffix])

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp format_value(value), do: inspect(value)

  defp render_demos(_signature, []), do: []

  defp render_demos(signature, demos) do
    {complete, incomplete} =
      demos
      |> Enum.map(&Imp.Example.to_map/1)
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

  defp extract_history(signature, inputs) do
    signature.inputs
    |> Enum.reduce({[], MapSet.new()}, fn field, {messages, fields} ->
      case fetch_field(inputs, field.name) do
        %Imp.History{} = history ->
          {messages ++ render_history_turns(signature, Imp.History.messages(history)),
           MapSet.put(fields, field.name)}

        _other ->
          {messages, fields}
      end
    end)
  end

  defp render_history_turns(signature, turns) do
    turns
    |> Enum.flat_map(fn turn ->
      turn = Imp.Example.new(turn) |> Imp.Example.to_map()

      if native_tool_history_turn?(turn) do
        render_native_tool_history_turn(signature, turn)
      else
        [
          %{
            role: :user,
            content: render_inputs(signature, turn, skip: history_input_fields(signature))
          },
          %{
            role: :assistant,
            content:
              render_outputs(signature, turn,
                missing_field_message: "Not supplied for this conversation history message. "
              )
          }
        ]
        |> Enum.reject(&blank_message?/1)
      end
    end)
  end

  defp native_tool_history_turn?(turn), do: not is_nil(fetch_field(turn, :tool_calls))

  defp render_native_tool_history_turn(signature, turn) do
    calls = normalize_history_tool_calls(fetch_field(turn, :tool_calls))
    results = List.wrap(fetch_field(turn, :tool_call_results))

    user = %{
      role: :user,
      content: render_inputs(signature, turn, skip: history_input_fields(signature))
    }

    assistant = %{
      role: :assistant,
      content: fetch_field(turn, :next_thought) |> blank_to_empty(),
      tool_calls: calls
    }

    tool_messages =
      Enum.map(results, fn result ->
        id = fetch_field(result, :id)

        %{
          role: :tool,
          content: result |> fetch_field(:result) |> format_value(),
          tool_calls: [%{id: id}]
        }
      end)

    [user, assistant | tool_messages]
    |> Enum.reject(fn
      %{role: :assistant, tool_calls: calls} -> calls == []
      message -> blank_message?(message)
    end)
  end

  defp normalize_history_tool_calls(%Imp.Adapters.Types.ToolCalls{tool_calls: calls}),
    do: Enum.map(calls, &Imp.Adapters.Types.ToolCall.format/1)

  # Redaction intentionally converts structs to credential-safe maps before an
  # event is stored in history. Preserve the collection envelope so replay still
  # emits the assistant tool-use message required before provider tool results.
  defp normalize_history_tool_calls(%{tool_calls: calls}),
    do: normalize_history_tool_calls(calls)

  defp normalize_history_tool_calls(%{"tool_calls" => calls}),
    do: normalize_history_tool_calls(calls)

  defp normalize_history_tool_calls(calls) when is_list(calls) do
    calls
    |> Imp.Adapters.Types.ToolCalls.new()
    |> normalize_history_tool_calls()
  end

  defp normalize_history_tool_calls(_calls), do: []

  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(value), do: to_string(value)

  defp history_input_fields(signature) do
    signature.inputs
    |> Enum.filter(&(&1.type == :history or &1.name == :history))
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp blank_message?(%{content: content}) when is_binary(content), do: String.trim(content) == ""

  defp blank_message?(%{content: content}) when is_list(content) do
    Enum.all?(content, fn
      text when is_binary(text) -> String.trim(text) == ""
      _part -> false
    end)
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
      |> Imp.Signature.output_names()
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
      |> Imp.Options.validate!(@format_option_schema, context)
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
