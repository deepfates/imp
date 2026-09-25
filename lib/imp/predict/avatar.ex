defmodule Imp.Predict.Avatar do
  @moduledoc """
  BEAM-native Avatar actor with typed actions and bounded tool execution.

  Avatar asks a typed actor predictor for one action per turn. Tool results,
  including policy denials and execution errors, become structured observations
  for the next turn. A reserved `Finish` action or iteration exhaustion invokes
  a separate typed finalizer for the task signature. Each tool callback runs in
  an isolated unlinked task under `:tool_timeout_ms`; a timeout kills that task,
  records a terminal action observation, and proceeds directly to finalization.
  """

  @behaviour Imp.Module

  alias __MODULE__.{Action, ActionOutput}

  defstruct [
    :signature,
    :actor,
    :finisher,
    tools: %{},
    max_iters: 3,
    tool_timeout_ms: 30_000,
    tool_policy: :allow,
    metadata: %{}
  ]

  @reserved_inputs [:avatar_goal, :avatar_tools, :avatar_history]
  @reserved_outputs [:actions, :termination_reason]

  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    demos: [type: {:list, :any}, default: []],
    config: [type: :keyword_list, default: []],
    metadata: [type: {:map, :any, :any}, default: %{}],
    max_iters: [type: :non_neg_integer, default: 3],
    tool_timeout_ms: [type: :non_neg_integer, default: 30_000],
    tool_policy: [type: {:custom, Imp.ToolPolicy, :validate, []}, default: :allow]
  ]

  def new(signature, tools, opts \\ []) do
    signature = Imp.Signature.ensure(signature)
    validate_reserved_fields!(signature)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.Avatar.new/3")
    tools = Imp.Tool.index_tools!(tools, "Imp.Predict.Avatar.new/3")

    if Imp.Tool.resolve_name(tools, "Finish") do
      raise ArgumentError, "Finish is reserved by Imp.Predict.Avatar"
    end

    predict_opts = Keyword.drop(opts, [:max_iters, :tool_timeout_ms, :tool_policy])

    %__MODULE__{
      signature: signature,
      actor: Imp.Predict.Predict.new(actor_signature(signature), predict_opts),
      finisher: Imp.Predict.Predict.new(finisher_signature(signature), predict_opts),
      tools: tools,
      max_iters: opts[:max_iters],
      tool_timeout_ms: opts[:tool_timeout_ms],
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
    %{avatar | actor: Imp.Predict.Predict.with_signature(actor, signature)}
  end

  def current_instruction(%__MODULE__{actor: actor}), do: actor.signature.instructions

  def with_lm(%__MODULE__{} = avatar, lm) do
    %{
      avatar
      | actor: Imp.Predict.Predict.with_lm(avatar.actor, lm),
        finisher: Imp.Predict.Predict.with_lm(avatar.finisher, lm)
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

    with {:ok, prediction} <- Imp.Predict.Predict.call(avatar.actor, actor_inputs),
         {:ok, action} <- normalize_action(Imp.Prediction.get(prediction, :action)) do
      if finish_action?(action) do
        finish(avatar, inputs, history, :finish)
      else
        case execute_action(avatar, action) do
          {:continue, observation} ->
            run(avatar, inputs, history ++ [observation], turn + 1)

          {:halt, observation, reason} ->
            finish(avatar, inputs, history ++ [observation], reason)
        end
      end
    end
  end

  defp finish(avatar, inputs, history, reason) do
    final_inputs = Map.put(inputs, :avatar_history, history)

    with {:ok, prediction} <- Imp.Predict.Predict.call(avatar.finisher, final_inputs) do
      prediction =
        prediction
        |> Imp.Prediction.put(:actions, history)
        |> Imp.Prediction.put(:termination_reason, reason)

      {:ok, prediction}
    end
  end

  defp execute_action(avatar, %Action{} = action) do
    canonical_name = Imp.Tool.resolve_name(avatar.tools, action.tool_name)

    {output, error?, terminal_reason} =
      cond do
        is_nil(canonical_name) ->
          {{:error, {:unknown_tool, action.tool_name}}, true, nil}

        true ->
          arguments = Imp.Tool.normalize_arguments(action.tool_input_query)

          case safe_authorize(avatar.tool_policy, canonical_name, arguments) do
            :ok ->
              bounded_tool_call(
                Map.fetch!(avatar.tools, canonical_name),
                arguments,
                avatar.tool_timeout_ms
              )

            {:error, reason} ->
              {{:error, reason}, true, nil}
          end
      end

    observation = %ActionOutput{
      tool_name: canonical_name || action.tool_name,
      tool_input_query: Imp.Redaction.redact(action.tool_input_query),
      tool_output: Imp.Redaction.redact(output),
      error?: error?,
      terminal_reason: terminal_reason
    }

    if terminal_reason,
      do: {:halt, observation, terminal_reason},
      else: {:continue, observation}
  end

  defp bounded_tool_call(tool, arguments, timeout) do
    task =
      Task.Supervisor.async_nolink(Imp.UnlinkedTaskSupervisor, fn ->
        safe_tool_call(tool, arguments)
      end)

    case Task.yield(task, timeout) do
      {:ok, {output, error?}} ->
        {output, error?, nil}

      {:exit, reason} ->
        {{:error, {:tool_task_exit, tool.name, reason}}, true, nil}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {{:error, {:tool_timeout, tool.name, timeout}}, true, :tool_timeout}
    end
  rescue
    error -> {{:error, {:tool_task_error, tool.name, error}}, true, nil}
  catch
    kind, reason -> {{:error, {:tool_task_error, tool.name, {kind, reason}}}, true, nil}
  end

  defp safe_tool_call(tool, arguments) do
    case Imp.Tool.call(tool, arguments) do
      {:error, reason} -> {{:error, reason}, true}
      result -> {result, false}
    end
  rescue
    error -> {{:error, {:tool_error, tool.name, error}}, true}
  catch
    kind, reason -> {{:error, {:tool_error, tool.name, {kind, reason}}}, true}
  end

  defp safe_authorize(policy, name, arguments) do
    Imp.ToolPolicy.authorize(policy, name, arguments)
  rescue
    error -> {:error, {:tool_policy_error, name, error}}
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
      Imp.Signature.Field.new(
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

    %Imp.Signature{
      inputs:
        signature.inputs ++
          [
            Imp.Signature.Field.new(:avatar_goal, :input),
            Imp.Signature.Field.new(%{name: :avatar_tools, type: :array}, :input),
            Imp.Signature.Field.new(%{name: :avatar_history, type: :array}, :input)
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
            [Imp.Signature.Field.new(%{name: :avatar_history, type: :array}, :input)],
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
    |> Imp.Signature.input_names()
    |> Map.new(fn name -> {name, fetch(inputs, name)} end)
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp optional?(field),
    do: Map.get(field.metadata, :optional, Map.get(field.metadata, "optional", false))

  defp validate_reserved_fields!(signature) do
    input_collisions =
      Imp.Signature.input_names(signature) --
        (Imp.Signature.input_names(signature) -- @reserved_inputs)

    output_collisions =
      Imp.Signature.output_names(signature) --
        (Imp.Signature.output_names(signature) -- @reserved_outputs)

    if input_collisions != [] or output_collisions != [] do
      raise ArgumentError,
            "Avatar signature uses reserved fields: #{inspect(input_collisions ++ output_collisions)}"
    end
  end
end
