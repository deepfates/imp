defmodule DSEx.Predict.RLM do
  @moduledoc """
  Recursive Language Model module.

  RLM is not retrieval-augmented generation. It is an inference-time strategy
  for large or awkward contexts: inputs are exposed as sandbox variables and a
  controller LM iteratively chooses actions until it submits structured output.

  This implementation uses a BEAM-safe sandbox for production control.
  Supported controller actions are:

  - `%{action: "eval", code: "x + 1"}` to evaluate a safe expression.
  - `%{action: "llm_query", signature: "...", inputs: %{...}}` to call a sub-LM.
  - `%{action: "submit", result: %{...}}` to return signature outputs.

  The loop enforces `max_iterations` and `max_llm_calls` budgets and stores an
  interpretable trajectory in prediction metadata.
  """

  @behaviour DSEx.Module

  defstruct [
    :signature,
    :lm,
    :adapter,
    :sub_lm,
    tools: %{},
    tool_policy: :allow,
    max_iterations: 10,
    max_llm_calls: 20,
    max_time_ms: nil,
    max_preview_chars: 2_000,
    max_observation_chars: 10_000,
    dynamic_lm?: true,
    dynamic_sub_lm?: true,
    dynamic_adapter?: true
  ]

  @doc """
  Creates an RLM controller loop.

  Options:

  - `:lm` - controller LM.
  - `:sub_lm` - LM used for `llm_query` actions; defaults to `:lm`.
  - `:tools` - list of `DSEx.Tool` values available to `tool` actions.
  - `:tool_policy` - `:allow`, a list of allowed tool names, or a predicate.
  - `:max_iterations`, `:max_llm_calls`, `:max_time_ms` - execution budgets.
  - `:max_preview_chars` - how much large input context the controller sees.
  - `:max_observation_chars` - truncation limit for string observations.
  """
  def new(signature, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)

    %__MODULE__{
      signature: signature,
      lm: Keyword.get(opts, :lm),
      adapter: Keyword.get(opts, :adapter),
      sub_lm: Keyword.get(opts, :sub_lm, Keyword.get(opts, :lm)),
      tools: Keyword.get(opts, :tools, []) |> Enum.map(&coerce_tool/1) |> Map.new(&{&1.name, &1}),
      tool_policy: Keyword.get(opts, :tool_policy, :allow),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      max_llm_calls: Keyword.get(opts, :max_llm_calls, 20),
      max_time_ms: Keyword.get(opts, :max_time_ms),
      max_preview_chars: Keyword.get(opts, :max_preview_chars, 2_000),
      max_observation_chars:
        Keyword.get(opts, :max_output_chars, Keyword.get(opts, :max_observation_chars, 10_000)),
      dynamic_lm?: not Keyword.has_key?(opts, :lm),
      dynamic_sub_lm?: not Keyword.has_key?(opts, :sub_lm) and not Keyword.has_key?(opts, :lm),
      dynamic_adapter?: not Keyword.has_key?(opts, :adapter)
    }
  end

  @impl true
  @doc """
  Runs the RLM loop.

  The controller LM returns actions such as `eval`, `assign`, `tool`,
  `llm_query`, and `submit`. A successful submit returns a `DSEx.Prediction`
  with `:rlm_trace` metadata.
  """
  def call(%__MODULE__{} = rlm, inputs) do
    state = %{
      vars: Map.new(inputs),
      observations: [],
      trace: [],
      llm_calls: 0,
      started_at: System.monotonic_time(:millisecond)
    }

    run_loop(rlm, state, 1)
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration)
       when iteration > rlm.max_iterations do
    {:error, {:rlm_max_iterations, rlm.max_iterations, Enum.reverse(state.trace)}}
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration) do
    with :ok <- check_time_budget(rlm, state),
         {:ok, raw_action} <- controller_action(rlm, state, iteration),
         {:ok, action} <- normalize_action(raw_action),
         {:cont, state} <- step(rlm, action, state, iteration) do
      run_loop(rlm, state, iteration + 1)
    else
      {:done, prediction, state} ->
        {:ok, add_trace(prediction, state)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp controller_action(%__MODULE__{} = rlm, state, iteration) do
    case resolve_lm(rlm) do
      nil -> {:error, :rlm_requires_controller_lm}
      lm -> controller_action_with_lm(rlm, lm, state, iteration)
    end
  end

  defp controller_action_with_lm(%__MODULE__{} = rlm, lm, state, iteration) do
    messages = [
      %{
        role: :system,
        content: "You are an RLM controller. Return JSON with action eval, llm_query, or submit."
      },
      %{
        role: :user,
        content:
          Jason.encode!(%{
            signature: DSEx.Signature.to_spec(rlm.signature),
            iteration: iteration,
            variables: variable_metadata(state.vars, rlm.max_preview_chars),
            observations: Enum.map(state.observations, &safe_json/1),
            tools: tool_metadata(rlm.tools),
            budget: %{
              remaining_iterations: rlm.max_iterations - iteration + 1,
              remaining_llm_calls: rlm.max_llm_calls - state.llm_calls,
              remaining_time_ms: remaining_time(rlm, state)
            }
          })
      }
    ]

    DSEx.LM.generate(lm, messages, [])
  end

  defp normalize_action(%{"action" => _action} = action), do: {:ok, action}

  defp normalize_action(%{action: action_name} = action),
    do: {:ok, action |> stringify_action_keys() |> Map.put("action", to_string(action_name))}

  defp normalize_action(%{"submit" => result}),
    do: {:ok, %{"action" => "submit", "result" => result}}

  defp normalize_action(%{submit: result}), do: {:ok, %{"action" => "submit", "result" => result}}

  defp normalize_action(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, action} when is_map(action) -> normalize_action(action)
      _ -> {:error, {:invalid_rlm_action, text}}
    end
  end

  defp normalize_action(other), do: {:error, {:invalid_rlm_action, other}}

  defp stringify_action_keys(action) do
    Map.new(action, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp step(rlm, %{"action" => "submit", "result" => result}, state, iteration)
       when is_map(result) do
    case resolve_adapter(rlm).parse(rlm.signature, result, []) do
      {:ok, prediction} ->
        state = trace(state, iteration, :submit, result, :done)
        {:done, prediction, state}

      {:error, reason} ->
        {:error, {:invalid_rlm_submit, reason}}
    end
  end

  defp step(rlm, %{"action" => "eval", "code" => code}, state, iteration) when is_binary(code) do
    observation =
      code
      |> DSEx.Sandbox.eval(state.vars)
      |> truncate_observation(rlm.max_observation_chars)

    state = add_observation(state, %{action: :eval, code: code, result: observation})
    {:cont, trace(state, iteration, :eval, code, observation)}
  end

  defp step(_rlm, %{"action" => "assign", "name" => name, "value" => value}, state, iteration)
       when is_binary(name) do
    key = existing_atom_or_string(name)
    state = %{state | vars: Map.put(state.vars, key, value)}
    state = add_observation(state, %{action: :assign, name: key, value: value})
    {:cont, trace(state, iteration, :assign, %{name: key, value: value}, :ok)}
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "llm_query"} = action, state, iteration) do
    if state.llm_calls >= rlm.max_llm_calls do
      {:error, {:rlm_max_llm_calls, rlm.max_llm_calls, Enum.reverse(state.trace)}}
    else
      signature = Map.get(action, "signature", DSEx.Signature.to_spec(rlm.signature))
      inputs = Map.get(action, "inputs", %{})

      program =
        DSEx.Predict.Predict.new(signature,
          lm: resolve_sub_lm(rlm),
          adapter: resolve_adapter(rlm)
        )

      result = DSEx.Predict.Predict.call(program, inputs)

      state =
        state
        |> Map.update!(:llm_calls, &(&1 + 1))
        |> add_observation(%{
          action: :llm_query,
          signature: signature,
          inputs: inputs,
          result: result
        })
        |> trace(iteration, :llm_query, action, result)

      {:cont, state}
    end
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "tool"} = action, state, iteration) do
    name = normalize_tool_name(rlm.tools, Map.get(action, "name"))
    args = Map.get(action, "arguments", Map.get(action, "args", %{}))
    tool = if name, do: Map.get(rlm.tools, name)

    result =
      cond do
        is_nil(tool) -> {:error, :unknown_tool}
        not authorized_tool?(rlm.tool_policy, name, args) -> {:error, {:tool_denied, name}}
        true -> DSEx.Tool.call(tool, args)
      end

    state =
      state
      |> add_observation(%{action: :tool, name: name, arguments: args, result: result})
      |> trace(iteration, :tool, action, result)

    case result do
      {:error, {:tool_denied, _name}} -> result
      _other -> {:cont, state}
    end
  end

  defp step(_rlm, action, _state, _iteration), do: {:error, {:unsupported_rlm_action, action}}

  defp add_observation(state, observation),
    do: Map.update!(state, :observations, &[observation | &1])

  defp trace(state, iteration, action, input, output) do
    event = %{iteration: iteration, action: action, input: input, output: output}
    Map.update!(state, :trace, &[event | &1])
  end

  defp add_trace(%DSEx.Prediction{} = prediction, state) do
    metadata = Map.put(prediction.metadata, :rlm_trace, Enum.reverse(state.trace))
    %{prediction | metadata: metadata}
  end

  defp variable_metadata(vars, preview_chars) do
    Map.new(vars, fn {key, value} -> {key, describe_value(value, preview_chars)} end)
  end

  defp describe_value(value, preview_chars) when is_binary(value) do
    %{
      type: :string,
      length: String.length(value),
      preview: String.slice(value, 0, preview_chars),
      truncated: String.length(value) > preview_chars
    }
  end

  defp describe_value(value, preview_chars) when is_list(value) do
    %{
      type: :list,
      length: length(value),
      preview: Enum.take(value, preview_chars),
      truncated: length(value) > preview_chars
    }
  end

  defp describe_value(value, _preview_chars) when is_map(value),
    do: %{type: :map, keys: Map.keys(value), size: map_size(value)}

  defp describe_value(value, _preview_chars), do: %{type: type_of(value), value: value}

  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :float
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(value) when is_nil(value), do: nil
  defp type_of(_value), do: :term

  defp truncate_observation({:ok, value}, max_chars) when is_binary(value) do
    {:ok,
     %{
       value: String.slice(value, 0, max_chars),
       truncated: String.length(value) > max_chars
     }}
  end

  defp truncate_observation(observation, _max_chars), do: observation

  defp tool_metadata(tools) do
    tools
    |> Map.values()
    |> Enum.map(&%{name: &1.name, description: &1.description, schema: &1.schema})
  end

  defp coerce_tool(%DSEx.Tool{} = tool), do: tool

  defp normalize_tool_name(tools, name) do
    Enum.find_value(Map.keys(tools), fn known ->
      if to_string(known) == to_string(name), do: known
    end)
  end

  defp authorized_tool?(:allow, _name, _args), do: true
  defp authorized_tool?(allowed, name, _args) when is_list(allowed), do: name in allowed

  defp authorized_tool?(policy, name, args) when is_function(policy, 2) do
    case policy.(name, args) do
      true -> true
      :ok -> true
      _other -> false
    end
  end

  defp authorized_tool?(policy, name, _args), do: name in List.wrap(policy)

  defp check_time_budget(%__MODULE__{max_time_ms: nil}, _state), do: :ok

  defp check_time_budget(%__MODULE__{} = rlm, state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    if elapsed <= rlm.max_time_ms,
      do: :ok,
      else: {:error, {:rlm_max_time_ms, rlm.max_time_ms, Enum.reverse(state.trace)}}
  end

  defp remaining_time(%__MODULE__{max_time_ms: nil}, _state), do: nil

  defp remaining_time(%__MODULE__{} = rlm, state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at
    max(rlm.max_time_ms - elapsed, 0)
  end

  defp resolve_lm(%__MODULE__{dynamic_lm?: true}), do: DSEx.Settings.get().lm
  defp resolve_lm(%__MODULE__{lm: lm}), do: lm

  defp resolve_sub_lm(%__MODULE__{dynamic_sub_lm?: true}), do: DSEx.Settings.get().lm
  defp resolve_sub_lm(%__MODULE__{sub_lm: nil} = rlm), do: resolve_lm(rlm)
  defp resolve_sub_lm(%__MODULE__{sub_lm: lm}), do: lm

  defp resolve_adapter(%__MODULE__{dynamic_adapter?: true}), do: DSEx.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: nil}), do: DSEx.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: adapter}), do: adapter

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp safe_json(value) do
    Jason.encode!(value)
    value
  rescue
    Protocol.UndefinedError -> inspect(value)
    ArgumentError -> inspect(value)
  end
end
