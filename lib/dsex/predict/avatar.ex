defmodule DSEx.Predict.Avatar do
  @moduledoc """
  BEAM-native Avatar actor with typed actions and bounded tool execution.

  Avatar asks a typed actor predictor for one action per turn. Tool results,
  including policy denials and execution errors, become structured observations
  for the next turn. A reserved `Finish` action or iteration exhaustion invokes
  a separate typed finalizer for the task signature.
  """

  @behaviour DSEx.Module

  alias __MODULE__.{Action, ActionOutput}

  defstruct [
    :signature,
    :actor,
    :finisher,
    tools: %{},
    max_iters: 3,
    tool_policy: :allow,
    metadata: %{}
  ]

  @reserved_inputs [:avatar_goal, :avatar_tools, :avatar_history]
  @reserved_outputs [:actions, :termination_reason]

  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 3],
    tool_policy: [type: {:custom, DSEx.ToolPolicy, :validate, []}, default: :allow]
  ]

  def new(signature, tools, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)
    validate_reserved_fields!(signature)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Avatar.new/3")
    tools = DSEx.Tool.index_tools!(tools, "DSEx.Predict.Avatar.new/3")

    if DSEx.Tool.resolve_name(tools, "Finish") do
      raise ArgumentError, "Finish is reserved by DSEx.Predict.Avatar"
    end

    predict_opts = Keyword.drop(opts, [:max_iters, :tool_policy])

    %__MODULE__{
      signature: signature,
      actor: DSEx.Predict.Predict.new(actor_signature(signature), predict_opts),
      finisher: DSEx.Predict.Predict.new(finisher_signature(signature), predict_opts),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_policy: opts[:tool_policy],
      metadata: opts[:metadata]
    }
  end

  @impl true
  def call(%__MODULE__{} = avatar, inputs) when is_map(inputs) or is_list(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         :ok <- validate_task_inputs(avatar.signature, inputs) do
      run(avatar, task_inputs(avatar.signature, inputs), [], 0)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error, {:invalid_avatar_inputs, "expected a map or field pairs, got: #{inspect(inputs)}"}}

  def put_instruction(%__MODULE__{actor: actor} = avatar, instruction)
      when is_binary(instruction) do
    signature = %{actor.signature | instructions: instruction}
    %{avatar | actor: DSEx.Predict.Predict.with_signature(actor, signature)}
  end

  def current_instruction(%__MODULE__{actor: actor}), do: actor.signature.instructions

  def with_lm(%__MODULE__{} = avatar, lm) do
    %{
      avatar
      | actor: DSEx.Predict.Predict.with_lm(avatar.actor, lm),
        finisher: DSEx.Predict.Predict.with_lm(avatar.finisher, lm)
    }
  end

  defp run(avatar, inputs, history, turn) when turn >= avatar.max_iters,
    do: finish(avatar, inputs, history, :max_iters)

  defp run(avatar, inputs, history, turn) do
    actor_inputs =
      Map.merge(inputs, %{
        avatar_goal: avatar.signature.instructions,
        avatar_tools: tool_descriptions(avatar),
        avatar_history: history
      })

    with {:ok, prediction} <- DSEx.Predict.Predict.call(avatar.actor, actor_inputs),
         {:ok, action} <- normalize_action(DSEx.Prediction.get(prediction, :action)) do
      if finish_action?(action) do
        finish(avatar, inputs, history, :finish)
      else
        observation = execute_action(avatar, action)
        run(avatar, inputs, history ++ [observation], turn + 1)
      end
    end
  end

  defp finish(avatar, inputs, history, reason) do
    final_inputs = Map.put(inputs, :avatar_history, history)

    with {:ok, prediction} <- DSEx.Predict.Predict.call(avatar.finisher, final_inputs) do
      prediction =
        prediction
        |> DSEx.Prediction.put(:actions, history)
        |> DSEx.Prediction.put(:termination_reason, reason)

      {:ok, prediction}
    end
  end

  defp execute_action(avatar, %Action{} = action) do
    canonical_name = DSEx.Tool.resolve_name(avatar.tools, action.tool_name)

    {output, error?} =
      cond do
        is_nil(canonical_name) ->
          {{:error, {:unknown_tool, action.tool_name}}, true}

        true ->
          arguments = DSEx.Tool.normalize_arguments(action.tool_input_query)

          case safe_authorize(avatar.tool_policy, canonical_name, arguments) do
            :ok -> safe_tool_call(Map.fetch!(avatar.tools, canonical_name), arguments)
            {:error, reason} -> {{:error, reason}, true}
          end
      end

    %ActionOutput{
      tool_name: canonical_name || action.tool_name,
      tool_input_query: DSEx.Redaction.redact(action.tool_input_query),
      tool_output: DSEx.Redaction.redact(output),
      error?: error?
    }
  end

  defp safe_tool_call(tool, arguments) do
    case DSEx.Tool.call(tool, arguments) do
      {:error, reason} -> {{:error, reason}, true}
      result -> {result, false}
    end
  rescue
    error -> {{:error, {:tool_error, tool.name, Exception.message(error)}}, true}
  catch
    kind, reason -> {{:error, {:tool_error, tool.name, {kind, reason}}}, true}
  end

  defp safe_authorize(policy, name, arguments) do
    DSEx.ToolPolicy.authorize(policy, name, arguments)
  rescue
    error -> {:error, {:tool_policy_error, name, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:tool_policy_error, name, {kind, reason}}}
  end

  defp normalize_action(%Action{} = action), do: {:ok, action}

  defp normalize_action(%{} = action) do
    action = Action.new(action)

    cond do
      not (is_atom(action.tool_name) or is_binary(action.tool_name)) ->
        {:error, {:invalid_avatar_action, :tool_name, action.tool_name}}

      is_nil(action.tool_input_query) ->
        {:error, {:invalid_avatar_action, :tool_input_query, nil}}

      true ->
        {:ok, action}
    end
  end

  defp normalize_action(action), do: {:error, {:invalid_avatar_action, action}}

  defp finish_action?(%Action{tool_name: name}), do: String.downcase(to_string(name)) == "finish"

  defp tool_descriptions(avatar) do
    avatar.tools
    |> Map.values()
    |> Enum.map(&%{name: &1.name, description: &1.description, schema: &1.schema})
    |> Kernel.++([
      %{name: "Finish", description: "Return the final output and finish the task.", schema: %{}}
    ])
  end

  defp actor_signature(signature) do
    action =
      DSEx.Signature.Field.new(
        %{
          name: :action,
          type: :object,
          desc: "The next tool action to take.",
          constraints: %{
            properties: %{
              tool_name: %{type: :string},
              tool_input_query: %{type: :any}
            }
          }
        },
        :output
      )

    %DSEx.Signature{
      inputs:
        signature.inputs ++
          [
            DSEx.Signature.Field.new(:avatar_goal, :input),
            DSEx.Signature.Field.new(%{name: :avatar_tools, type: :array}, :input),
            DSEx.Signature.Field.new(%{name: :avatar_history, type: :array}, :input)
          ],
      outputs: [action],
      instructions: actor_instructions()
    }
  end

  defp finisher_signature(signature) do
    %{
      signature
      | inputs:
          signature.inputs ++
            [DSEx.Signature.Field.new(%{name: :avatar_history, type: :array}, :input)],
        instructions:
          String.trim("""
          #{signature.instructions}
          Produce the final task outputs using the original inputs and Avatar action history.
          Do not request another tool.
          """)
    }
  end

  defp actor_instructions do
    """
    You will receive a goal, available tools, the user inputs, and prior action results.
    Select exactly one next action as an object with `tool_name` and `tool_input_query`.
    Reuse useful observations, recover from tool errors when possible, and avoid repeated calls.
    Select `Finish` when the action history contains enough information to answer the goal.
    """
    |> String.trim()
  end

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_avatar_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp validate_task_inputs(signature, inputs) do
    missing =
      signature.inputs
      |> Enum.reject(&optional?/1)
      |> Enum.map(& &1.name)
      |> Enum.reject(&has_key?(inputs, &1))

    if missing == [], do: :ok, else: {:error, {:missing_input_fields, missing}}
  end

  defp task_inputs(signature, inputs) do
    signature
    |> DSEx.Signature.input_names()
    |> Map.new(fn name -> {name, fetch(inputs, name)} end)
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp optional?(field),
    do: Map.get(field.metadata, :optional, Map.get(field.metadata, "optional", false))

  defp validate_reserved_fields!(signature) do
    input_collisions =
      DSEx.Signature.input_names(signature) --
        (DSEx.Signature.input_names(signature) -- @reserved_inputs)

    output_collisions =
      DSEx.Signature.output_names(signature) --
        (DSEx.Signature.output_names(signature) -- @reserved_outputs)

    if input_collisions != [] or output_collisions != [] do
      raise ArgumentError,
            "Avatar signature uses reserved fields: #{inspect(input_collisions ++ output_collisions)}"
    end
  end
end
