defmodule Imp.Adapter.Chat do
  @moduledoc """
  Plain chat adapter: instructions plus field-labelled user content.

  `format/3` renders a signature and its inputs as a system message, one
  user/assistant pair per demo, the conversation history, and a final user
  message. Fields are labelled with `[[ ## name ## ]]` markers.

  `parse/3` accepts an `Imp.Prediction`, a map of output fields, or completion
  text. Text is split on those markers and the first section for each output
  field wins. A completion that does not cover every output field is a parse
  error rather than a partial prediction.

  One signature-declared exception: `signature.metadata[:prose_step]` names an
  output field that takes a completion carrying no marker at all. A native tool
  loop asks for a thought and tool calls, and a model that answers a step in
  plain prose with no tool call has said something and called nothing — the
  plain reading of that completion, not a format failure worth a second LM call
  through `Imp.Adapter.JSON`. Remaining outputs take their declared defaults, so
  the signature says what an unanswered field means. The exception is narrow on
  purpose: the completion must carry no `[[ ## field ## ]]` line anywhere and
  must not be blank, a completion that carried native tool calls is a map rather
  than text and never reaches it, and a signature without that metadata parses
  exactly as before. `Imp.Predict.ReActV2` sets it on its internal step
  signature; see that module.

  Options to `format/3`: `:demos`, `:response_instruction`, `:guidance`,
  `:omit_empty_request`, and the renderer seams `:output_renderer`,
  `:input_section_renderer`, `:system_renderer`, `:tool_result_renderer` and
  `:history_note_renderer`,
  which let another adapter reuse this message assembly with its own dialect
  and let a host bound what a tool result costs in the prompt without changing
  what the loop records. `:history_note_renderer` is the one seam for saying
  something *about* a stored turn rather than re-rendering it: it is consulted
  for every history turn, native tool turns included, after that turn's own
  messages, and its text becomes one user message right after them — the next
  thing the model reads. A note is data about the turn (the answer was not
  delivered, the account's allowance ran out), not a rewrite of what happened,
  so the record the loop keeps is unchanged. Options outside that list
  are ignored; anything that is not a keyword list raises `ArgumentError`.
  """

  @behaviour Imp.Adapter

  @format_option_schema [
    demos: [
      type: {:custom, __MODULE__, :validate_demos, []},
      default: []
    ],
    response_instruction: [type: :boolean, default: true],
    # Renderer for demo/history ASSISTANT turns: (signature, outputs,
    # missing_message). A delegating adapter substitutes its own serialization
    # while reusing Chat's message assembly.
    output_renderer: [type: {:fun, 3}],
    # Renderer for one INPUT-field section in user-facing turns (main request,
    # demos, history): (field, formatted_value), where formatted_value is
    # Chat's field-aware formatted string. The renderer only wraps it in the
    # adapter's dialect.
    input_section_renderer: [type: {:fun, 2}],
    # Renderer for the SYSTEM message: (signature, opts), where opts are these
    # format options, so a renderer can read `:guidance`. Default:
    # `render_system/2`. Replacing it leaves parsing unchanged.
    system_renderer: [type: {:fun, 2}],
    # Renderer for one TOOL result message: (result, call), where call is
    # `%{id:, name:}` for the call that produced it. Default:
    # `format_tool_result/1`. This is where a host bounds what the model reads
    # of a large result: the loop still records the whole result in history and
    # in run events, and only the prompt carries the bounded view. Errors reach
    # it too, so a host decides how a failure reads.
    tool_result_renderer: [type: {:fun, 2}],
    # Renderer for a NOTE about one stored history turn: (signature, turn),
    # returning nil or text. Text becomes one user message immediately after
    # that turn's own messages, for both native tool turns and plain ones. This
    # is how a host tells the model something that became true after the turn
    # ended without editing the turn.
    history_note_renderer: [type: {:fun, 2}],
    # Loop guidance a program passes as data rather than writing into
    # `signature.instructions`: `%{finish_tool:, input_names:, output_names:,
    # tool_names:}`.
    guidance: [type: {:or, [:map, nil]}],
    # Drop the trailing user message when it is blank. A native tool loop has
    # nothing left to ask once every input is in the history, and an empty
    # message still counts as a turn to the provider.
    omit_empty_request: [type: :boolean, default: false]
  ]

  @impl true
  def format(signature, inputs, opts) do
    opts = validate_format_opts!(opts, "#{inspect(__MODULE__)}.format/3")
    demos = opts[:demos]
    response_instruction? = opts[:response_instruction]
    # Chat's own renderer emits `[[ ## field ## ]]` markers; the JSON adapter
    # passes one that emits a JSON object instead.
    output_renderer = Keyword.get(opts, :output_renderer) || (&render_demo_outputs/3)
    input_renderer = Keyword.get(opts, :input_section_renderer) || (&chat_input_section/2)
    system_renderer = Keyword.get(opts, :system_renderer) || (&render_system/2)

    tool_result_renderer =
      Keyword.get(opts, :tool_result_renderer) || (&default_tool_result_renderer/2)

    renderers = %{
      output: output_renderer,
      input_section: input_renderer,
      tool_result: tool_result_renderer,
      history_note: Keyword.get(opts, :history_note_renderer) || (&no_history_note/2),
      submit_is_text?: submit_is_text?(Keyword.get(opts, :guidance))
    }

    {history_messages, history_fields} = extract_history(signature, inputs, renderers)

    request = %{
      role: :user,
      content:
        append_content(
          render_inputs(signature, inputs,
            skip: history_fields,
            section_renderer: input_renderer
          ),
          render_response_instruction(signature, response_instruction?)
        )
    }

    trailing =
      if opts[:omit_empty_request] and blank_message?(request), do: [], else: [request]

    [%{role: :system, content: system_renderer.(signature, opts)}] ++
      render_demos(signature, demos, output_renderer, input_renderer) ++
      history_messages ++ trailing
  end

  @impl true
  def parse(signature, raw, opts) do
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")
    do_parse(signature, raw)
  end

  defp do_parse(_signature, %Imp.Prediction{} = prediction), do: {:ok, prediction}
  defp do_parse(signature, map) when is_map(map), do: build_prediction(signature, map)

  # The completion is split into `[[ ## field ## ]]`-headed sections and the
  # first section for each output field wins; then defaults and nullable
  # fallbacks fill the rest. A completion that still misses an output field is
  # a parse error: there is no single-output leniency and no in-parse JSON
  # decode, so a bad parse fails loudly and `Imp.Predict`'s JSON-adapter
  # fallback can fire.
  defp do_parse(signature, text) when is_binary(text) do
    build_prediction(signature, parse_fields(signature, text))
  end

  defp do_parse(_signature, raw), do: {:error, {:unsupported_lm_output, raw}}

  @doc false
  def validate_demos(demos) do
    {:ok, Imp.Example.normalize_demos!(demos, "#{inspect(__MODULE__)}.format/3")}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp build_prediction(signature, fields) do
    # PRESENT fields (even present-nil) are collected and coerced before the
    # shared fallback/completeness pass. Key presence, never truthiness, decides
    # whether a model value overrides a default.
    fields =
      signature.outputs
      |> Enum.filter(&field_present?(fields, &1.name))
      |> Map.new(fn field -> {field.name, fetch_field(fields, field.name)} end)
      |> then(&coerce_fields(signature, &1))

    with {:ok, completed} <- Imp.Adapter.OutputFields.complete(signature, fields),
         :ok <- Imp.Schema.validate_fields(signature.outputs, completed) do
      {:ok, Imp.Prediction.new(completed)}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         %Imp.AdapterParseError{
           message: Imp.Schema.retry_feedback(errors),
           reason: fields
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp coerce_fields(signature, fields) do
    signature.outputs
    |> Enum.reduce(fields, fn field, acc ->
      if Map.has_key?(acc, field.name),
        do: Map.update!(acc, field.name, &coerce_field(field, &1)),
        else: acc
    end)
  end

  # Dispatch order matches DSPy's `parse_value`: an enum-constrained string
  # (DSPy's Literal) gets quote and prefix stripping, a string field gets
  # Python `str(value)`, everything else takes the typed clauses below.
  defp coerce_field(field, value) do
    cond do
      is_nil(value) and Imp.Adapter.OutputFields.optional?(field) ->
        nil

      field.type in [:union, "union"] ->
        coerce_union(field, value)

      code_field?(field) ->
        coerce_code(value, code_language(field))

      field.type in [:reasoning, "reasoning"] ->
        coerce_reasoning(value)

      true ->
        case enum_constraint(field) do
          values when is_list(values) -> coerce_literal(value, values)
          _no_enum -> coerce_value(value, field.type)
        end
    end
  end

  defp coerce_union(field, value) do
    field.metadata
    |> fetch_meta(:constraints, %{})
    |> fetch_meta(:any_of, [])
    |> Enum.reduce_while(value, fn branch, _original ->
      branch_type = fetch_meta(branch, :type, :string)

      branch_field =
        Imp.Signature.Field.new(
          %{
            name: field.name,
            type: branch_type,
            constraints: drop_meta(branch, :type),
            optional: fetch_meta(branch, :optional, false)
          },
          :output
        )

      coerced = coerce_field(branch_field, value)

      if Imp.Schema.validate_field(branch_field, coerced) == [],
        do: {:halt, coerced},
        else: {:cont, value}
    end)
  end

  defp coerce_code(value, language) do
    Imp.Adapter.Types.Code.new(value, language: language)
  rescue
    ArgumentError -> value
  end

  defp coerce_reasoning(value) do
    Imp.Adapter.Types.Reasoning.new(value)
  rescue
    ArgumentError -> value
  end

  # An allowed value passes through. Otherwise a string is stripped of a
  # wrapping `Literal[...]`/`str[...]` spelling and one pair of quotes, and the
  # stripped form is accepted if allowed. Anything else keeps the raw value so
  # schema validation reports the enum error rather than this function hiding
  # it.
  defp coerce_literal(value, allowed) do
    cond do
      value in allowed ->
        value

      is_binary(value) ->
        stripped =
          value
          |> String.trim()
          |> strip_literal_wrapper()
          |> strip_wrapping_quotes()

        if stripped in allowed, do: stripped, else: value

      true ->
        value
    end
  end

  defp strip_literal_wrapper(value) do
    if (String.starts_with?(value, "Literal[") or String.starts_with?(value, "str[")) and
         String.ends_with?(value, "]") do
      {index, 1} = :binary.match(value, "[")
      binary_part(value, index + 1, byte_size(value) - index - 2)
    else
      value
    end
  end

  defp strip_wrapping_quotes(value) do
    with true <- String.length(value) > 1,
         first when first in ["\"", "'"] <- String.first(value),
         true <- first == String.last(value) do
      String.slice(value, 1..-2//1)
    else
      _no_strip -> value
    end
  end

  defp enum_constraint(field) do
    field.metadata
    |> fetch_meta(:constraints, %{})
    |> case do
      constraints when is_map(constraints) -> fetch_meta(constraints, :enum)
      _other -> nil
    end
  end

  # A string field takes Python's `str(value)` spelling: "None"/"True"/"False",
  # repr-style lists and dicts ("[1, 2, 3]"), floats in repr form.
  defp coerce_value(value, :string), do: py_str(value)

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

  # A datetime field arrives as ISO 8601 text: an offset-carrying string yields
  # a DateTime, a naive string a NaiveDateTime. An unparsable string stays raw
  # so schema validation reports the type error.
  defp coerce_value(value, :datetime) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(trimmed) do
          {:ok, naive} -> naive
          {:error, _reason} -> value
        end
    end
  end

  defp coerce_value(value, :array) when is_binary(value), do: decode_composite(value)
  defp coerce_value(value, :object) when is_binary(value), do: decode_composite(value)

  defp coerce_value(value, _type), do: value

  defp decode_composite(value) do
    case Imp.Adapter.JSONRepair.decode(value) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  # Python `str(...)` as applied to a string field's value.
  defp py_str(value) when is_binary(value), do: value
  defp py_str(nil), do: "None"
  defp py_str(true), do: "True"
  defp py_str(false), do: "False"
  defp py_str(value) when is_integer(value), do: Integer.to_string(value)
  defp py_str(value) when is_float(value), do: Imp.PyFloat.repr(value)

  defp py_str(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &py_repr/1) <> "]"

  defp py_str(value) when is_map(value) and not is_struct(value),
    do:
      "{" <> Enum.map_join(value, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"

  defp py_str(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp py_str(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp py_str(value) when is_atom(value), do: to_string(value)
  defp py_str(value), do: inspect(value)

  # Python `repr(...)` for elements nested in a `str()`-rendered list or dict:
  # a string is quoted (single quotes, unless it contains one and no double
  # quote); other scalars render as `py_str`.
  defp py_repr(value) when is_binary(value) do
    if String.contains?(value, "'") and not String.contains?(value, "\"") do
      "\"" <> value <> "\""
    else
      "'" <> String.replace(value, "'", "\\'") <> "'"
    end
  end

  defp py_repr(value), do: py_str(value)

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

  # Whether `name` is a present key, even with a nil value, across the atom,
  # string and existing-atom spellings `fetch_field/2` understands. Present-nil
  # and absent must stay distinguishable, and `fetch_field/2` collapses both to
  # nil.
  defp field_present?(fields, name) do
    string_name = to_string(name)

    Map.has_key?(fields, name) or
      Map.has_key?(fields, string_name) or
      ((is_binary(name) and existing_atom(name)) && Map.has_key?(fields, existing_atom(name)))
  end

  defp render_inputs(signature, inputs, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    skip = opts |> Keyword.get(:skip, MapSet.new()) |> MapSet.new()
    section_renderer = Keyword.get(opts, :section_renderer) || (&chat_input_section/2)

    sections =
      signature.inputs
      |> Enum.reduce([], fn field, acc ->
        value = fetch_field(inputs, field.name)

        if is_nil(value) or MapSet.member?(skip, field.name) do
          acc
        else
          [render_input_section(field, value, section_renderer) | acc]
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

  # Native multimodal content keeps Chat's marker header whatever the section
  # renderer is: the multimodal split happens on provider content parts, not in
  # the field dialect. Text values go through the section renderer.
  defp render_input_section(field, value, section_renderer) do
    if code_field?(field) do
      code = Imp.Adapter.Types.Code.new(value, language: code_language(field))
      section_renderer.(field, Imp.Adapter.Types.Code.format(code))
    else
      render_non_code_input_section(field, value, section_renderer)
    end
  end

  defp render_non_code_input_section(field, value, section_renderer) do
    if native_content?(value) do
      ["[[ ## #{field.name} ## ]]\n" | native_content_parts(value)]
    else
      section_renderer.(field, format_field_value(field, value))
    end
  end

  # Default input-section dialect: `[[ ## name ## ]]\nvalue`.
  defp chat_input_section(field, formatted), do: "[[ ## #{field.name} ## ]]\n#{formatted}"

  # A list on a string-typed field renders as a numbered guillemet blob list
  # rather than a JSON dump: the RAG pattern, where a `context` string field
  # carries a list of retrieved passages. A list on an array-typed field keeps
  # the JSON dump.
  defp format_field_value(field, value) when is_list(value) do
    # The blob branch takes only a list of strings (or the empty list, "N/A"),
    # which is all upstream can render. Any other list, such as a `tools` field
    # carrying tool-definition maps, falls back to JSON rather than crashing.
    if field_annotation(field) == "str" and Enum.all?(value, &is_binary/1) do
      format_input_list_field_value(value)
    else
      format_value(value)
    end
  end

  defp format_field_value(_field, value), do: format_value(value)

  defp format_input_list_field_value([]), do: "N/A"
  defp format_input_list_field_value([single]), do: format_blob(single)

  defp format_input_list_field_value(values) do
    values
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {value, index} -> "[#{index}] #{format_blob(value)}" end)
  end

  defp format_blob(blob) when is_binary(blob) do
    if String.contains?(blob, "\n") or String.contains?(blob, "«") or String.contains?(blob, "»") do
      "«««\n    " <> String.replace(blob, "\n", "\n    ") <> "\n»»»"
    else
      "«" <> blob <> "»"
    end
  end

  defp format_blob(blob), do: format_blob(to_string(blob))

  defp native_content?(value) when is_list(value), do: Enum.any?(value, &native_content?/1)
  defp native_content?(%Imp.Adapter.Types.Image{}), do: true
  defp native_content?(%Imp.Adapter.Types.Audio{}), do: true
  defp native_content?(%Imp.Adapter.Types.File{}), do: true
  defp native_content?(%Imp.Adapter.Types.Document{}), do: true
  defp native_content?(%Imp.Adapter.Types.Code{}), do: true
  defp native_content?(%Imp.Adapter.Types.Reasoning{}), do: true
  defp native_content?(%Imp.Adapter.Types.Citation{}), do: true
  defp native_content?(%Imp.Adapter.Types.Type{}), do: true
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

  # Default assistant-content renderer for demo/history turns. Three rules it
  # must keep: values resolve by key presence, so a legitimate `false` or `nil`
  # output is not replaced by the missing sentinel; the joined field block is
  # stripped once rather than per field, so interior trailing whitespace
  # survives; the trailing `\n\n[[ ## completed ## ]]\n` marker is always
  # appended.
  defp render_demo_outputs(signature, outputs, missing_field_message) do
    body =
      signature
      |> resolve_demo_outputs(outputs, missing_field_message)
      |> Enum.map_join("\n\n", fn {name, value} ->
        "[[ ## #{name} ## ]]\n#{format_value(value)}"
      end)
      |> String.trim()

    body <> "\n\n[[ ## completed ## ]]\n"
  end

  # Resolves a demo/history turn's output fields to ordered `{name, value}`
  # pairs by key presence: a present field, even nil or false, keeps its value;
  # an absent field takes the missing-field message. Shared with the JSON
  # adapter so the two assistant paths differ only in serialization. Internal
  # cross-adapter seam, not public API.
  @doc false
  def resolve_demo_outputs(signature, outputs, missing_field_message) do
    Enum.map(signature.outputs, fn field ->
      value =
        if field_present?(outputs, field.name) do
          fetch_field(outputs, field.name)
        else
          missing_field_message
        end

      {field.name, value}
    end)
  end

  # The default system message: the field listing, the marker template and the
  # objective. Public so a custom `:system_renderer` can fall back to it;
  # an internal seam, not packaged API.
  @doc false
  def render_system(signature, opts \\ []) do
    objective =
      signature.instructions
      |> with_guidance(Keyword.get(opts, :guidance))
      |> Imp.Adapter.Instructions.objective_text()

    """
    Your input fields are:
    #{render_field_list(signature.inputs)}
    Your output fields are:
    #{render_field_list(signature.outputs)}
    All interactions will be structured in the following way, with the appropriate values filled in.

    #{render_interaction_template(signature)}
    In adhering to this structure, your objective is: #{objective}
    """
    |> String.trim()
  end

  # Renders loop guidance passed as data, appended after the program's own
  # instructions so the two have separate owners. With a finish tool the text
  # is DSPy ReActV2's, byte for byte. A `finish_tool` of nil means the loop has
  # no finish tool and the answer is the text the model writes when it stops
  # calling tools, so that one line says so instead; this is Imp's divergence
  # for a signature with one text output (`Imp.Predict.ReActV2`).
  defp with_guidance(instructions, nil), do: instructions

  defp with_guidance(instructions, %{} = guidance) do
    names = fn key -> guidance |> Map.get(key, []) |> Enum.map_join(", ", &"`#{&1}`") end

    finish =
      case Map.get(guidance, :finish_tool, :submit) do
        nil ->
          "When the final answer is ready, write it as plain text without calling a tool."

        tool ->
          "When the final answer is ready, call `#{tool}` with #{names.(:output_names)}."
      end

    """
    #{instructions}
    You are an Agent. Use the supplied tools to produce #{names.(:output_names)} from #{names.(:input_names)}.
    Call tools when more information is needed.
    #{finish}
    The available tools are: #{names.(:tool_names)}.
    """
    |> String.trim()
  end

  # The field listing, shared with the TwoStep adapter's persona prompt.
  # Internal cross-adapter seam, not public API.
  @doc false
  def field_description_string(fields), do: render_field_list(fields)

  defp render_field_list(fields) do
    # Byte-faithful to DSPy: each field renders `N. \`name\` (type): {desc}`
    # with the colon-space always present, then the whole group is stripped, so
    # a field with no description keeps its trailing space only when it is not
    # the last line in its group.
    fields
    |> Enum.with_index(1)
    |> Enum.map(fn {field, index} ->
      "#{index}. `#{field.name}` (#{field_annotation(field)}): #{field_description(field)}" <>
        Imp.Adapter.FieldConstraints.suffix(field)
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp field_description(field) do
    # A description equal to the "${name}" placeholder (the chain-of-thought
    # reasoning sentinel) renders as empty.
    desc = if field.desc == "${#{field.name}}", do: nil, else: field.desc

    base =
      [desc, answer_shape_instruction(field)]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(" ")

    if code_field?(field) do
      type_description =
        "Type description of #{code_annotation(field)}: " <>
          Imp.Adapter.Types.Code.description(code_language(field))

      case base do
        "" -> "\n    " <> type_description
        _ -> base <> "\n    " <> type_description
      end
    else
      base
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
    # Input fields, and string or reasoning outputs, get no type note. Every
    # other output field gets an 8-space-indented "# note: the value you
    # produce ..." suffix.
    input_lines = Enum.map(signature.inputs, &interaction_field_line(&1, ""))

    output_lines =
      Enum.map(signature.outputs, &interaction_field_line(&1, structure_type_note(&1)))

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

  # The note text, keyed on the field's Python type and emitted only for output
  # fields. Composite types (enum, array, object) resolve through
  # `Imp.Adapter.CompositeType` first; scalars take the clauses below.
  defp structure_type_note(field) do
    case Imp.Adapter.CompositeType.note_desc(field) do
      nil -> scalar_structure_type_note(field)
      desc -> structure_note(desc)
    end
  end

  defp scalar_structure_type_note(field) do
    case field_type(field.type) do
      "str" -> ""
      "bool" -> structure_note("must be True or False")
      "int" -> structure_note("must be a single int value")
      "float" -> structure_note("must be a single float value")
      _ -> ""
    end
  end

  defp structure_note(desc),
    do: String.duplicate(" ", 8) <> "# note: the value you produce " <> desc

  defp field_type(:string), do: "str"
  defp field_type(:reasoning), do: "str"
  defp field_type("reasoning"), do: "str"
  defp field_type(:integer), do: "int"
  defp field_type(:float), do: "float"
  defp field_type(:number), do: "number"
  defp field_type(:boolean), do: "bool"
  defp field_type(type), do: to_string(type)

  defp fetch_meta(map, key, default \\ nil)

  defp fetch_meta(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_meta(map, key, default), do: Map.get(map, key, default)

  defp drop_meta(map, key) when is_atom(key),
    do: map |> Map.delete(key) |> Map.delete(Atom.to_string(key))

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
    # Byte-faithful to DSPy: always the singular "the field ", then every output
    # marker joined with ", then ", each carrying a Python-type note unless the
    # field is a string.
    markers =
      signature.outputs
      |> Enum.map(fn field -> "`[[ ## #{field.name} ## ]]`" <> output_type_info(field) end)
      |> Enum.join(", then ")

    "\n\nRespond with the corresponding output fields, starting with the field " <>
      markers <> ", and then ending with the marker for `[[ ## completed ## ]]`."
  end

  defp output_type_info(field) do
    case field_annotation(field) do
      "str" -> ""
      type_name -> " (must be formatted as a valid Python #{type_name})"
    end
  end

  # The Python annotation name for a field: composite types resolve through
  # `Imp.Adapter.CompositeType`, scalars through the plain type-name mapping.
  defp field_annotation(field) do
    if code_field?(field),
      do: code_annotation(field),
      else: Imp.Adapter.CompositeType.annotation_name(field) || field_type(field.type)
  end

  defp append_content(content, ""), do: content
  defp append_content(content, suffix) when is_binary(content), do: content <> suffix

  defp append_content(content, suffix) when is_list(content),
    do: merge_adjacent_text_parts(content ++ [suffix])

  @doc """
  Renders a tool result as the text a reader should see, whether that reader
  is the model or a person looking at a host's tool card.

  Successful results format like any other value. A failed result renders as
  one sentence instead of an Elixir term: a denied call says who declined it,
  a crashed tool names itself and its message, an atom reason is spelled out, a
  rejected `submit` says which outputs it needs, and a structured `:reason` map
  reads as its reason and limit. Hosts that relay Imp tool results over a
  protocol boundary should use this so the same words reach the person that
  reached the model.

      iex> Imp.Adapter.Chat.format_tool_result({:error, {:tool_authorization_denied, :post, :client_denied}})
      "Error: post was not allowed; the person declined it."
  """
  @spec format_tool_result(term()) :: String.t()
  def format_tool_result({:error, reason}), do: "Error: " <> error_prose(reason)
  def format_tool_result(value), do: format_value(value)

  defp error_prose({:tool_authorization_denied, name, :client_denied}),
    do: "#{name} was not allowed; the person declined it."

  defp error_prose({:tool_authorization_denied, name, reason}),
    do: "#{name} was not allowed: #{error_prose(reason)}"

  defp error_prose({:tool_error, name, message}), do: "#{name} failed: #{error_prose(message)}"

  # A failed submit is the one tool error the model is expected to act on, so it
  # says what is wrong with the call rather than naming an internal term.
  defp error_prose({:missing_output_fields, names}) when is_list(names),
    do: "submit is missing: " <> Enum.map_join(names, ", ", &to_string/1)

  defp error_prose({:invalid_submit_outputs, reason}),
    do: "submit outputs were not accepted: #{error_prose(reason)}"

  defp error_prose({:invalid_submit_arguments, _arguments}), do: "submit needs a map of outputs"

  defp error_prose(reason) when is_binary(reason), do: reason

  defp error_prose(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp error_prose(reason) when is_exception(reason), do: Exception.message(reason)

  # Adapters and tools carry structured failures as a map keyed on :reason. The
  # reason is the sentence; a :limit is the number the reader needs with it.
  defp error_prose(reason) when is_map(reason) and not is_struct(reason) do
    case fetch_either(reason, :reason) do
      {:ok, value} ->
        case fetch_either(reason, :limit) do
          {:ok, limit} -> "#{error_prose(value)} (limit #{format_value(limit)})"
          :error -> error_prose(value)
        end

      :error ->
        inspect(reason, limit: 20)
    end
  end

  defp error_prose(reason), do: inspect(reason, limit: 20)

  defp fetch_either(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  # Scalars take Python's `str(...)` spelling: `None`, `True`, `False`, where
  # Elixir's `to_string/1` would give "", "true" and "false". Public as an
  # internal cross-adapter seam, so the other adapters format scalars
  # identically and differ only in dialect.
  @doc false
  def format_value(value) when is_binary(value), do: value
  def format_value(nil), do: "None"
  def format_value(true), do: "True"
  def format_value(false), do: "False"

  def format_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  # Datetimes render as ISO 8601, their JSON string form.
  def format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def format_value(%Imp.Adapter.Types.Code{} = value), do: Imp.Adapter.Types.Code.format(value)

  # A list or map renders as complete, compact JSON with Python's default
  # separators. It must never be truncated: a cut structured tool result is one
  # the model cannot count and no bound can measure.
  def format_value(value) when is_list(value) or (is_map(value) and not is_struct(value)),
    do: py_json_dumps(value)

  def format_value(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  # Python `json.dumps(value, ensure_ascii=False)` with its default separators
  # `", "` and `": "`. A term JSON cannot carry (a tuple, a PID, a struct with
  # no encoder) renders as a complete `inspect`, never a cut one.
  @doc false
  def py_json_dumps(value) do
    case dumps(value) do
      {:ok, iodata} -> IO.iodata_to_binary(iodata)
      :error -> inspect(value, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp dumps(nil), do: {:ok, "null"}
  defp dumps(true), do: {:ok, "true"}
  defp dumps(false), do: {:ok, "false"}
  defp dumps(value) when is_binary(value), do: {:ok, Jason.encode!(value)}
  defp dumps(value) when is_atom(value), do: {:ok, Jason.encode!(Atom.to_string(value))}
  defp dumps(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp dumps(value) when is_float(value), do: {:ok, Imp.PyFloat.repr(value)}
  defp dumps(%DateTime{} = value), do: {:ok, Jason.encode!(DateTime.to_iso8601(value))}
  defp dumps(%NaiveDateTime{} = value), do: {:ok, Jason.encode!(NaiveDateTime.to_iso8601(value))}

  defp dumps(value) when is_list(value) do
    with {:ok, items} <- dumps_all(value) do
      {:ok, ["[", Enum.intersperse(items, ", "), "]"]}
    end
  end

  defp dumps(value) when is_map(value) and not is_struct(value) do
    with {:ok, pairs} <-
           value
           |> Enum.map(fn {key, item} -> {key, item} end)
           |> Enum.reduce_while({:ok, []}, fn {key, item}, {:ok, acc} ->
             with {:ok, key_json} <- dumps_key(key),
                  {:ok, item_json} <- dumps(item) do
               {:cont, {:ok, [[key_json, ": ", item_json] | acc]}}
             else
               :error -> {:halt, :error}
             end
           end) do
      {:ok, ["{", pairs |> Enum.reverse() |> Enum.intersperse(", "), "}"]}
    end
  end

  defp dumps(_value), do: :error

  defp dumps_all(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case dumps(item) do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  # A non-string key takes its Python `str()`, except that a bool becomes
  # "true"/"false" as `json.dumps` spells it; numbers keep their digits.
  defp dumps_key(key) when is_binary(key), do: {:ok, Jason.encode!(key)}
  defp dumps_key(key) when is_atom(key), do: {:ok, Jason.encode!(Atom.to_string(key))}
  defp dumps_key(key) when is_integer(key), do: {:ok, Jason.encode!(Integer.to_string(key))}
  defp dumps_key(_key), do: :error

  defp code_field?(%{type: type}), do: type in [:code, "code"]

  defp code_language(field) do
    field.metadata
    |> fetch_meta(:language, "python")
    |> to_string()
  end

  defp code_annotation(field), do: "Code_#{code_language(field)}"

  defp render_demos(_signature, [], _renderer, _input_renderer), do: []
  defp render_demos(_signature, nil, _renderer, _input_renderer), do: []

  defp render_demos(signature, demos, renderer, input_renderer) do
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
    |> Enum.flat_map(&render_demo(signature, &1, :incomplete, renderer, input_renderer))
    |> Kernel.++(
      complete
      |> Enum.reverse()
      |> Enum.flat_map(&render_demo(signature, &1, :complete, renderer, input_renderer))
    )
  end

  defp default_tool_result_renderer(result, _call), do: format_tool_result(result)

  defp no_history_note(_signature, _turn), do: nil

  defp extract_history(signature, inputs, renderers) do
    signature.inputs
    |> Enum.reduce({[], MapSet.new()}, fn field, {messages, fields} ->
      case fetch_field(inputs, field.name) do
        %Imp.History{} = history ->
          {messages ++
             render_history_turns(signature, Imp.History.messages(history), renderers),
           MapSet.put(fields, field.name)}

        _other ->
          {messages, fields}
      end
    end)
  end

  defp render_history_turns(signature, turns, renderers) do
    turns
    |> Enum.flat_map(fn turn ->
      turn = Imp.Example.new(turn) |> Imp.Example.to_map()

      messages =
        if native_tool_history_turn?(turn) do
          render_native_tool_history_turn(signature, turn, renderers)
        else
          [
            %{
              role: :user,
              content:
                render_inputs(signature, turn,
                  skip: history_input_fields(signature),
                  section_renderer: renderers.input_section
                )
            },
            %{
              role: :assistant,
              content:
                renderers.output.(
                  signature,
                  turn,
                  "Not supplied for this conversation history message. "
                )
            }
          ]
          |> Enum.reject(&blank_message?/1)
        end

      messages ++ history_note_messages(signature, turn, renderers.history_note)
    end)
  end

  # The note is what the model reads next after the turn it is about, so it is
  # a user message directly behind that turn's own messages. A renderer that
  # returns nothing adds nothing.
  defp history_note_messages(signature, turn, note_renderer) do
    case note_renderer.(signature, turn) do
      note when is_binary(note) and note != "" -> [%{role: :user, content: note}]
      _no_note -> []
    end
  end

  defp native_tool_history_turn?(turn), do: not is_nil(fetch_field(turn, :tool_calls))

  # A loop whose guidance names no finish tool answers in plain text, and has
  # no `submit` for a recorded call to name.
  defp submit_is_text?(%{} = guidance),
    do: Map.has_key?(guidance, :finish_tool) and is_nil(guidance.finish_tool)

  defp submit_is_text?(_guidance), do: false

  defp render_native_tool_history_turn(signature, turn, renderers) do
    calls = normalize_history_tool_calls(fetch_field(turn, :tool_calls))
    results = List.wrap(fetch_field(turn, :tool_call_results))

    {calls, results, answer} =
      if renderers.submit_is_text?,
        do: submit_as_text(calls, results),
        else: {calls, results, nil}

    tool_result_renderer = renderers.tool_result

    user = %{
      role: :user,
      content:
        render_inputs(signature, turn,
          skip: history_input_fields(signature),
          section_renderer: renderers.input_section
        )
    }

    thought = turn |> fetch_field(:next_thought) |> blank_to_empty()

    # A step that said something and called nothing is a plain assistant turn:
    # no `tool_calls` key for a provider to reconcile, and the thought is shown
    # back to the model, which is the point of recording it. A turn with
    # neither content nor calls is dropped below.
    assistant =
      if calls == [],
        do: %{role: :assistant, content: thought},
        else: %{role: :assistant, content: thought, tool_calls: calls}

    tool_messages =
      Enum.map(results, fn result ->
        id = fetch_field(result, :id)
        call = %{id: id, name: result |> fetch_field(:name) |> blank_to_empty()}

        %{
          role: :tool,
          content: tool_result_renderer.(fetch_field(result, :result), call),
          tool_calls: [%{id: id}]
        }
      end)

    answered =
      cond do
        is_nil(answer) -> []
        calls == [] -> []
        true -> [%{role: :assistant, content: answer}]
      end

    assistant =
      if is_binary(answer) and calls == [],
        do: %{assistant | content: join_text(thought, answer)},
        else: assistant

    ([user, assistant | tool_messages] ++ answered)
    |> Enum.reject(fn
      %{role: :assistant, tool_calls: calls} -> calls == []
      message -> blank_message?(message)
    end)
  end

  # A recorded `submit` call, replayed to a loop that has none. The call was
  # the turn's answer, so it is shown as the answer: assistant text, with its
  # result dropped. Shown as a call to a tool the request does not offer, some
  # providers' models imitate it and write the raw tool-call markup as text.
  defp submit_as_text(calls, results) do
    {submits, calls} = Enum.split_with(calls, &(get_in(&1, [:function, :name]) == "submit"))

    case submits do
      [] ->
        {calls, results, nil}

      submits ->
        ids = MapSet.new(submits, &Map.get(&1, :id))
        results = Enum.reject(results, &MapSet.member?(ids, fetch_field(&1, :id)))
        answer = submits |> List.last() |> get_in([:function, :arguments]) |> submitted_text()
        {calls, results, answer}
    end
  end

  defp submitted_text(%{} = arguments) do
    case Map.values(arguments) do
      [text] when is_binary(text) -> text
      _other -> Jason.encode!(arguments)
    end
  end

  defp submitted_text(text) when is_binary(text), do: text
  defp submitted_text(_arguments), do: ""

  defp join_text("", answer), do: answer
  defp join_text(thought, answer), do: thought <> "\n\n" <> answer

  defp normalize_history_tool_calls(%Imp.Adapter.Types.ToolCalls{tool_calls: calls}),
    do: Enum.map(calls, &Imp.Adapter.Types.ToolCall.format/1)

  # Redaction converts structs to credential-safe maps before an event is
  # stored in history. The collection envelope must survive, or replay omits
  # the assistant tool-use message a provider requires before tool results.
  defp normalize_history_tool_calls(%{tool_calls: calls}),
    do: normalize_history_tool_calls(calls)

  defp normalize_history_tool_calls(%{"tool_calls" => calls}),
    do: normalize_history_tool_calls(calls)

  defp normalize_history_tool_calls(calls) when is_list(calls) do
    calls
    |> Imp.Adapter.Types.ToolCalls.new()
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

  # An incomplete demo is still usable when at least one input field and one
  # output field are present. Key presence, not non-nil: a present-but-nil
  # output field must not drop the whole demo.
  defp usable_incomplete_demo?(signature, demo) do
    Enum.any?(signature.inputs, fn field -> field_present?(demo, field.name) end) and
      Enum.any?(signature.outputs, fn field -> field_present?(demo, field.name) end)
  end

  defp render_demo(signature, demo, :incomplete, renderer, input_renderer) do
    [
      %{
        role: :user,
        content:
          render_inputs(signature, demo,
            prefix:
              "This is an example of the task, though some input or output fields are not supplied.",
            section_renderer: input_renderer
          )
      },
      %{
        role: :assistant,
        content: renderer.(signature, demo, "Not supplied for this particular example. ")
      }
    ]
  end

  defp render_demo(signature, demo, :complete, renderer, input_renderer) do
    [
      %{role: :user, content: render_inputs(signature, demo, section_renderer: input_renderer)},
      %{
        role: :assistant,
        content:
          renderer.(signature, demo, "Not supplied for this conversation history message. ")
      }
    ]
  end

  # Matched against each line after stripping.
  @field_header_pattern ~r/^\[\[ ## (\w+) ## \]\]/u

  # Section scanning, ported from DSPy line for line:
  #   * a line whose stripped form starts with the header pattern opens a new
  #     section, and the rest of the line past the match becomes its first
  #     content line when non-empty (upstream slices the ORIGINAL line at the
  #     stripped match end; that quirk is reproduced);
  #   * every other line appends to the current section;
  #   * sections are joined with "\n" and stripped;
  #   * only headers naming an output field count, the first occurrence wins,
  #     and the name must match exactly: no downcasing, no `name:` label lines.
  # A completion carrying no marker at all is the whole answer for a signature
  # that declared a prose field, and marker parsing otherwise.
  defp parse_fields(signature, text) do
    case prose_step_field(signature, text) do
      {:ok, name} -> %{name => String.trim(text)}
      :error -> parse_marker_sections(signature, text)
    end
  end

  # `signature.metadata[:prose_step]` names the output field that takes a
  # marker-free completion. Only a completion with no `[[ ## field ## ]]` line
  # anywhere qualifies: a partially marked completion is still a parse failure,
  # so a model that half-followed the format is not silently reinterpreted.
  # Native tool calls never reach here — a completion that carried them is a
  # map, not text.
  defp prose_step_field(signature, text) do
    with name when not is_nil(name) <-
           Map.get(signature.metadata, :prose_step, Map.get(signature.metadata, "prose_step")),
         field when not is_nil(field) <- output_field(signature, name),
         true <- String.trim(text) != "",
         true <- marker_free?(text) do
      {:ok, field.name}
    else
      _no_prose_step -> :error
    end
  end

  defp output_field(signature, name) do
    name = to_string(name)
    Enum.find(signature.outputs, &(to_string(&1.name) == name))
  end

  defp marker_free?(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.all?(&is_nil(Regex.run(@field_header_pattern, String.trim(&1))))
  end

  defp parse_marker_sections(signature, text) do
    allowed = Map.new(signature.outputs, fn field -> {to_string(field.name), field.name} end)

    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce([{nil, []}], fn line, [{header, lines} | rest] ->
      trimmed = String.trim(line)

      case Regex.run(@field_header_pattern, trimmed) do
        [full, section_header] ->
          remaining = line |> String.slice(String.length(full)..-1//1) |> String.trim()
          content = if remaining == "", do: [], else: [remaining]
          [{section_header, content}, {header, lines} | rest]

        nil ->
          [{header, [line | lines]} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn
      {nil, _lines}, acc ->
        acc

      {header, lines}, acc ->
        case Map.fetch(allowed, header) do
          {:ok, field_name} ->
            value = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
            Map.put_new(acc, field_name, value)

          :error ->
            acc
        end
    end)
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
