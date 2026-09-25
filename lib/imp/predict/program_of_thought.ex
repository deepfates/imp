defmodule Imp.Predict.ProgramOfThought do
  @moduledoc """
  Generates and executes a small BEAM-safe program, regenerating failed code.

  Program execution uses `Imp.Sandbox`; generated source is never passed to
  `Code.eval_string/3` or an external runtime. When execution fails, the next
  planner call receives the previous program and its error. If the sandbox
  value cannot directly satisfy the declared outputs, a final LM call extracts
  those outputs from the program, value, and execution trajectory.
  """

  @behaviour Imp.Module

  alias Imp.Predict.Predict
  alias Imp.{Prediction, Signature}

  @max_iters_metadata_key :program_of_thought_max_iters

  @type t :: %__MODULE__{
          signature: Signature.t(),
          predict: struct(),
          output_field: atom() | String.t(),
          max_iters: pos_integer()
        }

  defstruct [:signature, :predict, output_field: :answer, max_iters: 3]

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    output_field: [
      type: {:custom, __MODULE__, :validate_output_field, []},
      default: nil
    ],
    max_iters: [type: :pos_integer, default: 3]
  ]

  @doc false
  def validate_output_field(nil), do: {:ok, nil}
  def validate_output_field(field), do: Imp.FieldSelector.validate_name(field)

  @doc """
  Builds a ProgramOfThought predictor.

  `:max_iters` is the total number of generation and regeneration attempts and
  defaults to `3`. The retry budget is retained by portable save/load.
  """
  @spec new(term(), keyword()) :: t()
  def new(signature, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.ProgramOfThought.new/2")
    original = Imp.Signature.ensure(signature)

    program_signature = %{
      original
      | outputs: [
          Imp.Signature.Field.new(
            %{
              name: :program,
              type: :any,
              desc: "Safe Elixir expression to evaluate",
              metadata: %{optional: true}
            },
            :output
          ),
          Imp.Signature.Field.new(
            %{
              name: :tool,
              desc: "Optional tool name to call before the next program step",
              metadata: %{optional: true}
            },
            :output
          ),
          Imp.Signature.Field.new(
            %{
              name: :arguments,
              type: :any,
              desc:
                "Optional raw tool arguments; maps and provider JSON strings are both accepted",
              metadata: %{optional: true}
            },
            :output
          )
        ]
    }

    predict_opts =
      opts
      |> Predict.take_options()
      |> Keyword.update!(:metadata, &Map.put(&1, @max_iters_metadata_key, opts[:max_iters]))

    %__MODULE__{
      signature: original,
      predict: Predict.new(program_signature, predict_opts),
      output_field: resolve_output_field!(original, opts[:output_field]),
      max_iters: opts[:max_iters]
    }
  end

  @spec call(t(), map() | [{term(), term()}]) :: {:ok, Prediction.t()} | {:error, term()}
  @impl true
  def call(%__MODULE__{} = pot, inputs) do
    with {:ok, normalized_inputs} <- normalize_inputs(inputs),
         {:ok, prediction} <- predict_step(pot, normalized_inputs) do
      execute_attempt(pot, normalized_inputs, prediction, 1, [])
    end
  end

  @doc false
  def predict_step(%__MODULE__{} = pot, inputs) do
    Predict.call(pot.predict, inputs)
  end

  @doc false
  def code_act_step(%__MODULE__{} = pot, inputs, trajectory) do
    signature =
      pot.predict.signature
      |> append_inputs([
        field(:trajectory, :input, :any, "Programs and observations from earlier iterations")
      ])
      |> append_outputs([
        field(:finished, :output, :boolean, "Whether enough information exists for extraction",
          optional: true
        )
      ])

    call_with_signature(
      pot,
      signature,
      Map.put(inputs, :trajectory, model_trajectory(trajectory))
    )
  end

  @doc false
  def extract_outputs(%__MODULE__{} = pot, inputs, program, value, trajectory) do
    signature =
      pot.signature
      |> append_inputs([
        field(:final_generated_program, :input, :string, "The final executed Elixir program"),
        field(:code_output, :input, :any, "The BEAM-safe program output"),
        field(:trajectory, :input, :any, "Programs and observations from earlier iterations")
      ])
      |> Map.update!(:instructions, &extraction_instructions/1)

    extraction_inputs =
      inputs
      |> Map.put(:final_generated_program, program)
      |> Map.put(:code_output, value)
      |> Map.put(:trajectory, model_trajectory(trajectory))

    call_with_signature(pot, signature, extraction_inputs)
  end

  @doc false
  def parse_program(program) when is_binary(program) do
    source = String.trim(program)

    source =
      case Regex.run(~r/```(?:elixir)?\s*\n?(.*?)\n?```/s, source, capture: :all_but_first) do
        [fenced] -> fenced
        _no_fence -> source
      end
      |> String.split("---", parts: 2)
      |> hd()
      |> String.split("\n\n\n", parts: 2)
      |> hd()
      |> String.trim()

    if source == "", do: {:error, :missing_program}, else: {:ok, source}
  end

  def parse_program(nil), do: {:error, :missing_program}
  def parse_program(program), do: {:error, {:invalid_generated_program, program}}

  @doc false
  def eval_program(program, inputs) do
    Imp.Sandbox.eval(program, inputs)
  rescue
    exception -> {:error, {:program_runtime_error, exception}}
  catch
    kind, reason -> {:error, {:program_runtime_error, {kind, reason}}}
  end

  @doc false
  def project_outputs(
        %__MODULE__{signature: %{outputs: [field]}, output_field: output_field},
        %Prediction{} = prediction,
        value
      ) do
    # The signature parser represents both untyped outputs and explicit strings
    # as `:string`. Preserve the established native-scalar behavior for that
    # ambiguous case, while enforcing every unambiguous declared type.
    validation =
      if field.type == :string,
        do: :ok,
        else: validate_output_fields([field], %{field.name => value})

    with :ok <- validation do
      {:ok, Prediction.put(prediction, output_field, value)}
    end
  end

  def project_outputs(
        %__MODULE__{signature: %{outputs: outputs}},
        %Prediction{} = prediction,
        value
      )
      when is_map(value) do
    with {:ok, fields} <- normalize_output_fields(outputs, value),
         :ok <- validate_output_fields(outputs, fields) do
      prediction =
        Enum.reduce(outputs, prediction, fn field, acc ->
          Prediction.put(acc, field.name, Map.fetch!(fields, field.name))
        end)

      {:ok, prediction}
    end
  end

  def project_outputs(%__MODULE__{signature: signature}, %Prediction{}, value) do
    {:error,
     {:invalid_program_outputs, {:expected_map, Signature.output_names(signature), value}}}
  end

  defp execute_attempt(pot, inputs, prediction, iteration, trace) do
    generated = Prediction.get(prediction, :program)

    with {:ok, program} <- parse_program(generated),
         {:ok, value} <- eval_program(program, inputs) do
      event = execution_event(iteration, program, {:ok, value})
      trajectory = Enum.reverse([event | trace])

      case project_outputs(pot, prediction, value) do
        {:ok, projected} ->
          {:ok, put_trajectory(projected, trajectory)}

        {:error, projection_error} ->
          extract_or_projection_error(pot, inputs, program, value, trajectory, projection_error)
      end
    else
      {:error, reason} -> retry_or_fail(pot, inputs, generated, reason, iteration, trace)
    end
  end

  defp retry_or_fail(pot, inputs, generated, reason, iteration, trace) do
    trace = [execution_event(iteration, generated, {:error, reason}) | trace]

    if iteration < effective_max_iters(pot) do
      retry_inputs =
        inputs
        |> Map.put(:previous_program, generated)
        |> Map.put(:error, error_text(reason))
        |> Map.put(:trajectory, model_trajectory(Enum.reverse(trace)))

      with {:ok, prediction} <- regenerate_step(pot, retry_inputs) do
        execute_attempt(pot, inputs, prediction, iteration + 1, trace)
      end
    else
      # Keep the established Imp error contract while still doing every
      # configured regeneration attempt.
      {:error, reason}
    end
  end

  defp regenerate_step(pot, inputs) do
    signature =
      pot.predict.signature
      |> append_inputs([
        field(:previous_program, :input, :string, "The previously generated program that failed"),
        field(:error, :input, :string, "The previous parse or execution error"),
        field(:trajectory, :input, :any, "Programs and observations from earlier attempts")
      ])
      |> Map.update!(:instructions, &regeneration_instructions/1)

    call_with_signature(pot, signature, inputs)
  end

  defp extract_or_projection_error(pot, inputs, program, value, trajectory, projection_error) do
    case extract_outputs(pot, inputs, program, value, trajectory) do
      {:ok, prediction} -> {:ok, put_trajectory(prediction, trajectory)}
      {:error, _extraction_error} -> {:error, projection_error}
    end
  end

  # Loop-state keys PoT/CodeAct deliberately carry in the inputs map between
  # iterations. Each per-step signature declares only the subset it renders, so
  # the carriers a step does not use are dropped here ON PURPOSE (they are the
  # module's own state, not user input) — otherwise Predict's extra-input
  # warning (de-hzcv gap #2) would fire on every loop step.
  @carried_loop_keys [:observation, :code_act_history, :previous_program, :error]

  defp call_with_signature(pot, signature, inputs) do
    declared = MapSet.new(signature.inputs, & &1.name)
    inputs = Map.drop(inputs, Enum.reject(@carried_loop_keys, &MapSet.member?(declared, &1)))

    pot.predict
    |> Predict.with_signature(signature)
    |> Predict.call(inputs)
  end

  defp append_inputs(signature, fields),
    do: %{signature | inputs: append_unique(signature.inputs, fields)}

  defp append_outputs(signature, fields),
    do: %{signature | outputs: append_unique(signature.outputs, fields)}

  defp append_unique(existing, additions) do
    names = MapSet.new(existing, & &1.name)
    existing ++ Enum.reject(additions, &MapSet.member?(names, &1.name))
  end

  defp field(name, kind, type, desc, metadata \\ []) do
    Signature.Field.new(
      %{name: name, type: type, desc: desc, metadata: Map.new(metadata)},
      kind
    )
  end

  defp regeneration_instructions(nil), do: regeneration_instructions("")

  defp regeneration_instructions(instructions) do
    instructions <>
      "\nThe previous generated program failed. Use previous_program, error, and trajectory to generate a corrected safe Elixir program."
  end

  defp extraction_instructions(nil), do: extraction_instructions("")

  defp extraction_instructions(instructions) do
    instructions <>
      "\nExtract the declared outputs from final_generated_program, code_output, and trajectory. Return only those declared outputs."
  end

  # What the model reads about a failed program: the term as it has always
  # read it, with a raised exception written as its message. The recorded
  # error keeps the exception.
  @doc false
  def error_text(reason), do: inspect(model_reason(reason))

  @doc false
  def model_trajectory(events) when is_list(events) do
    Enum.map(events, fn
      %{output: {:error, reason}} = event -> %{event | output: {:error, model_reason(reason)}}
      event -> event
    end)
  end

  def model_trajectory(other), do: other

  defp model_reason({:program_runtime_error, exception}) when is_exception(exception),
    do: {:program_runtime_error, Exception.message(exception)}

  defp model_reason(reason), do: reason

  defp execution_event(iteration, program, result) do
    Imp.Redaction.redact(%{
      iteration: iteration,
      action: :program,
      input: program,
      output: result
    })
  end

  defp put_trajectory(%Prediction{} = prediction, trajectory) do
    %{
      prediction
      | metadata: Map.put(prediction.metadata, :program_of_thought_trajectory, trajectory)
    }
  end

  defp normalize_inputs(inputs) when is_map(inputs), do: {:ok, inputs}

  defp normalize_inputs(inputs) when is_list(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_predict_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp effective_max_iters(%__MODULE__{predict: %{metadata: metadata}, max_iters: fallback}) do
    case Map.get(metadata, @max_iters_metadata_key, fallback) do
      max_iters when is_integer(max_iters) and max_iters > 0 -> max_iters
      _invalid -> fallback
    end
  end

  defp normalize_output_fields(outputs, value) do
    {fields, unknown, duplicates} =
      Enum.reduce(value, {%{}, [], []}, fn {key, field_value}, {fields, unknown, duplicates} ->
        case declared_output_name(outputs, key) do
          nil ->
            {fields, [key | unknown], duplicates}

          name when is_map_key(fields, name) ->
            {fields, unknown, [name | duplicates]}

          name ->
            {Map.put(fields, name, field_value), unknown, duplicates}
        end
      end)

    missing = outputs |> Enum.map(& &1.name) |> Enum.reject(&Map.has_key?(fields, &1))

    cond do
      unknown != [] -> {:error, {:unknown_output_fields, stable_keys(unknown)}}
      duplicates != [] -> {:error, {:duplicate_output_fields, stable_keys(duplicates)}}
      missing != [] -> {:error, {:missing_output_fields, missing}}
      true -> {:ok, fields}
    end
  end

  defp declared_output_name(outputs, key) when is_atom(key) or is_binary(key) do
    Enum.find_value(outputs, fn field ->
      if field.name == key or to_string(field.name) == to_string(key), do: field.name
    end)
  end

  defp declared_output_name(_outputs, _key), do: nil

  defp validate_output_fields(outputs, fields) do
    case Imp.Schema.validate_fields(outputs, fields) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_output_fields, errors}}
    end
  end

  defp stable_keys(keys), do: keys |> Enum.uniq() |> Enum.sort_by(&inspect/1)

  defp resolve_output_field!(signature, nil) do
    signature
    |> output_names()
    |> List.first()
  end

  defp resolve_output_field!(signature, field) do
    outputs = output_names(signature)

    if field in outputs do
      field
    else
      raise ArgumentError,
            "Imp.Predict.ProgramOfThought.new/2 :output_field must be one of the signature outputs; got #{inspect(field)} for outputs #{inspect(outputs)}"
    end
  end

  defp output_names(signature), do: Enum.map(signature.outputs, & &1.name)
end
