defmodule DSPy.Predict.RLM do
  @moduledoc """
  Recursive Language Model module.

  RLM is not retrieval-augmented generation. It is an inference-time strategy
  for large or awkward contexts: inputs are exposed as sandbox variables and a
  controller LM iteratively chooses actions until it submits structured output.

  This BEAM implementation intentionally uses the local arithmetic sandbox
  instead of an arbitrary Python/Deno REPL. Supported controller actions are:

  - `%{action: "eval", code: "x + 1"}` to evaluate a safe expression.
  - `%{action: "llm_query", signature: "...", inputs: %{...}}` to call a sub-LM.
  - `%{action: "submit", result: %{...}}` to return signature outputs.

  The loop enforces `max_iterations` and `max_llm_calls` budgets and stores an
  interpretable trajectory in prediction metadata.
  """

  @behaviour DSPy.Module

  defstruct [
    :signature,
    :lm,
    :adapter,
    :sub_lm,
    tools: [],
    max_iterations: 10,
    max_llm_calls: 20
  ]

  def new(signature, opts \\ []) do
    signature = DSPy.Signature.ensure(signature)

    %__MODULE__{
      signature: signature,
      lm: Keyword.get(opts, :lm),
      adapter: Keyword.get(opts, :adapter, DSPy.Adapter.Chat),
      sub_lm: Keyword.get(opts, :sub_lm, Keyword.get(opts, :lm)),
      tools: Keyword.get(opts, :tools, []),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      max_llm_calls: Keyword.get(opts, :max_llm_calls, 20)
    }
  end

  @impl true
  def call(%__MODULE__{} = rlm, inputs) do
    state = %{
      vars: Map.new(inputs),
      observations: [],
      trace: [],
      llm_calls: 0
    }

    run_loop(rlm, state, 1)
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration)
       when iteration > rlm.max_iterations do
    {:error, {:rlm_max_iterations, rlm.max_iterations, Enum.reverse(state.trace)}}
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration) do
    with {:ok, raw_action} <- controller_action(rlm, state, iteration),
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

  defp controller_action(%__MODULE__{lm: nil}, _state, _iteration),
    do: {:error, :rlm_requires_controller_lm}

  defp controller_action(%__MODULE__{} = rlm, state, iteration) do
    messages = [
      %{
        role: :system,
        content: "You are an RLM controller. Return JSON with action eval, llm_query, or submit."
      },
      %{
        role: :user,
        content:
          Jason.encode!(%{
            signature: DSPy.Signature.to_spec(rlm.signature),
            iteration: iteration,
            variables: state.vars,
            observations: Enum.map(state.observations, &safe_json/1),
            remaining_llm_calls: rlm.max_llm_calls - state.llm_calls
          })
      }
    ]

    DSPy.LM.generate(rlm.lm, messages, [])
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
    case DSPy.Adapter.Chat.parse(rlm.signature, result, []) do
      {:ok, prediction} ->
        state = trace(state, iteration, :submit, result, :done)
        {:done, prediction, state}

      {:error, reason} ->
        {:error, {:invalid_rlm_submit, reason}}
    end
  end

  defp step(_rlm, %{"action" => "eval", "code" => code}, state, iteration) when is_binary(code) do
    observation = DSPy.Sandbox.eval(code, state.vars)
    state = add_observation(state, %{action: :eval, code: code, result: observation})
    {:cont, trace(state, iteration, :eval, code, observation)}
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "llm_query"} = action, state, iteration) do
    if state.llm_calls >= rlm.max_llm_calls do
      {:error, {:rlm_max_llm_calls, rlm.max_llm_calls, Enum.reverse(state.trace)}}
    else
      signature = Map.get(action, "signature", DSPy.Signature.to_spec(rlm.signature))
      inputs = Map.get(action, "inputs", %{})
      program = DSPy.Predict.Predict.new(signature, lm: rlm.sub_lm, adapter: rlm.adapter)
      result = DSPy.Predict.Predict.call(program, inputs)

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

  defp step(_rlm, action, _state, _iteration), do: {:error, {:unsupported_rlm_action, action}}

  defp add_observation(state, observation),
    do: Map.update!(state, :observations, &[observation | &1])

  defp trace(state, iteration, action, input, output) do
    event = %{iteration: iteration, action: action, input: input, output: output}
    Map.update!(state, :trace, &[event | &1])
  end

  defp add_trace(%DSPy.Prediction{} = prediction, state) do
    metadata = Map.put(prediction.metadata, :rlm_trace, Enum.reverse(state.trace))
    %{prediction | metadata: metadata}
  end

  defp safe_json(value) do
    Jason.encode!(value)
    value
  rescue
    Protocol.UndefinedError -> inspect(value)
    ArgumentError -> inspect(value)
  end
end
