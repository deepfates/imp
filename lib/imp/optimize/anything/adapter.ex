defmodule Imp.Optimize.Anything.Adapter do
  @moduledoc false

  @behaviour Imp.Optimizer.GEPA.Adapter

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Refiner, StdioCapture, StructuredCandidate}
  alias Imp.Optimizer.GEPA.{Candidate, Result}
  alias Imp.Optimizer.Trajectory

  @modes [:single_task, :multi_task, :generalization]
  @contracts [:standard, :with_optimization_state]
  @candidate_formats [:named, :string, :structured]
  @default_candidate_key :current_candidate
  @default_best_example_evals_k 30
  @checkpoint_state_type "imp_optimize_anything_adapter_state"
  @checkpoint_state_version 1

  defmodule OptimizationState do
    @moduledoc false

    defstruct best_example_evals: []

    @type evaluation :: %{required(:score) => number(), required(:side_info) => map()}
    @type t :: %__MODULE__{best_example_evals: [evaluation()]}
  end

  @enforce_keys [:mode]
  defstruct [
    :evaluator,
    :batch_evaluator,
    :mode,
    candidate_format: :named,
    candidate_key: @default_candidate_key,
    structured_codec: nil,
    evaluator_contract: :standard,
    optimization_state: nil,
    optimization_state_store: nil,
    checkpoint_identity: nil,
    refiner: nil,
    best_example_evals_k: @default_best_example_evals_k,
    capture_stdio: false,
    raise_on_exception: true,
    max_concurrency: 1,
    timeout: 30_000
  ]

  @type mode :: :single_task | :multi_task | :generalization
  @type evaluator_contract :: :standard | :with_optimization_state
  @type candidate_format :: :named | :string | :structured
  @type t :: %__MODULE__{
          evaluator: function() | nil,
          batch_evaluator: function() | nil,
          mode: mode(),
          candidate_format: candidate_format(),
          candidate_key: atom() | String.t(),
          structured_codec: StructuredCandidate.t() | nil,
          evaluator_contract: evaluator_contract(),
          optimization_state: OptimizationState.t() | (term() -> OptimizationState.t()),
          optimization_state_store: pid(),
          checkpoint_identity: map() | nil,
          refiner: keyword() | nil,
          best_example_evals_k: non_neg_integer(),
          capture_stdio: boolean(),
          raise_on_exception: boolean(),
          max_concurrency: pos_integer(),
          timeout: timeout()
        }

  @spec new(function() | nil, mode()) :: t()
  def new(evaluator, mode) when mode in @modes, do: new(evaluator, mode, [])

  @spec new(function() | nil, keyword()) :: t()
  def new(evaluator, opts) when is_list(opts) do
    {mode, opts} = Keyword.pop(opts, :mode)

    if is_nil(mode) do
      raise ArgumentError, "Optimize Anything adapter requires an explicit :mode option"
    end

    new(evaluator, mode, opts)
  end

  @spec new(function() | nil, mode(), keyword()) :: t()
  def new(evaluator, mode, opts) when is_list(opts) do
    validate_mode!(mode)
    validate_options!(opts)

    adapter = %__MODULE__{
      evaluator: evaluator,
      batch_evaluator: Keyword.get(opts, :batch_evaluator),
      mode: mode,
      candidate_format: Keyword.get(opts, :candidate_format, :named),
      candidate_key: Keyword.get(opts, :candidate_key, @default_candidate_key),
      structured_codec: Keyword.get(opts, :structured_codec),
      evaluator_contract: Keyword.get(opts, :evaluator_contract, :standard),
      optimization_state: Keyword.get(opts, :optimization_state, %OptimizationState{}),
      checkpoint_identity: Keyword.get(opts, :checkpoint_identity),
      refiner: Keyword.get(opts, :refiner),
      best_example_evals_k:
        Keyword.get(opts, :best_example_evals_k, @default_best_example_evals_k),
      capture_stdio: Keyword.get(opts, :capture_stdio, false),
      raise_on_exception: Keyword.get(opts, :raise_on_exception, true),
      max_concurrency: Keyword.get(opts, :max_concurrency, 1),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }

    adapter = validate_adapter!(adapter)
    store = start_optimization_state_store()
    %{adapter | optimization_state_store: store}
  end

  @doc false
  @spec close(t()) :: :ok
  def close(%__MODULE__{optimization_state_store: store}) when is_pid(store) do
    if Process.alive?(store), do: Agent.stop(store, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, opts) when is_list(batch) do
    Candidate.validate!(candidate)
    validate_batch!(adapter.mode, batch)

    if adapter.batch_evaluator && is_nil(adapter.refiner) do
      adapter
      |> batch_evaluate([{candidate, batch}], opts)
      |> hd()
    else
      evaluate_individually(adapter, batch, candidate, opts)
    end
  end

  @impl true
  def batch_evaluate(
        %__MODULE__{batch_evaluator: batch_evaluator, refiner: nil} = adapter,
        items,
        opts
      )
      when not is_nil(batch_evaluator) and is_list(items) do
    Enum.each(items, fn {candidate, batch} ->
      Candidate.validate!(candidate)
      validate_batch!(adapter.mode, batch)
    end)

    capture_traces = Keyword.get(opts, :capture_traces, true)
    state_source = Keyword.get(opts, :optimization_state, adapter.optimization_state)

    contexts =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {{candidate, batch}, item_index} ->
        evaluator_candidate = evaluator_candidate(candidate, adapter)
        output_candidate = output_candidate(candidate, adapter)

        batch
        |> Enum.with_index()
        |> Enum.map(fn {example, example_index} ->
          %{
            item_index: item_index,
            example_index: example_index,
            example: example,
            public_example: public_example(adapter.mode, example),
            candidate: candidate,
            evaluator_candidate: evaluator_candidate,
            output_candidate: output_candidate,
            state: optimization_state(adapter, state_source, example)
          }
        end)
      end)

    evaluations = evaluate_grouped(adapter, contexts)

    Enum.each(Enum.zip(contexts, evaluations), fn {context, evaluation} ->
      if is_nil(evaluation.trajectory.error) do
        update_optimization_state(
          adapter,
          context.example,
          evaluation.score,
          evaluation.side_info
        )
      end
    end)

    evaluations_by_item = Enum.group_by(Enum.zip(contexts, evaluations), &elem(&1, 0).item_index)

    items
    |> Enum.with_index()
    |> Enum.map(fn {{candidate, _batch}, item_index} ->
      item_evaluations =
        evaluations_by_item
        |> Map.get(item_index, [])
        |> Enum.map(&elem(&1, 1))

      result_from_evaluations(adapter, candidate, item_evaluations, capture_traces, true)
    end)
  end

  def batch_evaluate(%__MODULE__{} = adapter, items, opts) when is_list(items) do
    Enum.map(items, fn {candidate, batch} ->
      evaluate_individually(adapter, batch, candidate, Keyword.put(opts, :capture_traces, true))
    end)
  end

  defp evaluate_individually(adapter, batch, candidate, opts) do
    capture_traces = Keyword.get(opts, :capture_traces, false)
    state_source = Keyword.get(opts, :optimization_state, adapter.optimization_state)

    evaluations =
      batch
      |> Enum.with_index()
      |> Imp.Tasks.async_stream(
        fn {example, index} -> evaluate_one(adapter, candidate, example, index, state_source) end,
        ordered: true,
        max_concurrency: min(adapter.max_concurrency, max(length(batch), 1)),
        timeout: adapter.timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.map(&resolve_task_result(&1, adapter.raise_on_exception))

    result_from_evaluations(adapter, candidate, evaluations, capture_traces, false)
  end

  @impl true
  def get_adapter_state(%__MODULE__{
        optimization_state_store: store,
        checkpoint_identity: nil
      }),
      do: Agent.get(store, &Map.new/1)

  def get_adapter_state(%__MODULE__{
        optimization_state_store: store,
        checkpoint_identity: identity
      }) do
    %{
      "type" => @checkpoint_state_type,
      "schema_version" => @checkpoint_state_version,
      "run_identity" => identity,
      "optimization_state" => Agent.get(store, &Map.new/1)
    }
  end

  @impl true
  def set_adapter_state(
        %__MODULE__{optimization_state_store: store, checkpoint_identity: nil} = adapter,
        state
      )
      when is_map(state) do
    validate_restored_optimization_state!(state, adapter.best_example_evals_k)
    Agent.update(store, fn _current -> Map.new(state) end)
    adapter
  end

  def set_adapter_state(
        %__MODULE__{optimization_state_store: store, checkpoint_identity: expected} = adapter,
        %{
          "type" => @checkpoint_state_type,
          "schema_version" => @checkpoint_state_version,
          "run_identity" => stored,
          "optimization_state" => state
        } = checkpoint
      )
      when is_map(state) do
    expected_keys = ~w(type schema_version run_identity optimization_state)

    unless MapSet.new(Map.keys(checkpoint)) == MapSet.new(expected_keys) do
      raise ArgumentError,
            "Optimize Anything adapter checkpoint has unexpected or missing keys"
    end

    unless stored == expected do
      if stored["schema_version"] == expected["schema_version"] and
           stored["candidate_selection_sha256"] != expected["candidate_selection_sha256"] do
        raise ArgumentError,
              "Optimize Anything candidate selection strategy identity mismatch on resume"
      else
        raise ArgumentError,
              "Optimize Anything resume run identity mismatch: stored #{inspect(stored)}, requested #{inspect(expected)}"
      end
    end

    validate_restored_optimization_state!(state, adapter.best_example_evals_k)
    Agent.update(store, fn _current -> Map.new(state) end)
    adapter
  end

  def set_adapter_state(%__MODULE__{checkpoint_identity: expected}, state)
      when is_map(expected) and is_map(state) do
    raise ArgumentError,
          "Optimize Anything resume checkpoint predates run identity binding and cannot be resumed safely"
  end

  defp validate_restored_optimization_state!(states, limit) do
    valid? =
      Enum.all?(states, fn {_example, evaluations} ->
        is_list(evaluations) and length(evaluations) <= limit and
          Enum.all?(evaluations, fn
            %{score: score, side_info: side_info} -> is_number(score) and is_map(side_info)
            _evaluation -> false
          end)
      end)

    unless valid? do
      raise ArgumentError,
            "Optimize Anything checkpoint contains an invalid optimization-state buffer"
    end
  end

  @impl true
  def make_reflective_dataset(%__MODULE__{}, candidate, result, components_to_update) do
    Candidate.validate!(candidate)

    Map.new(components_to_update, fn component ->
      records =
        result
        |> raw_side_information(component)
        |> Enum.map(&reflection_record(&1, component))

      {component, records}
    end)
  end

  defp evaluate_one(adapter, candidate, example, index, state_source) do
    state = optimization_state(adapter, state_source, example)
    public_candidate = output_candidate(candidate, adapter)

    try do
      case call_evaluator_with_stdio(adapter, candidate, example, state) do
        {:ok, raw, captured_stdout} ->
          evaluation =
            normalized_evaluation(
              raw,
              candidate,
              public_candidate,
              example,
              index,
              captured_stdout
            )

          unless refined_result?(raw) do
            update_optimization_state(adapter, example, evaluation.score, evaluation.side_info)
          end

          evaluation

        {:raised, kind, reason, stacktrace, captured_stdout} ->
          {:raised, kind, reason, stacktrace, public_candidate, example, index, captured_stdout}
      end
    rescue
      exception -> {:raised, :error, exception, __STACKTRACE__, public_candidate, example, index}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__, public_candidate, example, index}
    end
  end

  defp evaluate_grouped(_adapter, []), do: []

  defp evaluate_grouped(adapter, contexts) do
    pairs = Enum.map(contexts, &{&1.evaluator_candidate, &1.public_example})
    states = Enum.map(contexts, & &1.state)

    task_result =
      [{pairs, states}]
      |> Imp.Tasks.async_stream(
        fn {pairs, states} ->
          invoke_batch_evaluator(adapter.batch_evaluator, pairs, states)
        end,
        ordered: true,
        max_concurrency: 1,
        timeout: adapter.timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.at(0)

    case task_result do
      {:ok, {:ok, raw_results}} ->
        normalize_batch_results(adapter, contexts, raw_results)

      {:ok, {:raised, kind, reason, stacktrace}} when adapter.raise_on_exception ->
        :erlang.raise(kind, reason, stacktrace)

      {:ok, {:raised, _kind, reason, _stacktrace}} ->
        batch_failure_evaluations(contexts, redact_error(reason))

      {:exit, reason} when adapter.raise_on_exception ->
        raise RuntimeError,
              "Optimize Anything batch evaluator task exited: #{redact_error(reason)}"

      {:exit, reason} ->
        batch_failure_evaluations(
          contexts,
          "batch evaluator task exited: #{redact_error(reason)}"
        )
    end
  end

  defp invoke_batch_evaluator(batch_evaluator, pairs, states) do
    {:ok, call_batch_evaluator(batch_evaluator, pairs, states)}
  rescue
    exception -> {:raised, :error, exception, __STACKTRACE__}
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp call_batch_evaluator(batch_evaluator, pairs, states)
       when is_function(batch_evaluator, 2),
       do: batch_evaluator.(pairs, states)

  defp call_batch_evaluator(batch_evaluator, pairs, _states)
       when is_function(batch_evaluator, 1),
       do: batch_evaluator.(pairs)

  defp normalize_batch_results(adapter, contexts, raw_results) do
    raw_results = materialize_batch_results!(raw_results)

    unless length(raw_results) == length(contexts) do
      count = length(raw_results)

      raise ArgumentError,
            "Optimize Anything batch evaluator returned #{count} results but expected #{length(contexts)}"
    end

    contexts
    |> Enum.zip(raw_results)
    |> Enum.map(fn {context, raw} -> normalize_batch_evaluation(adapter, context, raw) end)
  end

  defp materialize_batch_results!(results) when is_list(results), do: results

  defp materialize_batch_results!(results)
       when (not is_map(results) or is_struct(results)) and not is_binary(results) do
    if Enumerable.impl_for(results) do
      Enum.to_list(results)
    else
      raise ArgumentError,
            "Optimize Anything batch evaluator must return an enumerable of aligned results, got: #{inspect(results)}"
    end
  end

  defp materialize_batch_results!(results) do
    raise ArgumentError,
          "Optimize Anything batch evaluator must return an enumerable of aligned results, got: #{inspect(results)}"
  end

  defp normalize_batch_evaluation(adapter, context, {:error, reason}) do
    if adapter.raise_on_exception do
      raise RuntimeError,
            "Optimize Anything batch evaluator failed for pair #{context.example_index}: #{redact_error(reason)}"
    else
      batch_failure_evaluation(context, redact_error(reason), false)
    end
  end

  defp normalize_batch_evaluation(_adapter, context, raw) do
    raw = normalize_batch_result_shape(raw)

    normalized_evaluation(
      raw,
      context.candidate,
      context.output_candidate,
      context.example,
      context.example_index,
      ""
    )
  end

  # Pinned v0.1.4 accepts this legacy transport shape but deliberately ignores
  # its output slot so candidate/result identity cannot be replaced by a batch
  # backend. The BEAM tuple is the direct counterpart of the Python 3-tuple.
  defp normalize_batch_result_shape({score, _ignored_output, side_info}),
    do: {score, side_info || %{}}

  defp normalize_batch_result_shape({score}), do: score
  defp normalize_batch_result_shape({score, nil}), do: {score, %{}}
  defp normalize_batch_result_shape(raw), do: raw

  defp batch_failure_evaluations(contexts, reason) do
    Enum.map(contexts, &batch_failure_evaluation(&1, reason, true))
  end

  defp batch_failure_evaluation(context, reason, transient?) do
    diagnostic =
      %{"error" => reason}
      |> maybe_put_transient_failure(transient?)
      |> Imp.Redaction.redact()

    %{
      score: 0.0,
      output: {0.0, Imp.Redaction.redact(context.output_candidate), diagnostic},
      side_info: diagnostic,
      objective_scores: %{},
      trajectory:
        trajectory(
          context.example_index,
          context.example,
          context.output_candidate,
          0.0,
          diagnostic,
          %{},
          diagnostic["error"]
        )
    }
  end

  defp maybe_put_transient_failure(diagnostic, true),
    do: Map.put(diagnostic, "_imp_transient_batch_failure", true)

  defp maybe_put_transient_failure(diagnostic, false), do: diagnostic

  defp result_from_evaluations(
         adapter,
         candidate,
         evaluations,
         capture_traces,
         record_completeness?
       ) do
    outputs = Enum.map(evaluations, & &1.output)
    scores = Enum.map(evaluations, & &1.score)
    objectives = Enum.map(evaluations, & &1.objective_scores)
    components = Map.keys(candidate)
    trajectories = Enum.map(evaluations, & &1.trajectory)
    failures = Enum.count(evaluations, &(not is_nil(&1.trajectory.error)))

    metadata = %{failures: failures, mode: adapter.mode}

    metadata =
      if record_completeness?, do: Map.put(metadata, :complete?, failures == 0), else: metadata

    Result.new(outputs, scores,
      objective_scores: objectives,
      trajectories: component_trajectories(components, trajectories, capture_traces),
      side_information: component_side_information(components, evaluations),
      metadata: metadata
    )
  end

  defp public_example(:single_task, _example), do: nil
  defp public_example(_mode, example), do: example

  defp call_evaluator_with_stdio(%{capture_stdio: false} = adapter, candidate, example, state) do
    {:ok, evaluate_candidate(adapter, candidate, example, state), ""}
  end

  defp call_evaluator_with_stdio(%{capture_stdio: true} = adapter, candidate, example, state) do
    case StdioCapture.capture(fn -> evaluate_candidate(adapter, candidate, example, state) end) do
      {{:ok, raw}, captured_stdout} ->
        {:ok, raw, captured_stdout}

      {{:raised, kind, reason, stacktrace}, captured_stdout} ->
        {:raised, kind, reason, stacktrace, captured_stdout}
    end
  end

  defp evaluate_candidate(%{refiner: nil} = adapter, candidate, example, state) do
    call_evaluator(adapter, evaluator_candidate(candidate, adapter), example, state)
  end

  defp evaluate_candidate(%{refiner: refiner} = adapter, candidate, example, state) do
    evaluator = fn refined_candidate ->
      call_evaluator(adapter, evaluator_candidate(refined_candidate, adapter), example, state)
    end

    result =
      Refiner.execute(
        Keyword.merge(refiner,
          candidate: candidate,
          example: example,
          evaluator: evaluator,
          on_evaluation: fn evaluation ->
            update_optimization_state(adapter, example, evaluation.score, evaluation.asi)
          end
        )
      )

    {:imp_refined, result}
  end

  defp call_evaluator(
         %{mode: :single_task, evaluator_contract: :standard} = adapter,
         candidate,
         _,
         _
       )
       when not is_nil(adapter.evaluator),
       do: adapter.evaluator.(candidate)

  defp call_evaluator(
         %{mode: :single_task, evaluator_contract: :with_optimization_state} = adapter,
         candidate,
         _,
         state
       )
       when not is_nil(adapter.evaluator),
       do: adapter.evaluator.(candidate, state)

  defp call_evaluator(%{evaluator_contract: :standard} = adapter, candidate, example, _)
       when not is_nil(adapter.evaluator),
       do: adapter.evaluator.(candidate, example)

  defp call_evaluator(
         %{evaluator_contract: :with_optimization_state} = adapter,
         candidate,
         example,
         state
       )
       when not is_nil(adapter.evaluator),
       do: adapter.evaluator.(candidate, example, state)

  defp call_evaluator(%{evaluator: nil} = adapter, candidate, example, state) do
    public_example = public_example(adapter.mode, example)

    results =
      adapter.batch_evaluator
      |> call_batch_evaluator([{candidate, public_example}], [state])
      |> materialize_batch_results!()

    case results do
      [raw] ->
        normalize_batch_result_shape(raw)

      raw ->
        raise ArgumentError,
              "Optimize Anything batch evaluator returned #{length(raw)} results but expected 1"
    end
  end

  defp normalized_evaluation(
         raw,
         engine_candidate,
         public_candidate,
         example,
         index,
         captured_stdout
       ) do
    {raw, evaluated_candidate} = unwrap_internal_result(raw, public_candidate)
    {score, side_info} = normalize_result!(raw)
    validate_score!(score)
    validate_side_info!(side_info)

    side_info = side_info |> merge_captured_stdout(captured_stdout) |> Imp.Redaction.redact()
    objective_scores = objective_scores!(side_info, Map.keys(engine_candidate))
    output = {score, Imp.Redaction.redact(evaluated_candidate), side_info}

    %{
      score: score,
      output: output,
      side_info: side_info,
      objective_scores: objective_scores,
      trajectory:
        trajectory(index, example, public_candidate, score, side_info, objective_scores, nil)
    }
  end

  defp unwrap_internal_result({:imp_refined, %Refiner.Result{} = result}, _candidate) do
    {%{score: result.score, asi: result.asi}, result.candidate}
  end

  defp unwrap_internal_result(raw, candidate), do: {raw, candidate}

  defp refined_result?({:imp_refined, %Refiner.Result{}}), do: true
  defp refined_result?(_raw), do: false

  defp merge_captured_stdout(side_info, ""), do: side_info

  defp merge_captured_stdout(side_info, captured_stdout) do
    key = if has_string_key?(side_info, "stdout"), do: "_gepa_stdout", else: "stdout"
    Map.put(side_info, key, captured_stdout)
  end

  defp has_string_key?(map, expected) do
    Enum.any?(map, fn {key, _value} -> to_string(key) == expected end)
  end

  defp normalize_result!(score) when is_number(score), do: {score, %{}}
  defp normalize_result!({score, side_info}), do: {score, side_info}

  defp normalize_result!(%Anything.Evaluation{} = evaluation) do
    {evaluation.score,
     %{
       "diagnostics" => evaluation.diagnostics,
       "metadata" => evaluation.metadata
     }}
  end

  defp normalize_result!(%{score: score} = evaluation) do
    side_info =
      Map.get(evaluation, :side_info, Map.get(evaluation, :asi, Map.drop(evaluation, [:score])))

    {score, side_info}
  end

  defp normalize_result!(%{"score" => score} = evaluation) do
    side_info =
      Map.get(
        evaluation,
        "side_info",
        Map.get(evaluation, "asi", Map.drop(evaluation, ["score"]))
      )

    {score, side_info}
  end

  defp normalize_result!(result) do
    raise ArgumentError,
          "Optimize Anything evaluator must return a numeric score, {score, side_info}, or an Evaluation-like map; got: #{inspect(result)}"
  end

  defp validate_score!(score) when is_number(score), do: :ok

  defp validate_score!(score) do
    raise ArgumentError,
          "Optimize Anything evaluator score must be numeric, got: #{inspect(score)}"
  end

  defp validate_side_info!(side_info) when is_map(side_info), do: :ok

  defp validate_side_info!(side_info) do
    raise ArgumentError,
          "Optimize Anything evaluator side_info must be a map, got: #{inspect(side_info)}"
  end

  defp objective_scores!(side_info, components) do
    top_level = fetch_scores!(side_info, "scores", "top-level")

    Enum.reduce(components, top_level, &merge_component_objectives(&1, &2, side_info))
  end

  defp merge_component_objectives(component, scores, side_info) do
    case fetch_by_string(side_info, "#{component}_specific_info") do
      :error ->
        scores

      {:ok, specific_info} when is_map(specific_info) ->
        specific_info
        |> fetch_scores!("scores", "#{component}_specific_info")
        |> Map.new(fn {name, score} -> {"#{component}::#{name}", score} end)
        |> Map.merge(scores)

      {:ok, specific_info} ->
        raise ArgumentError,
              "Optimize Anything #{component}_specific_info must be a map, got: #{inspect(specific_info)}"
    end
  end

  defp fetch_scores!(container, key, context) do
    case fetch_by_string(container, key) do
      :error ->
        %{}

      {:ok, scores} when is_map(scores) ->
        unless Enum.all?(scores, &valid_objective_entry?/1) do
          raise ArgumentError,
                "Optimize Anything #{context} scores must be a map with numeric values"
        end

        scores

      {:ok, scores} ->
        raise ArgumentError,
              "Optimize Anything #{context} scores must be a map, got: #{inspect(scores)}"
    end
  end

  defp valid_objective_entry?({name, score}),
    do: (is_atom(name) or is_binary(name)) and is_number(score)

  defp component_side_information(components, evaluations) do
    Map.new(components, fn component ->
      information = Enum.map(evaluations, &component_information(&1.side_info, component))
      {component, information}
    end)
  end

  defp component_information(side_info, component) do
    Enum.reduce(side_info, %{}, fn {key, value}, information ->
      key_string = to_string(key)

      cond do
        String.ends_with?(key_string, "_specific_info") and
          key_string == "#{component}_specific_info" and is_map(value) ->
          Map.merge(information, value)

        String.ends_with?(key_string, "_specific_info") ->
          information

        true ->
          Map.put(information, key, value)
      end
    end)
  end

  defp component_trajectories(_components, _trajectories, false), do: %{}

  defp component_trajectories(components, trajectories, true) do
    Map.new(components, &{&1, trajectories})
  end

  defp trajectory(index, example, candidate, score, side_info, objectives, error) do
    %Trajectory{
      runtime: :optimize_anything,
      index: index,
      example: Imp.Redaction.redact(example),
      prediction: Imp.Redaction.redact(candidate),
      trace: [],
      score: score,
      feedback: side_info,
      metric_metadata: %{objective_scores: objectives},
      error: error
    }
  end

  defp resolve_task_result(
         {:ok, {:raised, kind, reason, stacktrace, candidate, example, index}},
         true
       ) do
    _ = {candidate, example, index}
    :erlang.raise(kind, reason, stacktrace)
  end

  defp resolve_task_result(
         {:ok, {:raised, kind, reason, stacktrace, candidate, example, index, _captured_stdout}},
         true
       ) do
    _ = {candidate, example, index}
    :erlang.raise(kind, reason, stacktrace)
  end

  defp resolve_task_result(
         {:ok, {:raised, _kind, reason, _stacktrace, candidate, example, index}},
         false
       ) do
    diagnostic = %{"error" => redact_error(reason)}

    %{
      score: 0.0,
      output: nil,
      side_info: diagnostic,
      objective_scores: %{},
      trajectory: trajectory(index, example, candidate, 0.0, diagnostic, %{}, diagnostic["error"])
    }
  end

  defp resolve_task_result(
         {:ok, {:raised, _kind, reason, _stacktrace, candidate, example, index, captured_stdout}},
         false
       ) do
    diagnostic =
      %{"error" => redact_error(reason)}
      |> merge_captured_stdout(captured_stdout)
      |> Imp.Redaction.redact()

    %{
      score: 0.0,
      output: nil,
      side_info: diagnostic,
      objective_scores: %{},
      trajectory: trajectory(index, example, candidate, 0.0, diagnostic, %{}, diagnostic["error"])
    }
  end

  defp resolve_task_result({:ok, evaluation}, _raise_on_exception), do: evaluation

  defp resolve_task_result({:exit, reason}, true) do
    raise RuntimeError, "Optimize Anything evaluator task exited: #{redact_error(reason)}"
  end

  defp resolve_task_result({:exit, {{example, index}, reason}}, false) do
    task_exit_evaluation(example, index, reason)
  end

  defp resolve_task_result({:exit, reason}, false), do: task_exit_evaluation(nil, -1, reason)

  defp task_exit_evaluation(example, index, reason) do
    diagnostic = %{"error" => "evaluator task exited: #{redact_error(reason)}"}

    %{
      score: 0.0,
      output: nil,
      side_info: diagnostic,
      objective_scores: %{},
      trajectory: trajectory(index, example, nil, 0.0, diagnostic, %{}, diagnostic["error"])
    }
  end

  defp raw_side_information(result, component) do
    case Map.get(result.trajectories, component) do
      trajectories when is_list(trajectories) and trajectories != [] ->
        Enum.map(trajectories, fn
          %Trajectory{feedback: feedback} when is_map(feedback) -> feedback
          _trajectory -> %{}
        end)

      _other ->
        Map.get(result.side_information, component, [])
    end
  end

  defp reflection_record(side_info, component) do
    side_info
    |> Enum.reduce(%{}, fn {key, value}, record ->
      key_string = to_string(key)

      cond do
        key_string == "scores" ->
          Map.put(record, "Scores (Higher is Better)", value)

        key_string == "#{component}_specific_info" and is_map(value) ->
          Map.merge(record, stringify_keys(value))

        String.ends_with?(key_string, "_specific_info") ->
          record

        true ->
          Map.put(record, key_string, value)
      end
    end)
    |> Imp.Redaction.redact()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp evaluator_candidate(candidate, %{candidate_format: :named}), do: candidate

  defp evaluator_candidate(candidate, %{
         candidate_format: :structured,
         structured_codec: codec
       }),
       do: StructuredCandidate.decode_candidate!(codec, candidate)

  defp evaluator_candidate(candidate, %{candidate_format: :string, candidate_key: key}) do
    case fetch_candidate_component(candidate, key) do
      {:ok, value} ->
        value

      :error when map_size(candidate) == 1 ->
        candidate |> Map.values() |> hd()

      :error ->
        raise ArgumentError,
              "string candidate format requires component #{inspect(key)}, got: #{inspect(Map.keys(candidate))}"
    end
  end

  defp fetch_candidate_component(candidate, key) do
    case Map.fetch(candidate, key) do
      {:ok, _value} = found -> found
      :error -> fetch_by_string(candidate, to_string(key))
    end
  end

  defp output_candidate(candidate, %{candidate_format: :structured} = adapter),
    do: evaluator_candidate(candidate, adapter)

  defp output_candidate(candidate, _adapter), do: candidate

  defp fetch_by_string(map, expected) do
    Enum.find_value(map, :error, fn {key, value} ->
      if to_string(key) == expected, do: {:ok, value}, else: false
    end)
  end

  defp optimization_state(%__MODULE__{} = adapter, state_source, example) do
    state = initial_optimization_state(state_source, example)
    initial_evaluations = top_evaluations(state.best_example_evals, adapter.best_example_evals_k)

    Agent.get(adapter.optimization_state_store, fn states ->
      case Map.fetch(states, example) do
        {:ok, best_example_evals} ->
          %OptimizationState{best_example_evals: best_example_evals}

        :error ->
          %OptimizationState{best_example_evals: initial_evaluations}
      end
    end)
  end

  defp initial_optimization_state(%OptimizationState{} = state, _example), do: state

  defp initial_optimization_state(provider, example) when is_function(provider, 1) do
    case provider.(example) do
      %OptimizationState{} = state -> state
      state -> raise ArgumentError, "optimization state provider returned: #{inspect(state)}"
    end
  end

  defp update_optimization_state(adapter, example, score, side_info) do
    record = %{score: score, side_info: side_info}

    Agent.update(adapter.optimization_state_store, fn states ->
      Map.update(
        states,
        example,
        top_evaluations([record], adapter.best_example_evals_k),
        fn evaluations ->
          top_evaluations([record | evaluations], adapter.best_example_evals_k)
        end
      )
    end)
  end

  defp top_evaluations(evaluations, limit) do
    evaluations
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  # The store is supervised under Imp.Optimize.Anything.StateStoreSupervisor so
  # it survives the exit of whichever process happened to call new/3 — the
  # adapter struct is a value and may be used from any process. Its lifecycle
  # ends through exactly one path: an explicit close/1 (or application
  # shutdown, when the supervisor terminates it). `restart: :temporary` keeps
  # the supervisor from resurrecting a closed store.
  defp start_optimization_state_store do
    {:ok, store} =
      DynamicSupervisor.start_child(
        Imp.Optimize.Anything.StateStoreSupervisor,
        %{
          id: __MODULE__.OptimizationStateStore,
          start: {Agent, :start_link, [fn -> %{} end]},
          restart: :temporary
        }
      )

    store
  end

  defp validate_adapter!(adapter) do
    validate_member!(:candidate_format, adapter.candidate_format, @candidate_formats)
    validate_member!(:evaluator_contract, adapter.evaluator_contract, @contracts)
    validate_candidate_key!(adapter.candidate_key)
    validate_structured_codec!(adapter.candidate_format, adapter.structured_codec)
    validate_state_source!(adapter.optimization_state)
    validate_refiner!(adapter.refiner)
    validate_best_example_evals_k!(adapter.best_example_evals_k)

    unless is_boolean(adapter.raise_on_exception) do
      raise ArgumentError, ":raise_on_exception must be a boolean"
    end

    unless is_boolean(adapter.capture_stdio) do
      raise ArgumentError, ":capture_stdio must be a boolean"
    end

    unless is_integer(adapter.max_concurrency) and adapter.max_concurrency > 0 do
      raise ArgumentError, ":max_concurrency must be a positive integer"
    end

    unless adapter.timeout == :infinity or (is_integer(adapter.timeout) and adapter.timeout > 0) do
      raise ArgumentError, ":timeout must be :infinity or a positive integer"
    end

    expected_arity = expected_arity(adapter.mode, adapter.evaluator_contract)

    unless is_nil(adapter.evaluator) or is_function(adapter.evaluator, expected_arity) do
      raise ArgumentError,
            "#{adapter.mode} evaluator with #{adapter.evaluator_contract} contract must have arity #{expected_arity}"
    end

    unless is_nil(adapter.batch_evaluator) or is_function(adapter.batch_evaluator, 1) or
             is_function(adapter.batch_evaluator, 2) do
      raise ArgumentError,
            "batch evaluator must have arity 1 (pairs) or arity 2 (pairs, optimization_states)"
    end

    if is_nil(adapter.evaluator) and is_nil(adapter.batch_evaluator) do
      raise ArgumentError, "Optimize Anything adapter requires evaluator or batch_evaluator"
    end

    adapter
  end

  defp expected_arity(:single_task, :standard), do: 1
  defp expected_arity(:single_task, :with_optimization_state), do: 2
  defp expected_arity(_mode, :standard), do: 2
  defp expected_arity(_mode, :with_optimization_state), do: 3

  defp validate_mode!(mode), do: validate_member!(:mode, mode, @modes)

  defp validate_member!(name, value, allowed) do
    unless value in allowed do
      raise ArgumentError, "#{name} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
    end
  end

  defp validate_options!(opts) do
    allowed = [
      :candidate_format,
      :candidate_key,
      :structured_codec,
      :evaluator_contract,
      :optimization_state,
      :checkpoint_identity,
      :refiner,
      :best_example_evals_k,
      :batch_evaluator,
      :capture_stdio,
      :raise_on_exception,
      :max_concurrency,
      :timeout
    ]

    case Keyword.keys(opts) -- allowed do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown Optimize Anything adapter options: #{inspect(unknown)}"
    end
  end

  defp validate_candidate_key!(key) when is_atom(key) or is_binary(key), do: :ok

  defp validate_candidate_key!(key) do
    raise ArgumentError, ":candidate_key must be an atom or string, got: #{inspect(key)}"
  end

  defp validate_structured_codec!(:structured, %StructuredCandidate{}), do: :ok
  defp validate_structured_codec!(format, nil) when format in [:named, :string], do: :ok

  defp validate_structured_codec!(:structured, value) do
    raise ArgumentError,
          ":structured candidate format requires a StructuredCandidate codec, got: #{inspect(value)}"
  end

  defp validate_structured_codec!(format, %StructuredCandidate{}) do
    raise ArgumentError,
          "structured candidate codec cannot be combined with #{inspect(format)} candidate format"
  end

  defp validate_refiner!(nil), do: :ok

  defp validate_refiner!(refiner) when is_list(refiner) and refiner != [] do
    if Keyword.keyword?(refiner),
      do: :ok,
      else: raise(ArgumentError, ":refiner must be a keyword list")
  end

  defp validate_refiner!(refiner) do
    raise ArgumentError,
          ":refiner must be nil or a non-empty keyword list, got: #{inspect(refiner)}"
  end

  defp validate_best_example_evals_k!(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_best_example_evals_k!(_value) do
    raise ArgumentError, ":best_example_evals_k must be a non-negative integer"
  end

  defp validate_state_source!(%OptimizationState{}), do: :ok
  defp validate_state_source!(provider) when is_function(provider, 1), do: :ok

  defp validate_state_source!(source) do
    raise ArgumentError,
          ":optimization_state must be an OptimizationState or an arity-1 provider, got: #{inspect(source)}"
  end

  defp validate_batch!(:single_task, [_single]), do: :ok
  defp validate_batch!(:single_task, batch), do: raise_single_task_batch!(batch)
  defp validate_batch!(_mode, _batch), do: :ok

  defp raise_single_task_batch!(batch) do
    raise ArgumentError,
          "single_task evaluation requires exactly one sentinel example, got: #{length(batch)}"
  end

  defp redact_error(%{__exception__: true} = exception) do
    exception |> Exception.message() |> Imp.Redaction.redact()
  end

  defp redact_error(reason), do: reason |> inspect() |> Imp.Redaction.redact()
end
