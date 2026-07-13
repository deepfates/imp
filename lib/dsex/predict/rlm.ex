defmodule DSEx.Predict.RLM do
  @moduledoc """
  Recursive Language Model module.

  RLM is not retrieval-augmented generation. It is an inference-time strategy
  for large or awkward contexts: inputs are exposed as variables in a
  persistent constrained-Elixir environment, and a controller LM iteratively
  writes code until that code submits structured output.

  This implementation uses a BEAM-safe sandbox for production control.
  The primary controller response is `%{reasoning: "...", code: "..."}`. Safe
  code supports persistent assignment, bounded comprehensions and
  transformations, `llm_query/1`, `llm_query_batched/1`, `recurse/2`,
  `load/1`, registered tools, `print/1`, and `submit/1`. Legacy discrete action
  maps remain accepted as compatibility shims.

  A shared atomic ledger enforces `max_iterations`, `max_llm_calls`,
  `max_recursion_depth`, and `max_time_ms` across recursive children. Generated
  source is parsed but never evaluated by `Code.eval_*`; only an explicit AST
  allowlist executes, with atom-safe parsing and an interpreter step budget.

  Tool execution is policy-gated. Unknown, denied, crashing, or policy-crashing
  tool actions return `{:error, {:rlm_tool_error, reason, trace}}` with the
  redacted trajectory accumulated so far.
  """

  @behaviour DSEx.Module

  alias DSEx.Predict.RLM.{Budget, Interpreter, Runtime, Trace}
  alias DSEx.Predict.RLM.Interpreter.Effect

  @task_process_keys [
    :"$ancestors",
    :"$callers",
    :"$initial_call",
    :dsex_context_stack,
    :dsex_settings_snapshot
  ]

  defstruct [
    :signature,
    :lm,
    :adapter,
    :sub_lm,
    tools: %{},
    tool_policy: :allow,
    max_iterations: 20,
    max_llm_calls: 50,
    max_recursion_depth: 1,
    max_interpreter_steps: 10_000,
    max_interpreter_value_bytes: 16_000_000,
    max_interpreter_effects: 100,
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
  - `:max_iterations` / `:max_iters`, `:max_llm_calls`, `:max_time_ms` - execution budgets.
  - `:max_recursion_depth` - maximum symbolic child depth; defaults to `1`.
  - `:max_interpreter_steps` - AST execution steps per controller turn.
  - `:max_interpreter_value_bytes` - maximum serialized size of an interpreter value.
  - `:max_interpreter_effects` - external effects allowed per controller turn.
  - `:max_preview_chars` - how much large input context the controller sees.
  - `:max_observation_chars` - truncation limit for string observations.
  """
  @option_schema [
    lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    adapter: [type: {:custom, DSEx.Adapter, :validate_adapter, []}],
    sub_lm: [type: {:custom, DSEx.LM, :validate_lm, []}],
    tools: [type: {:custom, DSEx.Tool, :validate_tools, []}, default: []],
    tool_policy: [
      type: {:custom, DSEx.ToolPolicy, :validate, []},
      default: :allow
    ],
    max_iterations: [type: :non_neg_integer, default: 20],
    max_iters: [type: :non_neg_integer],
    max_llm_calls: [type: :non_neg_integer, default: 50],
    max_recursion_depth: [type: :non_neg_integer, default: 1],
    max_interpreter_steps: [type: :pos_integer, default: 10_000],
    max_interpreter_value_bytes: [type: :pos_integer, default: 16_000_000],
    max_interpreter_effects: [type: :pos_integer, default: 100],
    max_time_ms: [type: :non_neg_integer],
    max_preview_chars: [type: :non_neg_integer, default: 2_000],
    max_observation_chars: [type: :non_neg_integer, default: 10_000],
    max_output_chars: [type: :non_neg_integer]
  ]

  def new(signature, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.RLM.new/2")
    tools = DSEx.Tool.index_tools!(opts[:tools], "DSEx.Predict.RLM.new/2")

    %__MODULE__{
      signature: signature,
      lm: opts[:lm],
      adapter: opts[:adapter],
      sub_lm: Keyword.get(opts, :sub_lm, opts[:lm]),
      tools: tools,
      tool_policy: opts[:tool_policy],
      max_iterations: non_negative_integer(Keyword.get(opts, :max_iters, opts[:max_iterations])),
      max_llm_calls: non_negative_integer(opts[:max_llm_calls]),
      max_recursion_depth: non_negative_integer(opts[:max_recursion_depth]),
      max_interpreter_steps: opts[:max_interpreter_steps],
      max_interpreter_value_bytes: opts[:max_interpreter_value_bytes],
      max_interpreter_effects: opts[:max_interpreter_effects],
      max_time_ms: non_negative_integer_or_nil(opts[:max_time_ms]),
      max_preview_chars: non_negative_integer(opts[:max_preview_chars]),
      max_observation_chars:
        non_negative_integer(Keyword.get(opts, :max_output_chars, opts[:max_observation_chars])),
      dynamic_lm?: not Keyword.has_key?(opts, :lm),
      dynamic_sub_lm?: not Keyword.has_key?(opts, :sub_lm) and not Keyword.has_key?(opts, :lm),
      dynamic_adapter?: not Keyword.has_key?(opts, :adapter)
    }
  end

  @doc "Creates a lazy value handle that an RLM controller can load explicitly."
  def sandbox_serializable(name, loader, opts \\ []),
    do: DSEx.Predict.RLM.SandboxSerializable.new(name, loader, opts)

  @doc false
  def internal_predictors(%__MODULE__{} = rlm) do
    %{
      action: controller_predictor(rlm),
      extract: extract_predictor(rlm),
      subquery: subquery_predictor(rlm)
    }
  end

  @impl true
  @doc """
  Runs the RLM loop.

  The controller LM returns actions such as `eval`, `assign`, `tool`,
  `llm_query`, and `submit`. A successful submit returns a `DSEx.Prediction`
  with `:rlm_trace` metadata.
  """
  def call(%__MODULE__{} = rlm, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, vars} <- normalize_inputs(inputs),
         :ok <- validate_required_inputs(rlm.signature, vars),
         {:ok, budget} <-
           Budget.start_link(
             max_lm_calls: rlm.max_llm_calls,
             max_time_ms: rlm.max_time_ms,
             max_recursion_depth: rlm.max_recursion_depth
           ) do
      try do
        call_with_budget(rlm, vars, budget)
      after
        if Process.alive?(budget), do: GenServer.stop(budget, :normal)
      end
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_rlm_inputs,
        "expected a map or keyword/list of input pairs, got: #{inspect(inputs)}"}}

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_rlm_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp validate_required_inputs(signature, inputs) do
    missing =
      signature.inputs
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(& &1.name)
      |> Enum.reject(&input_present?(inputs, &1))

    if missing == [], do: :ok, else: {:error, {:missing_input_fields, missing}}
  end

  defp input_present?(inputs, name),
    do: Map.has_key?(inputs, name) or Map.has_key?(inputs, to_string(name))

  defp call_with_budget(%__MODULE__{} = rlm, vars, budget, depth \\ 0) do
    runtime = Runtime.new(rlm, budget, vars, depth)

    interpreter =
      Interpreter.new(vars, interpreter_callbacks(rlm), runtime,
        max_steps: rlm.max_interpreter_steps,
        max_output_chars: rlm.max_observation_chars,
        max_value_bytes: rlm.max_interpreter_value_bytes,
        max_effects: rlm.max_interpreter_effects
      )

    state = %{
      vars: vars,
      interpreter: interpreter,
      budget: budget,
      depth: depth,
      observations: [],
      trace: [],
      trace_limit: rlm.max_observation_chars,
      llm_calls: Budget.snapshot(budget).lm_calls,
      started_at: System.monotonic_time(:millisecond)
    }

    run_loop(rlm, state, 1)
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration)
       when iteration > rlm.max_iterations and rlm.max_iterations == 0 do
    {:error, {:rlm_max_iterations, rlm.max_iterations, Enum.reverse(state.trace)}}
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration)
       when iteration > rlm.max_iterations do
    extract_fallback(rlm, state, iteration)
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

      {:error, :rlm_time_budget_exceeded} ->
        {:error, {:rlm_max_time_ms, rlm.max_time_ms, Enum.reverse(state.trace)}}

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
        content:
          "You are an RLM controller with a persistent, constrained Elixir environment. Follow the task instructions exactly and return JSON with reasoning and code. Code may inspect and assign variables, use for comprehensions, call llm_query(prompt), llm_query_batched(prompts), recurse(signature, inputs), load(name), registered tools, print(value), and submit(a_map_with_the_required_output_fields). State persists across turns. Explore and compute in code; submit only when every required signature output is ready."
      },
      %{
        role: :user,
        content:
          Jason.encode!(%{
            signature: DSEx.Signature.to_spec(rlm.signature),
            task_instructions: rlm.signature.instructions,
            required_outputs: DSEx.Signature.output_names(rlm.signature),
            iteration: iteration,
            variables: variable_metadata(state.interpreter.vars, rlm.max_preview_chars),
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

    run_budgeted(state.budget, fn -> DSEx.LM.generate(lm, messages, []) end)
  end

  defp normalize_action(%{"code" => code} = action)
       when is_binary(code) and not is_map_key(action, "action") do
    {:ok,
     %{
       "action" => "run",
       "code" => code,
       "reasoning" => Map.get(action, "reasoning", "")
     }}
  end

  defp normalize_action(%{"action" => "submit", "result" => result}),
    do: {:ok, %{"action" => "submit", "result" => result}}

  defp normalize_action(%{"action" => "submit"} = action),
    do: {:ok, %{"action" => "submit", "result" => Map.delete(action, "action")}}

  defp normalize_action(%{"action" => _action} = action), do: {:ok, action}

  defp normalize_action(%{action: action_name} = action),
    do:
      action
      |> stringify_action_keys()
      |> Map.put("action", to_string(action_name))
      |> normalize_action()

  defp normalize_action(%{code: code} = action)
       when is_binary(code) and not is_map_key(action, :action),
       do: action |> stringify_action_keys() |> normalize_action()

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

  defp step(%__MODULE__{} = rlm, %{"action" => "run", "code" => code} = action, state, iteration)
       when is_binary(code) do
    reasoning = Map.get(action, "reasoning", "")

    {execution, state} =
      drive_interpreter(rlm, state, Interpreter.execute(state.interpreter, code))

    case execution do
      {:ok, value, interpreter} ->
        output = interpreter_output(interpreter, value, rlm.max_observation_chars)

        state =
          state
          |> sync_interpreter(interpreter)
          |> add_observation(%{reasoning: reasoning, code: code, output: output})
          |> trace(iteration, :run, %{reasoning: reasoning, code: code}, output)

        {:cont, state}

      {:final, result, interpreter} ->
        case resolve_adapter(rlm).parse(rlm.signature, result, []) do
          {:ok, prediction} ->
            state = sync_interpreter(state, Interpreter.commit(interpreter))
            state = trace(state, iteration, :submit, %{reasoning: reasoning, code: code}, result)
            {:done, prediction, state}

          {:error, reason} ->
            output = {:submit_error, reason}

            state =
              state
              |> sync_interpreter(interpreter)
              |> add_observation(%{reasoning: reasoning, code: code, output: output})
              |> trace(iteration, :submit_error, %{reasoning: reasoning, code: code}, output)

            {:cont, state}
        end

      {:error, reason, interpreter} ->
        state = sync_interpreter(state, interpreter)

        if budget_error?(reason) do
          {:error, attach_rlm_trace(reason, state)}
        else
          output = {:error, reason}

          state =
            state
            |> add_observation(%{reasoning: reasoning, code: code, output: output})
            |> trace(iteration, :run_error, %{reasoning: reasoning, code: code}, output)

          {:cont, state}
        end
    end
  end

  defp step(rlm, %{"action" => "submit", "result" => result}, state, iteration)
       when is_map(result) do
    case resolve_adapter(rlm).parse(rlm.signature, result, []) do
      {:ok, prediction} ->
        state = trace(state, iteration, :submit, result, :done)
        {:done, prediction, state}

      {:error, reason} ->
        state =
          state
          |> add_observation(%{action: :submit, result: result, error: inspect(reason)})
          |> trace(iteration, :submit_error, result, {:error, reason})

        {:cont, state}
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

  defp step(rlm, %{"action" => "load", "name" => name}, state, iteration)
       when is_binary(name) do
    key = find_var_key(state.vars, name)

    case Map.fetch(state.vars, key) do
      {:ok, %DSEx.Predict.RLM.SandboxSerializable{} = serializable} ->
        case run_budgeted(state.budget, fn ->
               DSEx.Predict.RLM.SandboxSerializable.load(serializable)
             end) do
          {:ok, loaded} ->
            state = put_state_var(state, key, loaded)

            observation = %{
              action: :load,
              name: key,
              result: describe_value(loaded, rlm.max_preview_chars)
            }

            {:cont,
             state
             |> add_observation(observation)
             |> trace(iteration, :load, %{name: key}, observation.result)}

          {:error, reason} ->
            observation = %{action: :load, name: key, error: reason}

            {:cont,
             state
             |> add_observation(observation)
             |> trace(iteration, :load_error, %{name: key}, {:error, reason})}
        end

      {:ok, loaded} ->
        observation = %{
          action: :load,
          name: key,
          result: describe_value(loaded, rlm.max_preview_chars)
        }

        {:cont,
         state
         |> add_observation(observation)
         |> trace(iteration, :load, %{name: key}, observation.result)}

      :error ->
        observation = %{action: :load, name: key, error: {:unknown_variable, key}}

        {:cont,
         state
         |> add_observation(observation)
         |> trace(iteration, :load_error, %{name: key}, {:error, {:unknown_variable, key}})}
    end
  end

  defp step(_rlm, %{"action" => "assign", "name" => name, "value" => value}, state, iteration)
       when is_binary(name) do
    key = existing_atom_or_string(name)
    state = put_state_var(state, key, value)
    state = add_observation(state, %{action: :assign, name: key, value: value})
    {:cont, trace(state, iteration, :assign, %{name: key, value: value}, :ok)}
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "llm_query"} = action, state, iteration) do
    case Budget.reserve_lm(state.budget, 1) do
      {:ok, _used} ->
        signature = Map.get(action, "signature", DSEx.Signature.to_spec(rlm.signature))
        inputs = Map.get(action, "inputs", %{})

        program =
          DSEx.Predict.Predict.new(signature,
            lm: resolve_sub_lm(rlm),
            adapter: resolve_adapter(rlm)
          )

        result =
          run_budgeted(state.budget, fn -> DSEx.Predict.Predict.call(program, inputs) end)

        state =
          state
          |> sync_budget_usage()
          |> add_observation(%{
            action: :llm_query,
            signature: signature,
            inputs: inputs,
            result: result
          })
          |> trace(iteration, :llm_query, action, result)

        {:cont, state}

      {:error, {:rlm_max_llm_calls, max}} ->
        {:error, {:rlm_max_llm_calls, max, Enum.reverse(state.trace)}}

      {:error, reason} ->
        {:error, attach_rlm_trace(reason, state)}
    end
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "llm_query_batched"} = action, state, iteration) do
    with {:ok, inputs_list} <- batched_inputs(action) do
      case run_leased_batch(state.budget, inputs_list, fn input ->
             DSEx.Predict.Predict.call(
               DSEx.Predict.Predict.new(
                 Map.get(action, "signature", DSEx.Signature.to_spec(rlm.signature)),
                 lm: resolve_sub_lm(rlm),
                 adapter: resolve_adapter(rlm)
               ),
               input
             )
           end) do
        {:ok, results} ->
          signature = Map.get(action, "signature", DSEx.Signature.to_spec(rlm.signature))

          state =
            state
            |> sync_budget_usage()
            |> add_observation(%{
              action: :llm_query_batched,
              signature: signature,
              inputs: inputs_list,
              result: results
            })
            |> trace(iteration, :llm_query_batched, action, results)

          {:cont, state}

        {:error, {:rlm_max_llm_calls, max}} ->
          {:error, {:rlm_max_llm_calls, max, Enum.reverse(state.trace)}}

        {:error, reason} ->
          {:error, attach_rlm_trace(reason, state)}
      end
    end
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "tool"} = action, state, iteration) do
    requested_name = Map.get(action, "name")
    name = normalize_tool_name(rlm.tools, requested_name)
    args = action |> Map.get("arguments", Map.get(action, "args", %{})) |> normalize_tool_args()

    result =
      run_budgeted(state.budget, fn -> execute_tool_call(rlm, name, requested_name, args) end)

    state =
      state
      |> add_observation(%{action: :tool, name: name, arguments: args, result: result})
      |> trace(iteration, :tool, action, result)

    case result do
      {:error, reason} -> {:error, {:rlm_tool_error, reason, Enum.reverse(state.trace)}}
      _other -> {:cont, state}
    end
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "recurse"} = action, state, iteration) do
    signature = Map.get(action, "signature", DSEx.Signature.to_spec(rlm.signature))
    inputs = Map.get(action, "inputs", state.vars)

    with true <- is_map(inputs),
         {:ok, child_signature} <- safe_signature(signature),
         {:ok, depth} <- Budget.enter_recursion(state.budget, state.depth) do
      child = %{
        rlm
        | signature: child_signature,
          max_iterations: max(rlm.max_iterations - iteration, 1)
      }

      result = call_with_budget(child, inputs, state.budget, depth)

      state =
        state
        |> sync_budget_usage()
        |> add_observation(%{
          action: :recurse,
          signature: signature,
          inputs: inputs,
          result: result
        })
        |> trace(iteration, :recurse, action, result)

      {:cont, state}
    else
      false -> {:error, {:invalid_rlm_recurse, {:inputs_must_be_a_map, inputs}}}
      {:error, reason} -> {:error, {:invalid_rlm_recurse, reason}}
    end
  end

  defp step(_rlm, action, _state, _iteration), do: {:error, {:unsupported_rlm_action, action}}

  defp interpreter_callbacks(%__MODULE__{} = rlm) do
    builtins = %{
      "llm_query" => :llm_query,
      "llm_query_batched" => :llm_query_batched,
      "recurse" => :recurse,
      "load" => :load
    }

    Enum.reduce(rlm.tools, builtins, fn {name, _tool}, callbacks ->
      Map.put(callbacks, to_string(name), {:tool, name})
    end)
  end

  defp drive_interpreter(rlm, state, {:effect, request, continuation}) do
    {result, state} = execute_interpreter_effect(rlm, state, request)

    continuation = %{
      continuation
      | interpreter: %{
          continuation.interpreter
          | runtime: state.interpreter.runtime,
            vars: state.interpreter.vars
        }
    }

    drive_interpreter(rlm, state, Interpreter.resume(continuation, result))
  end

  defp drive_interpreter(_rlm, state, result), do: {result, state}

  defp execute_interpreter_effect(_rlm, state, request) do
    runtime = state.interpreter.runtime

    result =
      case request do
        %Effect{kind: :llm_query, arguments: args} ->
          interpreter_llm_query(args, runtime)

        %Effect{kind: :llm_query_batched, arguments: args} ->
          interpreter_llm_query_batched(args, runtime)

        %Effect{kind: :recurse, arguments: args} ->
          interpreter_recurse(args, runtime)

        %Effect{kind: :load, arguments: args} ->
          interpreter_load(args, runtime)

        %Effect{kind: {:tool, name}, arguments: args} ->
          interpreter_tool(name, args, runtime)

        _other ->
          {:error, {:unknown_rlm_effect, request}, runtime}
      end

    case result do
      {:ok, value, runtime} ->
        state = put_interpreter_runtime(state, runtime)
        {{:ok, value}, sync_budget_usage(state)}

      {:error, reason, runtime} ->
        state = put_interpreter_runtime(state, runtime)
        {{:error, reason}, sync_budget_usage(state)}
    end
  rescue
    error ->
      reason = {:rlm_effect_exception, request.kind, Exception.message(error)}
      {{:error, reason}, sync_budget_usage(state)}
  catch
    kind, reason ->
      error = {:rlm_effect_throw, request.kind, {kind, reason}}
      {{:error, error}, sync_budget_usage(state)}
  end

  defp interpreter_llm_query([prompt], %{budget: budget, rlm: rlm} = runtime)
       when is_binary(prompt) do
    with {:ok, _used} <- Budget.reserve_lm(budget, 1),
         :ok <- Budget.check(budget),
         {:ok, raw} <- run_budgeted(budget, fn -> query_sub_lm(rlm, prompt) end) do
      {:ok, subquery_value(raw), runtime}
    else
      {:error, reason} -> {:error, reason, runtime}
    end
  end

  defp interpreter_llm_query(args, runtime),
    do: {:error, {:invalid_llm_query_arguments, args}, runtime}

  defp interpreter_llm_query_batched([prompts], %{budget: budget, rlm: rlm} = runtime)
       when is_list(prompts) do
    with true <- Enum.all?(prompts, &(is_binary(&1) and &1 != "")),
         {:ok, results} <- run_leased_batch(budget, prompts, &query_sub_lm(rlm, &1)) do
      normalized =
        Enum.map(results, fn
          {:ok, value} -> subquery_value(value)
          {:error, reason} -> {:error, reason}
        end)

      {:ok, normalized, runtime}
    else
      false -> {:error, {:invalid_llm_query_batched_arguments, prompts}, runtime}
      {:error, reason} -> {:error, reason, runtime}
    end
  end

  defp interpreter_llm_query_batched(args, runtime),
    do: {:error, {:invalid_llm_query_batched_arguments, args}, runtime}

  defp interpreter_recurse(
         [signature, inputs],
         %{budget: budget, rlm: rlm, depth: parent_depth} = runtime
       )
       when (is_binary(signature) or is_struct(signature, DSEx.Signature)) and is_map(inputs) do
    with {:ok, child_signature} <- safe_signature(signature),
         {:ok, depth} <- Budget.enter_recursion(budget, parent_depth) do
      child = %{rlm | signature: child_signature}

      case call_with_budget(child, inputs, budget, depth) do
        {:ok, prediction} -> {:ok, DSEx.Prediction.to_map(prediction), runtime}
        {:error, reason} -> {:error, reason, runtime}
      end
    else
      {:error, reason} -> {:error, reason, runtime}
    end
  end

  defp interpreter_recurse(args, runtime),
    do: {:error, {:invalid_recurse_arguments, args}, runtime}

  defp interpreter_load([name], %{inputs: inputs} = runtime)
       when is_atom(name) or is_binary(name) do
    key = find_var_key(inputs, to_string(name))

    case Map.fetch(inputs, key) do
      {:ok, %DSEx.Predict.RLM.SandboxSerializable{} = serializable} ->
        case run_budgeted(runtime.budget, fn ->
               DSEx.Predict.RLM.SandboxSerializable.load(serializable)
             end) do
          {:ok, value} -> {:ok, value, Runtime.put_input(runtime, key, value)}
          {:error, reason} -> {:error, {:sandbox_load_failed, name, reason}, runtime}
        end

      {:ok, value} ->
        {:ok, value, runtime}

      :error ->
        {:error, {:unknown_variable, name}, runtime}
    end
  end

  defp interpreter_load(args, runtime), do: {:error, {:invalid_load_arguments, args}, runtime}

  defp interpreter_tool(name, [args], %{rlm: rlm} = runtime) when is_map(args) do
    case run_budgeted(runtime.budget, fn -> execute_tool_call(rlm, name, name, args) end) do
      {:error, reason} -> {:error, {:rlm_tool_error, reason}, runtime}
      value -> {:ok, value, runtime}
    end
  end

  defp interpreter_tool(name, args, runtime),
    do: {:error, {:invalid_tool_arguments, name, args}, runtime}

  defp query_sub_lm(%__MODULE__{} = rlm, prompt) do
    case resolve_sub_lm(rlm) do
      nil -> {:error, :rlm_requires_sub_lm}
      lm -> DSEx.LM.generate(lm, [%{role: :user, content: prompt}], [])
    end
  end

  defp run_budgeted(budget, fun) when is_function(fun, 0) do
    with :ok <- Budget.check(budget) do
      {task, result_ref, inherited_keys} = start_budgeted_effect(fun)

      case Budget.register_effect(budget, task.pid) do
        :ok ->
          await_budgeted_effect(budget, task, result_ref, inherited_keys)

        {:error, reason} ->
          DSEx.Tasks.cancel(task, 1_000)
          {:error, reason}
      end
    end
  end

  defp start_budgeted_effect(fun) do
    inherited_dictionary = effect_process_dictionary()
    result_ref = make_ref()

    task =
      DSEx.Tasks.async_nolink(fn ->
        put_effect_process_dictionary(inherited_dictionary)
        result = fun.()
        {result_ref, result, effect_process_dictionary()}
      end)

    {task, result_ref, Map.keys(inherited_dictionary)}
  end

  defp await_budgeted_effect(budget, task, result_ref, inherited_keys) do
    case Task.yield(task, interpreter_timeout(budget)) do
      {:ok, {^result_ref, result, effect_dictionary}} ->
        sync_effect_process_dictionary(inherited_keys, effect_dictionary)
        result

      {:exit, reason} ->
        {:error, {:rlm_effect_exit, reason}}

      nil ->
        DSEx.Tasks.cancel(task, 1_000)
        {:error, :rlm_time_budget_exceeded}
    end
  after
    if Process.alive?(budget), do: Budget.unregister_effect(budget, task.pid)
  end

  defp effect_process_dictionary do
    Process.get()
    |> Enum.reject(fn {key, _value} -> key in @task_process_keys end)
    |> Map.new()
  end

  defp put_effect_process_dictionary(dictionary) do
    Enum.each(dictionary, fn {key, value} -> Process.put(key, value) end)
  end

  defp sync_effect_process_dictionary(inherited_keys, effect_dictionary) do
    Enum.each(inherited_keys, &Process.delete/1)
    put_effect_process_dictionary(effect_dictionary)
  end

  defp run_leased_batch(budget, items, fun) do
    with {:ok, lease} <- Budget.lease_lm(budget, length(items)) do
      try do
        run_budgeted(budget, fn ->
          results =
            items
            |> DSEx.Tasks.async_stream(
              fn item ->
                with :ok <- Budget.check(budget),
                     {:ok, _used} <- Budget.commit_lm(budget, lease) do
                  fun.(item)
                end
              end,
              ordered: true,
              max_concurrency: min(max(length(items), 1), 8),
              timeout: interpreter_timeout(budget),
              on_timeout: :kill_task
            )
            |> Enum.map(fn
              {:ok, result} -> result
              {:exit, reason} -> {:error, {:batched_llm_query_exit, reason}}
            end)

          {:ok, results}
        end)
      after
        if Process.alive?(budget), do: Budget.release_lm(budget, lease)
      end
    end
  end

  defp subquery_value(%DSEx.Prediction{} = prediction), do: DSEx.Prediction.to_map(prediction)
  defp subquery_value(value), do: value

  defp interpreter_timeout(budget) do
    case Budget.snapshot(budget).remaining_time_ms do
      nil -> 120_000
      0 -> 1
      remaining -> remaining
    end
  end

  defp sync_interpreter(state, interpreter) do
    calls = Budget.snapshot(state.budget).lm_calls

    runtime = %{
      interpreter.runtime
      | inputs: Map.merge(interpreter.runtime.inputs, interpreter.vars)
    }

    interpreter = %{interpreter | runtime: runtime}
    %{state | interpreter: interpreter, vars: interpreter.vars, llm_calls: calls}
  end

  defp put_interpreter_runtime(state, runtime) do
    previous_inputs = state.interpreter.runtime.inputs

    vars =
      Enum.reduce(runtime.inputs, state.interpreter.vars, fn {key, value}, vars ->
        case Map.fetch(previous_inputs, key) do
          {:ok, ^value} -> vars
          _other -> Map.put(vars, key, value)
        end
      end)

    %{state | interpreter: %{state.interpreter | runtime: runtime, vars: vars}, vars: vars}
  end

  defp sync_budget_usage(state) do
    %{state | llm_calls: Budget.snapshot(state.budget).lm_calls}
  end

  defp put_state_var(state, key, value) do
    runtime = Runtime.put_input(state.interpreter.runtime, key, value)

    interpreter = %{
      state.interpreter
      | vars: Map.put(state.interpreter.vars, key, value),
        runtime: runtime
    }

    %{state | vars: Map.put(state.vars, key, value), interpreter: interpreter}
  end

  defp interpreter_output(interpreter, value, max_chars) do
    rendered = if interpreter.output == "", do: inspect(value), else: interpreter.output
    length = String.length(rendered)

    if length <= max_chars do
      rendered
    else
      half = div(max(max_chars - 40, 0), 2)

      %{
        head: String.slice(rendered, 0, half),
        tail: String.slice(rendered, max(length - half, 0), half),
        length: length,
        truncated: true
      }
    end
  end

  defp budget_error?({:rlm_cancelled, _reason}), do: true
  defp budget_error?(:rlm_time_budget_exceeded), do: true
  defp budget_error?(_reason), do: false

  defp attach_rlm_trace(reason, state), do: {reason, Enum.reverse(state.trace)}

  defp batched_inputs(action) do
    inputs =
      Map.get(action, "inputs", Map.get(action, "batch", Map.get(action, "inputs_list", [])))

    cond do
      is_list(inputs) and Enum.all?(inputs, &is_map/1) ->
        {:ok, inputs}

      is_map(inputs) ->
        {:ok, Map.values(inputs)}

      true ->
        {:error, {:invalid_rlm_batched_inputs, inputs}}
    end
  end

  defp extract_fallback(%__MODULE__{} = rlm, state, iteration) do
    case resolve_lm(rlm) do
      nil ->
        {:error, {:rlm_max_iterations, rlm.max_iterations, Enum.reverse(state.trace)}}

      lm ->
        extract_fallback_with_lm(rlm, lm, state, iteration)
    end
  end

  defp extract_fallback_with_lm(%__MODULE__{} = rlm, lm, state, iteration) do
    messages = [
      %{
        role: :system,
        content:
          "You are the RLM extract pass. Return only the final structured output for the signature, not another action."
      },
      %{
        role: :user,
        content:
          Jason.encode!(%{
            signature: DSEx.Signature.to_spec(rlm.signature),
            exhausted_at_iteration: iteration,
            variables: variable_metadata(state.vars, rlm.max_preview_chars),
            observations: Enum.map(state.observations, &safe_json/1),
            trace: state.trace |> Enum.reverse() |> Enum.map(&safe_json/1)
          })
      }
    ]

    with {:ok, raw} <- run_budgeted(state.budget, fn -> DSEx.LM.generate(lm, messages, []) end),
         {:ok, prediction} <- resolve_adapter(rlm).parse(rlm.signature, raw, []) do
      state = trace(state, iteration, :extract, %{reason: :max_iterations}, raw)
      {:ok, add_trace(prediction, state)}
    else
      {:error, reason} ->
        {:error, {:rlm_extract_failed, reason, Enum.reverse(state.trace)}}
    end
  end

  defp add_observation(state, observation),
    do: Map.update!(state, :observations, &[trace_term(observation, state.trace_limit) | &1])

  defp trace(state, iteration, action, input, output) do
    event = %{
      iteration: iteration,
      action: action,
      input: trace_term(input, state.trace_limit),
      output: trace_term(output, state.trace_limit)
    }

    Map.update!(state, :trace, &[event | &1])
  end

  defp trace_term(value, limit) do
    Trace.compact(value, limit)
  end

  defp add_trace(%DSEx.Prediction{} = prediction, state) do
    trace = Enum.reverse(state.trace)
    trajectory = normalized_trajectory(trace)
    final_reasoning = trajectory |> List.last() |> then(&if(&1, do: &1.reasoning))

    metadata =
      prediction.metadata
      |> Map.put(:rlm_trace, trace)
      |> Map.put(:trajectory, trajectory)
      |> Map.put(:final_reasoning, final_reasoning)
      |> Map.put(:rlm, %{
        iterations: trace |> Enum.map(& &1.iteration) |> Enum.max(fn -> 0 end),
        sub_lm_calls: state.llm_calls,
        elapsed_ms: System.monotonic_time(:millisecond) - state.started_at
      })

    %{prediction | metadata: metadata}
  end

  defp normalized_trajectory(trace) do
    Enum.flat_map(trace, fn
      %{input: %{code: code} = input, output: output} when is_binary(code) ->
        [%{reasoning: Map.get(input, :reasoning, ""), code: code, output: output}]

      _event ->
        []
    end)
  end

  defp variable_metadata(vars, preview_chars) do
    Map.new(vars, fn {key, value} -> {key, describe_value(value, preview_chars)} end)
  end

  defp describe_value(%DSEx.Predict.RLM.SandboxSerializable{} = value, _preview_chars) do
    %{
      type: :sandbox_serializable,
      name: value.name,
      metadata: value.metadata,
      loaded: false
    }
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

  defp normalize_tool_name(tools, name), do: DSEx.Tool.resolve_name(tools, name)

  defp normalize_tool_args(args), do: DSEx.Tool.normalize_arguments(args)

  defp execute_tool_call(_rlm, nil, requested_name, _args),
    do: {:error, {:unknown_tool, requested_name}}

  defp execute_tool_call(rlm, name, _requested_name, args) do
    case authorize_tool(rlm.tool_policy, name, args) do
      :ok ->
        call_known_tool(Map.fetch!(rlm.tools, name), args)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_known_tool(tool, args) do
    DSEx.Tool.call(tool, args)
  rescue
    exception ->
      {:error, {:tool_error, tool.name, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(policy, name, args), do: DSEx.ToolPolicy.authorize(policy, name, args)

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

  defp controller_predictor(%__MODULE__{} = rlm) do
    signature =
      "signature, iteration, variables, observations, tools, budget -> action"
      |> DSEx.Signature.ensure()

    DSEx.Predict.Predict.new(signature, lm: resolve_lm(rlm), adapter: resolve_adapter(rlm))
  end

  defp extract_predictor(%__MODULE__{} = rlm) do
    signature =
      "signature, variables, observations, trace -> output"
      |> DSEx.Signature.ensure()

    DSEx.Predict.Predict.new(signature, lm: resolve_lm(rlm), adapter: resolve_adapter(rlm))
  end

  defp subquery_predictor(%__MODULE__{} = rlm) do
    DSEx.Predict.Predict.new(rlm.signature,
      lm: resolve_sub_lm(rlm),
      adapter: resolve_adapter(rlm)
    )
  end

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp safe_signature(signature) do
    {:ok, DSEx.Signature.ensure(signature)}
  rescue
    error -> {:error, {:invalid_signature, Exception.message(error)}}
  end

  defp find_var_key(vars, name) do
    atom_or_string = existing_atom_or_string(name)

    cond do
      Map.has_key?(vars, atom_or_string) -> atom_or_string
      Map.has_key?(vars, name) -> name
      true -> atom_or_string
    end
  end

  defp safe_json(value) do
    Jason.encode!(value)
    value
  rescue
    Protocol.UndefinedError -> inspect(value)
    ArgumentError -> inspect(value)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer_or_nil(nil), do: nil
  defp non_negative_integer_or_nil(value) when is_integer(value) and value >= 0, do: value
end
