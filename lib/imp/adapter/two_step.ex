defmodule Imp.Adapter.TwoStep do
  @moduledoc """
  Faithful port of DSPy 3.2.1 `TwoStepAdapter` (dspy/adapters/two_step_adapter.py).

  Two stages:

    1. The MAIN LM receives a simple natural-language prompt: a persona/task
       system message built from the signature's field descriptions (no
       `[[ ## field ## ]]` markers), demos rendered as plain `name: value`
       user/assistant turns, and a plain `name: value` user message.
    2. Parsing runs a SECOND extraction LM through the ChatAdapter path over a
       synthesized `text -> {original output fields}` signature, extracting the
       structured fields from the main LM's free-form completion. A failed chat
       extraction falls back to a JSONAdapter-formatted retry, exactly like
       DSPy's `ChatAdapter.__call__` fallback.

  ## Extraction LM threading (mapping to DSPy's constructor argument)

  DSPy carries the extraction LM on the adapter instance:
  `dspy.TwoStepAdapter(extraction_model=lm)`. Imp adapters are stateless
  modules, so the instance slot maps onto Imp's settings surface — the same
  place `dspy.configure(adapter=...)` state already lives:

      Imp.configure(adapter: Imp.Adapter.TwoStep, two_step_extraction_lm: small_lm)
      # or scoped:
      Imp.Settings.context([two_step_extraction_lm: small_lm], fn -> ... end)

  A direct `parse/3` call may instead pass `extraction_lm:` in opts. A missing
  extraction LM is a loud error: parse returns
  `{:error, {:two_step_extraction_lm_not_configured, ...}}` rather than
  silently degrading to single-step parsing.

  The former plan-prepend extension that wore this name is now
  `Imp.Adapter.PlanFirst`.
  """

  @behaviour Imp.Adapter

  @format_option_schema [
    demos: [
      type: {:custom, Imp.Adapter.Chat, :validate_demos, []},
      default: []
    ]
  ]

  @parse_option_schema [
    extraction_lm: [type: :any]
  ]

  @doc """
  Formats the MAIN-LM messages: persona system message, `name: value` demos,
  and a `name: value` user message (DSPy `TwoStepAdapter.format`).
  """
  @impl true
  def format(signature, inputs, opts) do
    opts = validate_opts!(opts, @format_option_schema, "#{inspect(__MODULE__)}.format/3")
    demos = opts[:demos] |> Enum.map(&Imp.Example.to_map/1)

    [%{role: :system, content: task_description(signature)}] ++
      format_demos(signature, demos) ++
      [%{role: :user, content: user_message_content(signature, inputs)}]
  end

  @doc """
  Parses the main LM's free-form completion by calling the extraction LM with
  a ChatAdapter-formatted `text -> outputs` signature (DSPy
  `TwoStepAdapter.parse`). Any extraction failure (after DSPy's JSONAdapter
  fallback) is a loud error carrying the original completion.
  """
  @impl true
  def parse(signature, raw, opts) do
    opts = validate_opts!(opts, @parse_option_schema, "#{inspect(__MODULE__)}.parse/3")

    with {:ok, extraction_lm} <- fetch_extraction_lm(opts),
         {:ok, completion} <- require_text(raw) do
      extract(signature, completion, extraction_lm)
    end
  end

  # -- main-call rendering ----------------------------------------------------

  # DSPy TwoStepAdapter.format_task_description: persona line, input/output
  # field description blocks (get_field_description_string), lay-out line, and
  # a "Specific instructions:" line only when instructions are non-empty.
  defp task_description(signature) do
    parts =
      [
        "You are a helpful assistant that can solve tasks based on user input.",
        "As input, you will be provided with:\n" <>
          Imp.Adapter.Chat.field_description_string(signature.inputs),
        "Your outputs must contain:\n" <>
          Imp.Adapter.Chat.field_description_string(signature.outputs),
        "You should lay out your outputs in detail so that your answer can be understood by another agent"
      ] ++
        case signature.instructions do
          nil -> []
          "" -> []
          instructions -> ["Specific instructions: #{instructions}"]
        end

    Enum.join(parts, "\n")
  end

  # DSPy TwoStepAdapter.format_user_message_content: plain `name: value` lines
  # for PRESENT input fields, joined with blank lines; prefix/suffix take part
  # in the join before the final strip.
  defp user_message_content(signature, inputs, prefix \\ "") do
    parts =
      [prefix] ++
        Enum.flat_map(signature.inputs, fn field ->
          case fetch_present(inputs, field.name) do
            {:ok, value} -> ["#{field.name}: #{py_str(value)}"]
            :error -> []
          end
        end) ++ [""]

    parts |> Enum.join("\n\n") |> String.trim()
  end

  # DSPy TwoStepAdapter.format_assistant_message_content: plain `name: value`
  # lines for PRESENT output fields (absent fields are skipped, not replaced by
  # a missing-field message — upstream's guard makes the fallback unreachable).
  defp assistant_message_content(signature, outputs) do
    signature.outputs
    |> Enum.flat_map(fn field ->
      case fetch_present(outputs, field.name) do
        {:ok, value} -> ["#{field.name}: #{py_str(value)}"]
        :error -> []
      end
    end)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  # DSPy base Adapter.format_demos: complete demos (every field present and
  # non-nil) render after incomplete demos (at least one input and one output
  # field PRESENT); incomplete demos carry the explanatory prefix.
  defp format_demos(signature, demos) do
    {complete, incomplete} =
      Enum.reduce(demos, {[], []}, fn demo, {complete, incomplete} ->
        all_fields = signature.inputs ++ signature.outputs

        complete? =
          Enum.all?(all_fields, fn field ->
            match?({:ok, value} when not is_nil(value), fetch_present(demo, field.name))
          end)

        has_input? = Enum.any?(signature.inputs, &present?(demo, &1.name))
        has_output? = Enum.any?(signature.outputs, &present?(demo, &1.name))

        cond do
          complete? -> {[demo | complete], incomplete}
          has_input? and has_output? -> {complete, [demo | incomplete]}
          true -> {complete, incomplete}
        end
      end)

    incomplete_prefix =
      "This is an example of the task, though some input or output fields are not supplied."

    Enum.flat_map(Enum.reverse(incomplete), fn demo ->
      [
        %{role: :user, content: user_message_content(signature, demo, incomplete_prefix)},
        %{role: :assistant, content: assistant_message_content(signature, demo)}
      ]
    end) ++
      Enum.flat_map(Enum.reverse(complete), fn demo ->
        [
          %{role: :user, content: user_message_content(signature, demo)},
          %{role: :assistant, content: assistant_message_content(signature, demo)}
        ]
      end)
  end

  # -- extraction call --------------------------------------------------------

  defp extract(signature, completion, extraction_lm) do
    extractor_signature = extractor_signature(signature)
    messages = Imp.Adapter.Chat.format(extractor_signature, %{text: completion}, demos: [])

    with {:ok, raw} <- Imp.LM.generate(extraction_lm, messages, []),
         {:ok, output, _lm_metadata} <- Imp.LM.Result.split(raw),
         {:ok, prediction} <- Imp.Adapter.Chat.parse(extractor_signature, output, []) do
      {:ok, prediction}
    else
      {:error, reason} ->
        # DSPy's extraction call goes through ChatAdapter.__call__, which
        # retries a failure through JSONAdapter before giving up.
        json_fallback(extractor_signature, completion, extraction_lm, reason)
    end
  end

  defp json_fallback(extractor_signature, completion, extraction_lm, original_reason) do
    retry_messages = Imp.Adapter.JSON.format(extractor_signature, %{text: completion}, demos: [])

    retry_opts =
      Imp.Adapter.JSON.lm_opts(
        extractor_signature,
        [],
        Imp.LM.response_format_capability(extraction_lm)
      )

    with {:ok, raw} <- Imp.LM.generate(extraction_lm, retry_messages, retry_opts),
         {:ok, output, _lm_metadata} <- Imp.LM.Result.split(raw),
         {:ok, prediction} <- Imp.Adapter.JSON.parse(extractor_signature, output, []) do
      {:ok, prediction}
    else
      {:error, _retry_reason} ->
        # Mirrors DSPy's ValueError("Failed to parse response from the
        # original completion: ...") — loud, and the completion is retained.
        {:error, extraction_failed(original_reason, completion)}
    end
  end

  # DSPy TwoStepAdapter._create_extractor_signature: a `text` input plus the
  # ORIGINAL output fields (annotations and descriptions intact), with the
  # exact upstream instructions string — including the 12-space run the Python
  # source's line continuation embeds mid-sentence.
  @doc false
  def extractor_signature(signature) do
    outputs_str = Enum.map_join(signature.outputs, ", ", &"`#{&1.name}`")

    instructions =
      "The input is a text that should contain all the necessary information to produce the fields #{outputs_str}. " <>
        "            Your job is to extract the fields from the text verbatim. Extract precisely the appropriate value (content) for each field."

    %Imp.Signature{
      inputs: Imp.Signature.new("text: string -> ignored: string").inputs,
      outputs: signature.outputs,
      instructions: instructions
    }
  end

  # -- helpers ----------------------------------------------------------------

  defp fetch_extraction_lm(opts) do
    case Keyword.get(opts, :extraction_lm) || Map.get(Imp.Settings.get(), :two_step_extraction_lm) do
      nil ->
        {:error,
         {:two_step_extraction_lm_not_configured,
          "Imp.Adapter.TwoStep needs an extraction LM: configure " <>
            "`Imp.configure(two_step_extraction_lm: lm)` (DSPy: dspy.TwoStepAdapter(extraction_model=lm)) " <>
            "or pass `extraction_lm:` to parse/3"}}

      lm ->
        {:ok, lm}
    end
  end

  defp require_text(raw) when is_binary(raw), do: {:ok, raw}
  defp require_text(raw), do: {:error, Imp.AdapterParseError.unsupported_output(raw)}

  # The extraction's own failure keeps its kind when it was a parse failure;
  # an extraction LM that failed is `:other`, with its error as the reason.
  defp extraction_failed(reason, completion) do
    kind =
      case reason do
        %Imp.AdapterParseError{kind: kind} when not is_nil(kind) -> kind
        _other -> :other
      end

    %Imp.AdapterParseError{
      kind: kind,
      message:
        "Failed to parse response from the original completion: " <>
          if(is_exception(reason), do: Exception.message(reason), else: inspect(reason)),
      reason: reason,
      trace: %{raw: completion}
    }
  end

  defp present?(fields, name), do: match?({:ok, _value}, fetch_present(fields, name))

  defp fetch_present(fields, name) do
    string_name = to_string(name)

    cond do
      Map.has_key?(fields, name) -> {:ok, Map.fetch!(fields, name)}
      Map.has_key?(fields, string_name) -> {:ok, Map.fetch!(fields, string_name)}
      true -> :error
    end
  end

  # Python `str(...)` as DSPy's f-strings apply it: None/True/False keep their
  # Python spelling and floats render in repr form (1000000.0, not 1.0e6).
  defp py_str(value) when is_float(value), do: Imp.PyFloat.repr(value)
  defp py_str(value), do: Imp.Adapter.Chat.format_value(value)

  defp validate_opts!(opts, schema, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.take(Keyword.keys(schema))
      |> Imp.Options.validate!(schema, context)
    else
      raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, _schema, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end
end
