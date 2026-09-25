defmodule Imp.Predict.RLM do
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
  `load/1`, registered tools, `print/1`, and `submit/1`.

  Controller iterations, recursion depth, and optional wall time are bounded
  separately. A shared `max_llm_calls` ledger covers only one-shot sub-LM work
  from `llm_query*`, depth-limit `rlm_query*` fallbacks, and sub-LM calls made
  inside recursive children. Root and child controller turns, extraction, and
  compaction generations are not charged. Generated source is parsed but never
  evaluated by `Code.eval_*`; only an explicit AST allowlist executes, with
  atom-safe parsing and an interpreter step budget.

  Tool execution is policy-gated. Denied, crashing, or policy-crashing
  registered-tool effects return `{:error, {:rlm_tool_error, reason}}` to the
  interpreter, which records the redacted failure and permits controller repair.
  """

  @behaviour Imp.Module

  alias Imp.Predict.RLM.{Action, Budget, Compaction, Interpreter, Runtime, Session, Trace}
  alias Imp.Predict.RLM.Interpreter.Effect

  @max_llm_calls_scope :subcalls_only

  @task_process_keys [
    :"$ancestors",
    :"$callers",
    :"$initial_call",
    :imp_context_stack,
    :imp_settings_snapshot
  ]

  defstruct [
    :signature,
    :lm,
    :adapter,
    :sub_lm,
    :model_override,
    tools: %{},
    tool_policy: :allow,
    max_iterations: 20,
    max_llm_calls: 50,
    max_recursion_depth: 1,
    max_interpreter_steps: 10_000,
    max_interpreter_value_bytes: 16_000_000,
    max_interpreter_effects: 100,
    max_concurrent_subcalls: 4,
    max_time_ms: nil,
    max_preview_chars: 2_000,
    max_observation_chars: 10_000,
    compaction: false,
    compaction_threshold_pct: 0.85,
    compaction_context_tokens: 128_000,
    persistent: false,
    session: nil,
    dynamic_lm?: true,
    dynamic_sub_lm?: true,
    dynamic_adapter?: true
  ]

  @doc """
  Creates an RLM controller loop.

  Options:

  - `:lm` - controller LM.
  - `:sub_lm` - LM used for `llm_query` calls; defaults to `:lm`.
  - `:tools` - list of `Imp.Tool` values available to tool calls.
  - `:tool_policy` - `:allow`, a list of allowed tool names, or a predicate.
  - `:max_iterations` / `:max_iters` - maximum controller turns.
  - `:max_llm_calls` - shared limit for one-shot sub-LM calls. This includes
    `llm_query*`, depth-limit `rlm_query*` fallbacks, and sub-LM work inside
    recursive children; it excludes controller, extraction, and compaction calls.
  - `:max_time_ms` - optional deadline for the complete RLM call. When omitted,
    RLM effects have no configured deadline.
  - `:max_recursion_depth` - maximum symbolic child depth; defaults to `1`.
  - `:max_interpreter_steps` - AST execution steps per controller turn.
  - `:max_interpreter_value_bytes` - maximum serialized size of an interpreter value.
  - `:max_interpreter_effects` - external effects allowed per controller turn.
  - `:max_preview_chars` - characters of each variable's printed value the controller sees each turn.
  - `:max_observation_chars` - truncation limit for string observations.
  - `:compaction` / `:compaction_threshold_pct` - summarize root history at a model-context fraction.
  - `:compaction_context_tokens` - context limit paired with the explicit chars/4 token-estimation fallback; Imp.LM currently exposes no standard tokenizer/context metadata.
  - `:persistent` - retain the constrained namespace across calls; release it with `close/1`.
  """
  @option_schema [
    lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    adapter: [type: {:custom, Imp.Adapter, :validate_adapter, []}],
    sub_lm: [type: {:custom, Imp.LM, :validate_lm, []}],
    tools: [type: {:custom, Imp.Tool, :validate_tools, []}, default: []],
    tool_policy: [
      type: {:custom, Imp.ToolPolicy, :validate, []},
      default: :allow
    ],
    max_iterations: [type: :non_neg_integer, default: 20],
    max_iters: [type: :non_neg_integer],
    max_llm_calls: [type: :non_neg_integer, default: 50],
    max_recursion_depth: [type: :non_neg_integer, default: 1],
    max_interpreter_steps: [type: :pos_integer, default: 10_000],
    max_interpreter_value_bytes: [type: :pos_integer, default: 16_000_000],
    max_interpreter_effects: [type: :pos_integer, default: 100],
    max_concurrent_subcalls: [type: :pos_integer, default: 4],
    max_time_ms: [type: :non_neg_integer],
    max_preview_chars: [type: :non_neg_integer, default: 2_000],
    max_observation_chars: [type: :non_neg_integer, default: 10_000],
    max_output_chars: [type: :non_neg_integer],
    compaction: [type: :boolean, default: false],
    compaction_threshold_pct: [
      type: {:custom, __MODULE__, :validate_compaction_threshold, []},
      default: 0.85
    ],
    compaction_context_tokens: [type: :pos_integer, default: 128_000],
    persistent: [type: :boolean, default: false]
  ]

  # Names already bound inside the constrained interpreter: the registered
  # callbacks and the interpreter intrinsics (`SHOW_VARS` is rewritten to
  # `show_vars` before evaluation). A user tool taking one of these names would
  # be shadowed by the builtin, so it is rejected at construction.
  @reserved_tool_names ~w(llm_query llm_query_batched rlm_query rlm_query_batched recurse load print submit show_vars SHOW_VARS)

  def new(signature, opts \\ []) do
    signature = Imp.Signature.ensure(signature)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.RLM.new/2")
    tools = Imp.Tool.index_tools!(opts[:tools], "Imp.Predict.RLM.new/2")
    validate_tool_names!(tools)

    persistent = opts[:persistent]
    session = if persistent, do: start_persistent_session!(), else: nil

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
      max_concurrent_subcalls: opts[:max_concurrent_subcalls],
      max_time_ms: non_negative_integer_or_nil(opts[:max_time_ms]),
      max_preview_chars: non_negative_integer(opts[:max_preview_chars]),
      max_observation_chars:
        non_negative_integer(Keyword.get(opts, :max_output_chars, opts[:max_observation_chars])),
      compaction: opts[:compaction],
      compaction_threshold_pct: opts[:compaction_threshold_pct],
      compaction_context_tokens: opts[:compaction_context_tokens],
      persistent: persistent,
      session: session,
      dynamic_lm?: not Keyword.has_key?(opts, :lm),
      dynamic_sub_lm?: not Keyword.has_key?(opts, :sub_lm) and not Keyword.has_key?(opts, :lm),
      dynamic_adapter?: not Keyword.has_key?(opts, :adapter)
    }
  end

  defp validate_tool_names!(tools) do
    Enum.each(tools, fn {name, _tool} ->
      if to_string(name) in @reserved_tool_names do
        raise ArgumentError,
              "Imp.Predict.RLM.new/2 tool name #{inspect(name)} conflicts with a built-in " <>
                "interpreter function; reserved names: #{Enum.join(@reserved_tool_names, ", ")}"
      end
    end)
  end

  @doc false
  def validate_compaction_threshold(value) when is_number(value) and value > 0 and value <= 1,
    do: {:ok, value * 1.0}

  def validate_compaction_threshold(value),
    do: {:error, "expected a number greater than 0 and at most 1, got: #{inspect(value)}"}

  @doc "Creates a lazy value handle that an RLM controller can load explicitly."
  def sandbox_serializable(name, loader, opts \\ []),
    do: Imp.Predict.RLM.SandboxSerializable.new(name, loader, opts)

  @doc "Closes the optional persistent RLM environment."
  def close(%__MODULE__{persistent: true, session: session}) when is_pid(session),
    do: Session.close(session)

  def close(%__MODULE__{}), do: :ok

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

  The controller LM returns reasoning and constrained Elixir `code`. A
  successful `submit/1` call returns a `Imp.Prediction` with `:rlm_trace`
  metadata.
  """
  def call(%__MODULE__{} = rlm, inputs) when is_list(inputs) or is_map(inputs) do
    do_call(rlm, inputs, Imp.Execution.unrestricted())
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_rlm_inputs,
        "expected a map or keyword/list of input pairs, got: #{inspect(inputs)}"}}

  @impl true
  def execute(%__MODULE__{} = rlm, inputs, %Imp.Execution{} = execution)
      when is_list(inputs) or is_map(inputs) do
    do_call(rlm, inputs, execution)
  end

  def execute(%__MODULE__{}, inputs, %Imp.Execution{}),
    do:
      {:error,
       {:invalid_rlm_inputs,
        "expected a map or keyword/list of input pairs, got: #{inspect(inputs)}"}}

  defp do_call(rlm, inputs, execution) do
    with {:ok, vars} <- normalize_inputs(inputs),
         :ok <- validate_required_inputs(rlm.signature, vars) do
      call_with_environment(rlm, vars, execution)
    end
  end

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

  defp call_with_environment(
         %__MODULE__{persistent: true, session: session} = rlm,
         vars,
         execution
       )
       when is_pid(session) do
    Session.transaction(session, fn snapshot ->
      environment = Session.merge_inputs(snapshot, vars)

      {result, state} =
        call_with_new_budget(rlm, environment.vars,
          protected_vars: Session.protected_vars(environment, rlm.compaction),
          compaction_history: environment.compaction_history,
          execution: execution
        )

      environment = %{
        environment
        | vars: state.interpreter.vars,
          compaction_history: state.compaction_history
      }

      environment =
        case result do
          {:ok, _prediction} ->
            Session.add_history(
              environment,
              state.call_history,
              state.compaction_history,
              rlm.compaction
            )

          {:error, _reason} ->
            environment
        end

      {result, environment}
    end)
  end

  defp call_with_environment(%__MODULE__{persistent: true}, _vars, _execution),
    do: {:error, :rlm_persistent_session_closed}

  defp call_with_environment(%__MODULE__{} = rlm, vars, execution) do
    {result, _state} =
      call_with_new_budget(rlm, vars,
        protected_vars: protected_input_vars(vars),
        execution: execution
      )

    result
  end

  defp protected_input_vars(vars) do
    case Enum.find(vars, fn {key, _value} -> to_string(key) == "context" end) do
      {_key, value} -> %{"context" => value}
      nil -> %{}
    end
  end

  defp call_with_new_budget(%__MODULE__{} = rlm, vars, opts) do
    case Budget.start_link(
           max_lm_calls: rlm.max_llm_calls,
           max_time_ms: rlm.max_time_ms,
           max_recursion_depth: rlm.max_recursion_depth
         ) do
      {:ok, budget} ->
        cancel_ref =
          Imp.Run.register_cancellable(fn reason ->
            if Process.alive?(budget), do: Budget.cancel(budget, reason)
          end)

        try do
          call_with_budget_state(rlm, vars, budget, 0, opts)
        after
          Imp.Run.unregister_cancellable(cancel_ref)
          if Process.alive?(budget), do: GenServer.stop(budget, :normal)
        end

      {:error, reason} ->
        {{:error, reason}, %{interpreter: Interpreter.new(vars, %{}, nil)}}
    end
  end

  defp call_with_budget(%__MODULE__{} = rlm, vars, budget, depth, execution) do
    {result, _state} =
      call_with_budget_state(rlm, vars, budget, depth, execution: execution)

    result
  end

  defp call_with_budget_state(%__MODULE__{} = rlm, vars, budget, depth, opts) do
    protected_vars = opts |> Keyword.get(:protected_vars, %{}) |> Map.new()
    compaction_history = Keyword.get(opts, :compaction_history, [])
    execution = Keyword.get_lazy(opts, :execution, &Imp.Execution.unrestricted/0)

    {vars, protected_vars} =
      if rlm.compaction do
        {
          Map.put(vars, :history, compaction_history),
          Map.put(protected_vars, "history", compaction_history)
        }
      else
        {vars, protected_vars}
      end

    runtime = Runtime.new(rlm, budget, vars, depth, execution)

    interpreter =
      Interpreter.new(vars, interpreter_callbacks(rlm), runtime,
        max_steps: rlm.max_interpreter_steps,
        max_output_chars: rlm.max_observation_chars,
        max_value_bytes: rlm.max_interpreter_value_bytes,
        max_effects: rlm.max_interpreter_effects,
        protected_vars: protected_vars
      )

    state = %{
      vars: vars,
      interpreter: interpreter,
      budget: budget,
      depth: depth,
      observations: [],
      trace: [],
      invalid_action_digests: MapSet.new(),
      trace_limit: rlm.max_observation_chars,
      llm_calls: Budget.snapshot(budget).lm_calls,
      started_at: System.monotonic_time(:millisecond),
      call_history: [],
      active_history: [],
      pending_history_segment: [],
      compaction_history: compaction_history,
      compaction_count: 0,
      compaction_summary: nil,
      compaction?: rlm.compaction,
      history_error: nil
    }

    run_loop(rlm, state, 1)
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration)
       when iteration > rlm.max_iterations and rlm.max_iterations == 0 do
    {{:error, {:rlm_max_iterations, rlm.max_iterations, Enum.reverse(state.trace)}}, state}
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration)
       when iteration > rlm.max_iterations do
    extract_fallback(rlm, state, iteration)
  end

  defp run_loop(%__MODULE__{} = rlm, state, iteration) do
    with :ok <- check_time_budget(rlm, state),
         :ok <- check_history_error(state),
         {:ok, state} <- maybe_compact_history(rlm, state, iteration),
         {:ok, raw_action, messages} <- controller_action(rlm, state, iteration),
         state = record_controller_exchange(state, messages, raw_action),
         {:cont, state} <- consume_controller_output(rlm, raw_action, state, iteration) do
      run_loop(rlm, state, iteration + 1)
    else
      {:done, prediction, state} ->
        case check_history_error(state) do
          :ok -> {{:ok, add_trace(prediction, state)}, state}
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, :rlm_time_budget_exceeded} ->
        {{:error, {:rlm_max_time_ms, rlm.max_time_ms, Enum.reverse(state.trace)}}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp consume_controller_output(rlm, raw, state, iteration) do
    case normalize_action(raw) do
      {:ok, action} -> step(rlm, action, state, iteration)
      {:error, reason} -> maybe_direct_submit(rlm, raw, state, iteration, reason)
    end
  end

  defp maybe_direct_submit(rlm, raw, state, iteration, original_error) do
    output = unwrap_lm_output(raw)

    if is_map(output) do
      output = stringify_action_keys(output)
      required = Enum.map(Imp.Signature.output_names(rlm.signature), &to_string/1)
      keys = Map.keys(output)

      if Enum.sort(keys) == Enum.sort(required) or
           Enum.sort(keys) == Enum.sort(["reasoning" | required]) do
        emit_reasoning(Map.get(output, "reasoning", ""), iteration, :direct_submit)
        fields = Map.take(output, required)

        case resolve_adapter(rlm).parse(rlm.signature, fields, []) do
          {:ok, prediction} ->
            if required_outputs_present?(rlm.signature, prediction) do
              state =
                state
                |> discard_pending_history_segment()
                |> trace_without_history(
                  iteration,
                  :direct_submit,
                  %{reasoning: Map.get(output, "reasoning", "")},
                  fields
                )

              {:done, prediction, state}
            else
              direct_submit_error(rlm, output, fields, state, iteration, :empty_required_output)
            end

          {:error, reason} ->
            direct_submit_error(rlm, output, fields, state, iteration, reason)
        end
      else
        {:error, original_error}
      end
    else
      if is_binary(output),
        do: controller_action_error(output, state, iteration, original_error),
        else: {:error, original_error}
    end
  end

  defp controller_action_error(output, state, iteration, reason) do
    detail = safe_error_detail(output)
    digest = :crypto.hash(:sha256, output)

    state =
      state
      |> Map.update!(:invalid_action_digests, &MapSet.put(&1, digest))
      |> add_observation(%{
        reasoning: "",
        output: {:action_error, reason |> Imp.Redaction.redact() |> Trace.compact(512)}
      })
      |> trace(iteration, :action_error, %{reasoning: ""}, detail)

    {:cont, state}
  end

  defp unwrap_lm_output(%{__imp_lm_output__: _output} = result) do
    case Imp.LM.Result.output(result) do
      {:ok, output} -> output
      {:error, _reason} -> result
    end
  end

  defp unwrap_lm_output(%{"__imp_lm_output__" => _output} = result) do
    case Imp.LM.Result.output(result) do
      {:ok, output} -> output
      {:error, _reason} -> result
    end
  end

  defp unwrap_lm_output(output), do: output

  defp direct_submit_error(rlm, output, fields, state, iteration, reason) do
    observation = {:submit_error, reason}

    state =
      state
      |> add_observation(%{
        reasoning: Map.get(output, "reasoning", ""),
        output: observation
      })
      |> trace(
        iteration,
        :direct_submit_error,
        %{reasoning: Map.get(output, "reasoning", "")},
        fields
      )

    if iteration >= rlm.max_iterations,
      do: {:error, {:rlm_invalid_final_output, reason, Enum.reverse(state.trace)}},
      else: {:cont, state}
  end

  defp controller_action(%__MODULE__{} = rlm, state, iteration) do
    case resolve_lm(rlm) do
      nil -> {:error, :rlm_requires_controller_lm}
      lm -> controller_action_with_lm(rlm, lm, state, iteration)
    end
  end

  defp controller_action_with_lm(%__MODULE__{} = rlm, lm, state, iteration) do
    messages = controller_messages(rlm, state, iteration)

    case run_budgeted(state.budget, fn -> generate_lm(rlm, lm, messages) end) do
      {:ok, raw_action} -> {:ok, raw_action, messages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp controller_messages(%__MODULE__{} = rlm, state, iteration) do
    turn_message = %{
      role: :user,
      content:
        Jason.encode!(%{
          iteration: iteration,
          variables: variable_metadata(state.interpreter.vars, rlm.max_preview_chars),
          observations: %{
            count: length(state.observations),
            source: :prior_repl_messages
          },
          compaction:
            if(state.compaction_summary,
              do: %{
                count: state.compaction_count,
                summary: :available_in_prior_messages,
                full_history: :available_in_environment
              },
              else: nil
            ),
          budget: %{
            remaining_iterations: rlm.max_iterations - iteration + 1,
            remaining_sub_lm_calls: rlm.max_llm_calls - state.llm_calls,
            max_llm_calls_scope: @max_llm_calls_scope,
            remaining_time_ms: remaining_time(rlm, state)
          }
        })
    }

    if state.active_history == [] do
      controller_prefix(rlm) ++ [turn_message]
    else
      state.active_history ++ [turn_message]
    end
  end

  defp controller_prefix(%__MODULE__{} = rlm) do
    [
      %{
        role: :system,
        content:
          "You are an RLM controller with a persistent, constrained Elixir environment. Follow the task instructions exactly. Return exactly one JSON object such as {\"reasoning\":\"inspect the context\",\"code\":\"context = load(\\\"context\\\")\\nprint(context)\"}; do not use markdown fences or prose around it. Code may inspect and assign variables, use for comprehensions, call SHOW_VARS(), llm_query(prompt, model \\\\ nil), llm_query_batched(prompts, model \\\\ nil), rlm_query(prompt, model \\\\ nil), rlm_query_batched(prompts, model \\\\ nil), recurse(signature, inputs), load(name), registered tools, print(value), and submit(a_map_with_the_required_output_fields). rlm_query creates an isolated recursive constrained environment and falls back to a one-shot query at the configured depth limit. State persists across turns. Every reply is that one JSON object, including the last: explore and compute in code, and when every required output is ready, reply with code that calls submit/1 with non-empty values. Only the first object in a reply is run, and you read its output before you write the next.\n\n" <>
            Interpreter.controller_language_guide()
      },
      %{
        role: :user,
        content:
          Jason.encode!(%{
            signature: Imp.Signature.to_spec(rlm.signature),
            task_instructions: rlm.signature.instructions,
            required_outputs: Imp.Signature.output_names(rlm.signature),
            tools: tool_metadata(rlm.tools),
            environment: %{
              runtime: :beam_constrained_elixir,
              persistent_namespace: true,
              full_history_variable: if(rlm.compaction, do: :history, else: nil)
            }
          })
      }
    ]
  end

  defp normalize_action(%{action: _} = action),
    do:
      {:error,
       {:invalid_rlm_action,
        "legacy discrete action maps are unsupported; return a map with reasoning and code",
        action}}

  defp normalize_action(%{__imp_lm_output__: _output} = result) do
    with {:ok, output} <- Imp.LM.Result.output(result), do: normalize_action(output)
  end

  defp normalize_action(%{"__imp_lm_output__" => _output} = result) do
    with {:ok, output} <- Imp.LM.Result.output(result), do: normalize_action(output)
  end

  defp normalize_action(%{submit: _} = action),
    do:
      {:error,
       {:invalid_rlm_action,
        "legacy discrete submit maps are unsupported; call submit/1 from code",
        safe_error_detail(action)}}

  defp normalize_action(%{"code" => code} = action)
       when is_binary(code) and not is_map_key(action, "action") do
    {:ok,
     %{
       "action" => "run",
       "code" => code,
       "reasoning" => Map.get(action, "reasoning", "")
     }}
  end

  defp normalize_action(%{code: code} = action)
       when is_binary(code),
       do: action |> stringify_action_keys() |> normalize_action()

  defp normalize_action(text) when is_binary(text) do
    case Action.decode(text) do
      {:ok, action} -> normalize_action(action)
      {:error, _reason} -> {:error, {:invalid_rlm_action, safe_error_detail(text)}}
    end
  end

  defp normalize_action(%{"action" => _} = action),
    do:
      {:error,
       {:invalid_rlm_action,
        "legacy discrete action maps are unsupported; return a map with reasoning and code",
        safe_error_detail(action)}}

  defp normalize_action(%{"submit" => _} = action),
    do:
      {:error,
       {:invalid_rlm_action,
        "legacy discrete submit maps are unsupported; call submit/1 from code",
        safe_error_detail(action)}}

  defp normalize_action(other),
    do:
      {:error,
       {:invalid_rlm_action, "expected a map with a binary code field", safe_error_detail(other)}}

  defp safe_error_detail(value) when is_binary(value) do
    fingerprint =
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    %{
      type: :string,
      bytes: byte_size(value),
      fingerprint: fingerprint
    }
  end

  defp safe_error_detail(value), do: value |> Imp.Redaction.redact() |> Trace.compact(512)

  defp emit_reasoning("", _iteration, _phase), do: :ok
  defp emit_reasoning(nil, _iteration, _phase), do: :ok

  defp emit_reasoning(reasoning, iteration, phase) do
    Imp.Run.emit(:reasoning,
      component: __MODULE__,
      reasoning: reasoning,
      metadata: %{iteration: iteration, phase: phase}
    )
  end

  defp stringify_action_keys(action) do
    Map.new(action, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp step(%__MODULE__{} = rlm, %{"action" => "run", "code" => code} = action, state, iteration)
       when is_binary(code) do
    reasoning = Map.get(action, "reasoning", "")
    emit_reasoning(reasoning, iteration, :controller)

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
            if required_outputs_present?(rlm.signature, prediction) do
              state = sync_interpreter(state, Interpreter.commit(interpreter))

              state =
                state
                |> discard_pending_history_segment()
                |> trace_without_history(
                  iteration,
                  :submit,
                  %{reasoning: reasoning, code: code},
                  result
                )

              {:done, prediction, state}
            else
              output = {:submit_error, :empty_required_output}

              state =
                state
                |> sync_interpreter(interpreter)
                |> add_observation(%{reasoning: reasoning, code: code, output: output})
                |> trace(iteration, :submit_error, %{reasoning: reasoning, code: code}, output)

              {:cont, state}
            end

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

  defp required_outputs_present?(signature, prediction) do
    Enum.all?(Imp.Signature.output_names(signature), fn name ->
      case Imp.Prediction.get(prediction, name) do
        nil -> false
        value when is_binary(value) -> String.trim(value) != ""
        _value -> true
      end
    end)
  end

  defp interpreter_callbacks(%__MODULE__{} = rlm) do
    builtins = %{
      "llm_query" => :llm_query,
      "llm_query_batched" => :llm_query_batched,
      "rlm_query" => :rlm_query,
      "rlm_query_batched" => :rlm_query_batched,
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
            vars: state.interpreter.vars,
            protected_vars: state.interpreter.protected_vars
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

        %Effect{kind: :rlm_query, arguments: args} ->
          interpreter_rlm_query(args, runtime)

        %Effect{kind: :rlm_query_batched, arguments: args} ->
          interpreter_rlm_query_batched(args, runtime)

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

  defp interpreter_llm_query([prompt], runtime),
    do: interpreter_llm_query([prompt, nil], runtime)

  defp interpreter_llm_query([prompt, model], %{budget: budget, rlm: rlm} = runtime)
       when is_binary(prompt) and (is_nil(model) or is_binary(model)) do
    with {:ok, _used} <- Budget.reserve_lm(budget, 1),
         :ok <- Budget.check(budget),
         {:ok, raw} <- run_budgeted(budget, fn -> query_sub_lm(rlm, prompt, model) end),
         {:ok, value} <- subquery_value(raw) do
      {:ok, value, runtime}
    else
      {:error, reason} -> {:error, reason, runtime}
    end
  end

  defp interpreter_llm_query(args, runtime),
    do: {:error, {:invalid_llm_query_arguments, args}, runtime}

  defp interpreter_llm_query_batched([prompts], runtime),
    do: interpreter_llm_query_batched([prompts, nil], runtime)

  defp interpreter_llm_query_batched(
         [prompts, model],
         %{budget: budget, rlm: rlm} = runtime
       )
       when is_list(prompts) and (is_nil(model) or is_binary(model)) do
    with true <- Enum.all?(prompts, &(is_binary(&1) and &1 != "")),
         {:ok, results} <-
           run_leased_batch(budget, prompts, &query_sub_lm(rlm, &1, model)) do
      normalized =
        Enum.map(results, fn
          {:ok, value} ->
            case subquery_value(value) do
              {:ok, output} -> output
              {:error, reason} -> llm_query_error(reason)
            end

          {:error, reason} ->
            llm_query_error(reason)
        end)

      {:ok, normalized, runtime}
    else
      false -> {:error, {:invalid_llm_query_batched_arguments, prompts}, runtime}
      {:error, reason} -> {:error, reason, runtime}
    end
  end

  defp interpreter_llm_query_batched(args, runtime),
    do: {:error, {:invalid_llm_query_batched_arguments, args}, runtime}

  defp interpreter_rlm_query([prompt], runtime),
    do: interpreter_rlm_query([prompt, nil], runtime)

  defp interpreter_rlm_query([prompt, model], runtime)
       when is_binary(prompt) and prompt != "" and (is_nil(model) or is_binary(model)) do
    if recursive_child_available?(runtime) do
      case run_recursive_child(runtime, prompt, model) do
        {:ok, value, depth, trace} ->
          runtime = Runtime.observe_recursion(runtime, depth, trace, :rlm_query)
          {:ok, value, runtime}

        {:error, reason, depth, trace} ->
          runtime = Runtime.observe_recursion(runtime, depth, trace, :rlm_query)
          {:error, reason, runtime}

        {:partial_error, value, _depth} ->
          {:ok, value, runtime}
      end
    else
      rlm_query_fallback(prompt, model, runtime)
    end
  end

  defp interpreter_rlm_query(args, runtime),
    do: {:error, {:invalid_rlm_query_arguments, args}, runtime}

  defp interpreter_rlm_query_batched([prompts], runtime),
    do: interpreter_rlm_query_batched([prompts, nil], runtime)

  defp interpreter_rlm_query_batched([prompts, model], runtime)
       when is_list(prompts) and (is_nil(model) or is_binary(model)) do
    if Enum.all?(prompts, &(is_binary(&1) and &1 != "")) do
      if recursive_child_available?(runtime) do
        run_recursive_children(prompts, model, runtime)
      else
        rlm_query_batched_fallback(prompts, model, runtime)
      end
    else
      {:error, {:invalid_rlm_query_batched_arguments, prompts}, runtime}
    end
  end

  defp interpreter_rlm_query_batched(args, runtime),
    do: {:error, {:invalid_rlm_query_batched_arguments, args}, runtime}

  defp recursive_child_available?(%{depth: depth, rlm: rlm}) do
    depth + 1 < rlm.max_recursion_depth
  end

  defp run_recursive_child(
         %{budget: budget, rlm: rlm, depth: parent_depth} = runtime,
         prompt,
         model
       ) do
    with {:ok, depth} <- Budget.enter_recursion(budget, parent_depth) do
      child = recursive_query_child(rlm, model)

      case call_with_budget(child, %{context: prompt}, budget, depth, runtime.execution) do
        {:ok, prediction} ->
          trace = get_in(prediction.metadata, [:rlm_trace]) || []
          {:ok, recursive_query_value(prediction), depth, trace}

        {:error, reason} ->
          if hard_runtime_error?(reason),
            do: {:error, reason, depth, []},
            else: {:partial_error, recursive_query_error(reason), depth}
      end
    else
      {:error, reason} -> {:error, reason, parent_depth + 1, []}
    end
  end

  defp run_recursive_children(prompts, model, runtime) do
    settings = Imp.Settings.snapshot()
    process_dictionary = effect_process_dictionary()

    run_child = fn prompt ->
      Imp.Settings.with_snapshot(settings, fn ->
        put_effect_process_dictionary(process_dictionary)
        run_recursive_child(runtime, prompt, model)
      end)
    end

    stream =
      Task.Supervisor.async_stream_nolink(
        Imp.Tasks.supervisor(),
        prompts,
        run_child,
        ordered: true,
        max_concurrency: min(runtime.rlm.max_concurrent_subcalls, max(length(prompts), 1)),
        timeout: Budget.task_timeout(runtime.budget),
        on_timeout: :kill_task
      )

    results =
      Enum.map(stream, fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:partial_error, recursive_query_error({:child_exit, reason}), runtime.depth + 1}
      end)

    case Budget.check(runtime.budget) do
      {:error, reason} ->
        {:error, reason, runtime}

      :ok ->
        case Enum.find(results, fn
               {:error, reason, _depth, _trace} -> hard_runtime_error?(reason)
               _result -> false
             end) do
          {:error, reason, _depth, _trace} ->
            {:error, reason, runtime}

          nil ->
            {values, runtime} =
              Enum.map_reduce(results, runtime, fn
                {:ok, value, depth, trace}, runtime ->
                  {value, Runtime.observe_recursion(runtime, depth, trace, :rlm_query)}

                {:partial_error, value, _depth}, runtime ->
                  {value, runtime}
              end)

            {:ok, values, runtime}
        end
    end
  end

  defp rlm_query_fallback(prompt, model, runtime) do
    case interpreter_llm_query([prompt, model], runtime) do
      {:ok, value, runtime} ->
        {:ok, recursive_query_value(value), runtime}

      {:error, reason, runtime} ->
        if hard_runtime_error?(reason),
          do: {:error, reason, runtime},
          else: {:ok, recursive_query_error(reason), runtime}
    end
  end

  defp rlm_query_batched_fallback(prompts, model, runtime) do
    case interpreter_llm_query_batched([prompts, model], runtime) do
      {:ok, values, runtime} ->
        values =
          Enum.map(values, fn
            {:error, reason} -> recursive_query_error(reason)
            value -> recursive_query_value(value)
          end)

        {:ok, values, runtime}

      {:error, reason, runtime} ->
        if hard_runtime_error?(reason),
          do: {:error, reason, runtime},
          else: {:ok, List.duplicate(recursive_query_error(reason), length(prompts)), runtime}
    end
  end

  defp recursive_query_child(rlm, model) do
    %{
      rlm
      | signature: Imp.Signature.ensure("context -> answer"),
        persistent: false,
        session: nil,
        compaction: false,
        model_override: model
    }
  end

  defp recursive_query_value(%Imp.Prediction{} = prediction),
    do: prediction |> Imp.Prediction.get(:answer) |> recursive_query_value()

  defp recursive_query_value(value) when is_binary(value), do: value
  defp recursive_query_value(value), do: inspect(value)

  defp recursive_query_error(reason) do
    reason = reason |> Imp.Redaction.redact() |> inspect(limit: 12, printable_limit: 512)
    "Error: RLM query failed - #{reason}"
  end

  defp hard_runtime_error?(:rlm_time_budget_exceeded), do: true
  defp hard_runtime_error?({:rlm_max_time_ms, _max, _trace}), do: true
  defp hard_runtime_error?({:rlm_cancelled, _reason}), do: true
  defp hard_runtime_error?({{:rlm_cancelled, _reason}, _trace}), do: true
  defp hard_runtime_error?({:execution_cancelled, _reason}), do: true
  defp hard_runtime_error?(_reason), do: false

  defp interpreter_recurse(
         [signature, inputs],
         %{budget: budget, rlm: rlm, depth: parent_depth} = runtime
       )
       when (is_binary(signature) or is_struct(signature, Imp.Signature)) and is_map(inputs) do
    with {:ok, child_signature} <- safe_signature(signature),
         :ok <- validate_required_inputs(child_signature, inputs),
         {:ok, depth} <- Budget.enter_recursion(budget, parent_depth) do
      # Recursive calls run in a distinct REPL environment. Do not let an
      # opt-in persistent root session cross a recursion branch boundary.
      child = %{rlm | signature: child_signature, persistent: false, session: nil}

      case call_with_budget(child, inputs, budget, depth, runtime.execution) do
        {:ok, prediction} ->
          trace = get_in(prediction.metadata, [:rlm_trace]) || []
          runtime = Runtime.observe_recursion(runtime, depth, trace)
          {:ok, Imp.Prediction.to_map(prediction), runtime}

        {:error, reason} ->
          {:error, reason, Runtime.observe_recursion(runtime, depth)}
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
      {:ok, %Imp.Predict.RLM.SandboxSerializable{} = serializable} ->
        case run_budgeted(runtime.budget, fn ->
               Imp.Predict.RLM.SandboxSerializable.load(serializable)
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
    tool_call_id = Imp.Run.new_event_id("rlm_tool")

    :ok =
      Imp.Run.emit(:tool_call,
        component: __MODULE__,
        tool_call_id: tool_call_id,
        tool_name: name,
        input: args
      )

    # `execute_tool_call/6` says whether it refused the call or ran the tool,
    # and the outcome is decided from that: a tool can return any term, so its
    # value alone cannot say it was refused.
    case run_budgeted(runtime.budget, fn ->
           execute_tool_call(rlm, name, name, args, tool_call_id, runtime.execution)
         end) do
      {:cancel, reason} ->
        {:error, {:execution_cancelled, reason}, runtime}

      {:refused, reason} ->
        tool_failed(name, tool_call_id, reason, :refused, runtime)

      {:ran, {:error, reason} = error} ->
        tool_failed(name, tool_call_id, reason, Imp.Tool.outcome(error), runtime)

      {:ran, value} ->
        :ok =
          Imp.Run.emit(:tool_result,
            component: __MODULE__,
            tool_call_id: tool_call_id,
            tool_name: name,
            output: value,
            metadata: %{outcome: :result}
          )

        {:ok, value, runtime}

      # The budget stopped the call, before the tool started or while it ran.
      {:error, reason} ->
        tool_failed(name, tool_call_id, reason, :unknown, runtime)
    end
  end

  defp interpreter_tool(name, args, runtime),
    do: {:error, {:invalid_tool_arguments, name, args}, runtime}

  defp tool_failed(name, tool_call_id, reason, outcome, runtime) do
    error = {:rlm_tool_error, reason}

    :ok =
      Imp.Run.emit(:tool_result,
        component: __MODULE__,
        tool_call_id: tool_call_id,
        tool_name: name,
        error: error,
        metadata: %{outcome: outcome}
      )

    {:error, error, runtime}
  end

  defp query_sub_lm(%__MODULE__{} = rlm, prompt, model) do
    case resolve_sub_lm(rlm) do
      nil -> {:error, :rlm_requires_sub_lm}
      lm -> generate_lm(rlm, lm, [%{role: :user, content: prompt}], model)
    end
  end

  defp generate_lm(rlm, lm, messages, model \\ nil) do
    model = model || rlm.model_override

    case {lm, model} do
      {lm, nil} ->
        Imp.LM.generate(lm, messages, [])

      {%{__struct__: _module, model: _configured} = lm, model} ->
        Imp.LM.generate(Map.put(lm, :model, model), messages, [])

      {lm, model} ->
        Imp.LM.generate(lm, messages, model: model)
    end
  end

  defp run_budgeted(budget, fun) when is_function(fun, 0) do
    with :ok <- Budget.check(budget) do
      {task, result_ref, inherited_keys} = start_budgeted_effect(fun)

      case Budget.register_effect(budget, task.pid) do
        :ok ->
          await_budgeted_effect(budget, task, result_ref, inherited_keys)

        {:error, reason} ->
          Imp.Tasks.cancel(task, 1_000)
          {:error, reason}
      end
    end
  end

  defp start_budgeted_effect(fun) do
    inherited_dictionary = effect_process_dictionary()
    result_ref = make_ref()

    task =
      Imp.Tasks.async_nolink(fn ->
        put_effect_process_dictionary(inherited_dictionary)
        result = fun.()
        {result_ref, result, effect_process_dictionary()}
      end)

    {task, result_ref, Map.keys(inherited_dictionary)}
  end

  defp await_budgeted_effect(budget, task, result_ref, inherited_keys) do
    case Task.yield(task, Budget.task_timeout(budget)) do
      {:ok, {^result_ref, result, effect_dictionary}} ->
        sync_effect_process_dictionary(inherited_keys, effect_dictionary)

        case Budget.check(budget) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end

      {:exit, reason} ->
        {:error, {:rlm_effect_exit, reason}}

      nil ->
        Imp.Tasks.cancel(task, 1_000)
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
            |> Imp.Tasks.async_stream(
              fn item ->
                with :ok <- Budget.check(budget),
                     {:ok, _used} <- Budget.commit_lm(budget, lease) do
                  fun.(item)
                end
              end,
              ordered: true,
              max_concurrency: min(max(length(items), 1), 8),
              timeout: Budget.task_timeout(budget),
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

  defp subquery_value(value) do
    case Imp.LM.Result.output(value) do
      {:ok, %Imp.Prediction{} = prediction} -> {:ok, Imp.Prediction.to_map(prediction)}
      {:ok, output} -> {:ok, output}
      {:error, _reason} = error -> error
    end
  end

  defp llm_query_error(reason) do
    reason = reason |> Imp.Redaction.redact() |> inspect(limit: 12, printable_limit: 512)
    "Error: LM query failed - #{reason}"
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

    interpreter =
      Enum.reduce(runtime.inputs, state.interpreter, fn {key, value}, interpreter ->
        case Map.fetch(previous_inputs, key) do
          {:ok, %Imp.Predict.RLM.SandboxSerializable{}} ->
            case Interpreter.put_protected(interpreter, key, value) do
              {:ok, interpreter} -> interpreter
              {:error, _reason} -> interpreter
            end

          _other ->
            interpreter
        end
      end)

    vars =
      Enum.reduce(runtime.inputs, state.interpreter.vars, fn {key, value}, vars ->
        case Map.fetch(previous_inputs, key) do
          {:ok, ^value} -> vars
          _other -> Map.put(vars, key, value)
        end
      end)

    interpreter = %{interpreter | runtime: runtime, vars: vars}
    %{state | interpreter: interpreter, vars: vars}
  end

  defp sync_budget_usage(state) do
    %{state | llm_calls: Budget.snapshot(state.budget).lm_calls}
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
  defp budget_error?({:execution_cancelled, _reason}), do: true
  defp budget_error?(:rlm_time_budget_exceeded), do: true
  defp budget_error?({:rlm_max_llm_calls, 0}), do: true
  defp budget_error?(_reason), do: false

  defp attach_rlm_trace({:rlm_max_llm_calls, max}, state),
    do: {:rlm_max_llm_calls, max, Enum.reverse(state.trace)}

  defp attach_rlm_trace({:execution_cancelled, reason}, _state),
    do: {:execution_cancelled, reason}

  defp attach_rlm_trace(reason, state), do: {reason, Enum.reverse(state.trace)}

  defp extract_fallback(%__MODULE__{} = rlm, state, iteration) do
    case resolve_lm(rlm) do
      nil ->
        {{:error, {:rlm_max_iterations, rlm.max_iterations, Enum.reverse(state.trace)}}, state}

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
            signature: Imp.Signature.to_spec(rlm.signature),
            exhausted_at_iteration: iteration,
            variables: variable_metadata(state.vars, rlm.max_preview_chars),
            observations: Enum.map(state.observations, &safe_json/1),
            trace: state.trace |> Enum.reverse() |> Enum.map(&safe_json/1)
          })
      }
    ]

    with {:ok, raw} <- run_budgeted(state.budget, fn -> generate_lm(rlm, lm, messages) end),
         {:ok, raw} <- Imp.LM.Result.output(raw),
         {:ok, prediction} <- resolve_adapter(rlm).parse(rlm.signature, raw, []),
         :ok <- validate_fallback_prediction(rlm.signature, prediction, state) do
      state = trace_without_history(state, iteration, :extract, %{reason: :max_iterations}, raw)
      {{:ok, add_trace(prediction, state)}, state}
    else
      {:error, reason} ->
        {{:error, {:rlm_extract_failed, reason, Enum.reverse(state.trace)}}, state}
    end
  end

  defp validate_fallback_prediction(signature, prediction, state) do
    cond do
      not required_outputs_present?(signature, prediction) ->
        {:error, :empty_required_output}

      Enum.any?(Imp.Signature.output_names(signature), fn name ->
        case Imp.Prediction.get(prediction, name) do
          value when is_binary(value) ->
            MapSet.member?(state.invalid_action_digests, :crypto.hash(:sha256, value))

          _value ->
            false
        end
      end) ->
        {:error, :replayed_invalid_action}

      true ->
        :ok
    end
  end

  defp maybe_compact_history(%__MODULE__{compaction: false}, state, _iteration),
    do: {:ok, state}

  defp maybe_compact_history(%__MODULE__{} = rlm, state, iteration) do
    compact? =
      state.active_history != [] and
        Compaction.should_compact?(
          state.active_history,
          rlm.compaction_threshold_pct,
          rlm.compaction_context_tokens
        )

    if compact? do
      compact_history(rlm, state, iteration)
    else
      {:ok, state}
    end
  end

  defp compact_history(rlm, state, iteration) do
    with lm when not is_nil(lm) <- resolve_lm(rlm),
         summary_messages = Compaction.summary_messages(state.active_history),
         {:ok, raw} <-
           run_budgeted(state.budget, fn -> generate_lm(rlm, lm, summary_messages) end),
         {:ok, summary} when is_binary(summary) <- Imp.LM.Result.output(raw) do
      count = state.compaction_count + 1
      continuation = Compaction.continuation(summary, count)

      event = %{
        iteration: iteration,
        action: :compact,
        depth: state.depth,
        input: %{
          estimated_tokens: Compaction.estimate_tokens(state.active_history),
          token_estimator: Compaction.estimator(),
          context_tokens: rlm.compaction_context_tokens
        },
        output: trace_term(%{count: count, summary: summary}, state.trace_limit)
      }

      scaffold =
        Enum.take(state.active_history, 2) ++
          [
            %{role: :assistant, content: summary},
            %{role: :user, content: continuation.instruction}
          ]

      state = %{
        state
        | observations: [],
          active_history: scaffold,
          call_history: normalize_history_messages(scaffold),
          pending_history_segment: [],
          compaction_history:
            state.compaction_history ++ [%{"type" => "summary", "content" => summary}],
          compaction_count: count,
          compaction_summary: summary,
          trace: [event | state.trace]
      }

      state = sync_compaction_history(state)

      case check_history_error(state) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :rlm_requires_controller_lm}
      {:ok, other} -> {:error, {:rlm_compaction_failed, {:invalid_summary, other}}}
      {:error, reason} -> {:error, {:rlm_compaction_failed, reason}}
    end
  end

  defp record_controller_exchange(state, messages, raw_action) do
    messages = normalize_controller_messages(messages)
    new_prompt_messages = Enum.drop(messages, length(state.active_history))
    assistant_content = history_content(unwrap_lm_output(raw_action))
    assistant_message = %{role: :assistant, content: assistant_content}

    call_segment =
      normalize_history_messages(new_prompt_messages) ++
        [%{"role" => "assistant", "content" => assistant_content}]

    # One compacted iteration is an assistant action followed by a single
    # REPL-result user message.
    pending_history_segment = [%{"role" => "assistant", "content" => assistant_content}]

    %{
      state
      | call_history: state.call_history ++ call_segment,
        active_history: messages ++ [assistant_message],
        pending_history_segment: pending_history_segment
    }
  end

  defp normalize_controller_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        role: normalize_controller_role(Map.get(message, :role, Map.get(message, "role"))),
        content: history_content(Map.get(message, :content, Map.get(message, "content", "")))
      }
    end)
  end

  defp normalize_controller_role(role) when role in [:system, :assistant, :user], do: role
  defp normalize_controller_role("system"), do: :system
  defp normalize_controller_role("assistant"), do: :assistant
  defp normalize_controller_role(_role), do: :user

  defp normalize_history_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        "role" => message |> Map.get(:role, Map.get(message, "role", "unknown")) |> to_string(),
        "content" => history_content(Map.get(message, :content, Map.get(message, "content", "")))
      }
    end)
  end

  defp history_content(value) when is_binary(value), do: value

  defp history_content(value) do
    Jason.encode!(value)
  rescue
    _error -> inspect(value, limit: 50, printable_limit: 4_000)
  end

  defp append_history_event(state, action, output) do
    pending_segment = state.pending_history_segment
    repl_content = "REPL output (#{action}):\n#{history_content(output)}"

    history_message = %{"role" => "user", "content" => repl_content}
    controller_message = %{role: :user, content: repl_content}

    state = %{
      state
      | call_history: state.call_history ++ [history_message],
        active_history: state.active_history ++ [controller_message],
        pending_history_segment: []
    }

    if state.compaction? do
      entry = pending_segment ++ [history_message]
      state = %{state | compaction_history: state.compaction_history ++ [entry]}
      sync_compaction_history(state)
    else
      state
    end
  end

  # Both callers append to the pending segment before discarding it, and
  # Enum.drop/2 with -0 is the identity, so an empty segment needs no clause.
  defp discard_pending_history_segment(state) do
    count = length(state.pending_history_segment)

    %{
      state
      | call_history: Enum.drop(state.call_history, -count),
        active_history: Enum.drop(state.active_history, -count),
        pending_history_segment: []
    }
  end

  defp sync_compaction_history(state) do
    case Interpreter.put_protected(state.interpreter, "history", state.compaction_history) do
      {:ok, interpreter} ->
        %{state | interpreter: interpreter, vars: interpreter.vars, history_error: nil}

      {:error, reason} ->
        %{state | history_error: {:rlm_history_budget_exceeded, reason}}
    end
  end

  defp check_history_error(%{history_error: nil}), do: :ok
  defp check_history_error(%{history_error: reason}), do: {:error, reason}

  defp add_observation(state, observation),
    do: Map.update!(state, :observations, &[trace_term(observation, state.trace_limit) | &1])

  defp trace(state, iteration, action, input, output) do
    state
    |> trace_without_history(iteration, action, input, output)
    |> append_history_event(action, output)
  end

  defp trace_without_history(state, iteration, action, input, output) do
    event = %{
      iteration: iteration,
      action: action,
      depth: state.depth,
      input: trace_term(input, state.trace_limit),
      output: trace_term(output, state.trace_limit)
    }

    Map.update!(state, :trace, &[event | &1])
  end

  defp trace_term(value, limit) do
    Trace.compact(value, limit)
  end

  defp add_trace(%Imp.Prediction{} = prediction, state) do
    trace = Enum.reverse(state.trace)
    runtime = state.interpreter.runtime
    child_traces = Enum.reverse(runtime.child_traces)
    trajectory = normalized_trajectory(trace)
    final_reasoning = trajectory |> List.last() |> then(&if(&1, do: &1.reasoning))

    metadata =
      prediction.metadata
      |> Map.put(:rlm_trace, trace)
      |> Map.put(:rlm_child_traces, child_traces)
      |> Map.put(:trajectory, trajectory)
      |> Map.put(:final_reasoning, final_reasoning)
      |> Map.put(:rlm, %{
        iterations: trace |> Enum.map(& &1.iteration) |> Enum.max(fn -> 0 end),
        max_llm_calls: runtime.rlm.max_llm_calls,
        max_llm_calls_scope: @max_llm_calls_scope,
        sub_lm_calls: state.llm_calls,
        max_observed_depth: runtime.max_observed_depth,
        compactions: state.compaction_count,
        compaction_token_estimator: Compaction.estimator(),
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
    Map.new(vars, fn {key, value} ->
      description =
        if history_variable?(key) and is_list(value) do
          %{type: :history, length: length(value), preview: :available_in_environment}
        else
          describe_value(value, preview_chars)
        end

      {key, description}
    end)
  end

  defp history_variable?(key) do
    name = to_string(key)
    name == "history" or String.starts_with?(name, "history_")
  end

  defp describe_value(%Imp.Predict.RLM.SandboxSerializable{} = value, _preview_chars) do
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

  defp describe_value(value, preview_chars) when is_list(value),
    do: Map.merge(%{type: :list, length: length(value)}, printed_preview(value, preview_chars))

  defp describe_value(value, preview_chars) when is_map(value),
    do: Map.merge(%{type: :map, size: map_size(value)}, printed_preview(value, preview_chars))

  defp describe_value(value, _preview_chars)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: %{type: type_of(value), value: value}

  defp describe_value(value, preview_chars),
    do: Map.merge(%{type: type_of(value)}, printed_preview(value, preview_chars))

  # Every preview is at most `preview_chars` characters of the value as the
  # controller's language prints it, as upstream previews a variable with
  # `str(value)[:preview_chars]`. A value too large to print in the preview is
  # printed with inspect's own limits, so a 20,000-line list costs no more to
  # describe than its preview; any term prints in at least an eighth of its
  # external size in characters, so such a value is always truncated.
  defp printed_preview(value, preview_chars) do
    {printed, cut?} =
      if :erlang.external_size(value) <= 8 * preview_chars do
        {inspect(value, limit: :infinity, printable_limit: :infinity), false}
      else
        # Each printed item takes at least three characters with its separator.
        limit = div(preview_chars, 3) + 1
        {inspect(value, limit: limit, printable_limit: preview_chars), true}
      end

    %{
      preview: String.slice(printed, 0, preview_chars),
      truncated: cut? or String.length(printed) > preview_chars
    }
  end

  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :float
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(value) when is_nil(value), do: nil
  defp type_of(value) when is_atom(value), do: :atom
  defp type_of(value) when is_tuple(value), do: :tuple
  defp type_of(_value), do: :term

  defp tool_metadata(tools) do
    tools
    |> Map.values()
    |> Enum.map(&%{name: &1.name, description: &1.description, schema: &1.schema})
  end

  defp execute_tool_call(_rlm, nil, requested_name, _args, _tool_call_id, _execution),
    do: {:refused, {:unknown_tool, requested_name}}

  defp execute_tool_call(rlm, name, _requested_name, args, tool_call_id, execution) do
    tool = Map.fetch!(rlm.tools, name)

    with :ok <- authorize_tool(rlm.tool_policy, name, args),
         :ok <- Imp.Tool.validate_input(tool, args) do
      request = %Imp.Execution.Authorization{
        run_id: execution.run_id,
        tool_call_id: tool_call_id,
        tool_name: tool.name,
        arguments: args,
        description: Imp.Execution.bounded_description(tool.description),
        metadata: %{runtime: __MODULE__}
      }

      case Imp.Execution.authorize(execution, request) do
        :allow ->
          {:ran, call_known_tool(tool, args)}

        {:deny, reason} ->
          {:refused, {:tool_authorization_denied, name, Imp.Redaction.redact(reason)}}

        {:cancel, reason} ->
          {:cancel, reason}
      end
    else
      {:error, reason} -> {:refused, reason}
    end
  end

  defp call_known_tool(tool, args) do
    Imp.Tool.call(tool, args)
  rescue
    exception ->
      {:error, {:tool_error, tool.name, exception}}
  catch
    kind, reason ->
      {:error, {:tool_error, tool.name, {kind, reason}}}
  end

  defp authorize_tool(policy, name, args), do: Imp.ToolPolicy.authorize(policy, name, args)

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

  defp resolve_lm(%__MODULE__{dynamic_lm?: true}), do: Imp.Settings.get().lm
  defp resolve_lm(%__MODULE__{lm: lm}), do: lm

  defp resolve_sub_lm(%__MODULE__{dynamic_sub_lm?: true}), do: Imp.Settings.get().lm
  defp resolve_sub_lm(%__MODULE__{sub_lm: nil} = rlm), do: resolve_lm(rlm)
  defp resolve_sub_lm(%__MODULE__{sub_lm: lm}), do: lm

  defp resolve_adapter(%__MODULE__{dynamic_adapter?: true}), do: Imp.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: nil}), do: Imp.Settings.get().adapter
  defp resolve_adapter(%__MODULE__{adapter: adapter}), do: adapter

  defp controller_predictor(%__MODULE__{} = rlm) do
    signature =
      "signature, iteration, variables, observations, tools, budget -> action"
      |> Imp.Signature.ensure()

    Imp.Predict.Predict.new(signature, lm: resolve_lm(rlm), adapter: resolve_adapter(rlm))
  end

  defp extract_predictor(%__MODULE__{} = rlm) do
    signature =
      "signature, variables, observations, trace -> output"
      |> Imp.Signature.ensure()

    Imp.Predict.Predict.new(signature, lm: resolve_lm(rlm), adapter: resolve_adapter(rlm))
  end

  defp subquery_predictor(%__MODULE__{} = rlm) do
    Imp.Predict.Predict.new(rlm.signature,
      lm: resolve_sub_lm(rlm),
      adapter: resolve_adapter(rlm)
    )
  end

  defp existing_atom_or_string(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp start_persistent_session! do
    case Session.start_link() do
      {:ok, session} -> session
      {:error, reason} -> raise "failed to start RLM persistent session: #{inspect(reason)}"
    end
  end

  defp safe_signature(signature) do
    {:ok, Imp.Signature.ensure(signature)}
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
