defmodule Imp.Optimize.Anything.Runner do
  @moduledoc false

  alias Imp.Optimize.Anything.{
    Adapter,
    BestOutputWriter,
    Config,
    Multimodal,
    Progress,
    Result,
    StructuredCandidate,
    StructuredStrategy,
    Tracking
  }

  alias Imp.Optimizer.GEPA.{Candidate, CandidateSelector, Engine}

  @string_candidate_key :current_candidate
  @single_instance :__imp_optimize_anything_single_instance__
  @default_refiner_prompt """
  You are a refinement agent improving candidates in an optimization loop.

  ## What We're Optimizing For
  The overall optimization objective is:
  <objective>

  This tells you what "better" means - use it to guide your improvements.

  ## Domain Knowledge
  <background>

  ## Your Task
  Given a candidate and its evaluation feedback:
  1. Understand why it scored the way it did
  2. Fix any errors (errors = zero score)
  3. Make improvements that move toward the objective
  4. Return the complete improved candidate
  """
  @option_keys [
    :background,
    :batch_evaluator,
    :checkpoint_fn,
    :config,
    :dataset,
    :evaluator_contract,
    :evaluator_identity,
    :fallback_max_iterations,
    :fallback_proposer,
    :objective,
    :optimization_state,
    :proposal_identity,
    :resume_state,
    :timeout,
    :valset
  ]

  @spec run(String.t() | map() | nil, function() | nil, keyword()) :: Result.t()
  def run(seed_candidate, evaluator, opts)
      when (is_function(evaluator) or is_nil(evaluator)) and is_list(opts) do
    validate_options!(opts)
    validate_evaluation_transports!(evaluator, Keyword.get(opts, :batch_evaluator))
    config = resolve_config(Keyword.get(opts, :config))
    {mode, trainset, valset} = datasets(opts)
    evaluator_contract = resolve_evaluator_contract(evaluator, mode, opts)
    validate_runtime_support!(config, opts)

    evaluator_identity = validate_evaluator_identity!(Keyword.get(opts, :evaluator_identity))
    proposal_identity = validate_proposal_identity!(Keyword.get(opts, :proposal_identity))
    resolved_resume_state = resume_state(config, Keyword.get(opts, :resume_state))

    {candidate, candidate_format, string_key, structured_codec} =
      normalize_seed(seed_candidate, config, opts, trainset, resolved_resume_state)

    validate_candidate_support!(structured_codec, config)
    candidate = inject_refiner_prompt(candidate, config, opts)

    adapter_opts =
      [
        candidate_format: candidate_format,
        candidate_key: string_key || @string_candidate_key,
        structured_codec: structured_codec,
        checkpoint_identity:
          checkpoint_identity(
            config,
            mode,
            trainset,
            valset,
            evaluator,
            Keyword.get(opts, :batch_evaluator),
            evaluator_contract,
            evaluator_identity,
            proposal_identity,
            opts
          ),
        evaluator_contract: evaluator_contract,
        batch_evaluator: Keyword.get(opts, :batch_evaluator),
        raise_on_exception: config.engine.raise_on_exception,
        best_example_evals_k: config.engine.best_example_evals_k,
        capture_stdio: config.engine.capture_stdio,
        refiner: refiner_options(config),
        cache_evaluation: config.engine.cache_evaluation,
        max_concurrency: max_concurrency(config),
        timeout: Keyword.get(opts, :timeout, 30_000)
      ]
      |> maybe_put(:optimization_state, Keyword.get(opts, :optimization_state))

    if structured_codec,
      do: StructuredCandidate.validate_checkpoint!(structured_codec, resolved_resume_state)

    {runtime_callbacks, runtime_resources} = runtime_services(config)
    adapter = open_adapter(evaluator, mode, adapter_opts, runtime_resources)

    engine_opts =
      config
      |> Config.to_engine_options()
      |> Keyword.update!(:callbacks, &(runtime_callbacks ++ &1))
      |> Keyword.merge(
        resume_state: resolved_resume_state,
        checkpoint_fn: checkpoint_callback(config, Keyword.get(opts, :checkpoint_fn))
      )
      |> Keyword.put(:reject_identical_candidate, not is_nil(structured_codec))
      |> put_structured_strategy(config, structured_codec)
      |> normalize_iteration_limit(opts)

    try do
      state =
        Engine.run(
          adapter,
          Candidate.validate!(candidate),
          trainset,
          valset,
          proposer(config, opts, structured_codec),
          engine_opts
        )

      result =
        Result.from_state(state,
          mode: mode,
          run_dir: config.engine.run_dir,
          seed: config.engine.seed,
          string_candidate_key: string_key,
          candidate_decoder: candidate_decoder(structured_codec)
        )

      close_runtime_resources(runtime_resources, :finished)
      result
    catch
      kind, reason ->
        close_runtime_resources(runtime_resources, :failed)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Adapter.close(adapter)
    end
  end

  def run(_seed_candidate, evaluator, opts) do
    raise ArgumentError,
          "Optimize Anything expects an evaluator function or nil and keyword options, got: " <>
            "#{inspect(evaluator)}, #{inspect(opts)}"
  end

  defp validate_evaluation_transports!(nil, nil) do
    raise ArgumentError,
          "Optimize Anything requires :batch_evaluator when evaluator is nil; provide one or both evaluation transports"
  end

  defp validate_evaluation_transports!(evaluator, batch_evaluator) do
    unless is_nil(evaluator) or is_function(evaluator) do
      raise ArgumentError, "Optimize Anything evaluator must be a function or nil"
    end

    unless is_nil(batch_evaluator) or is_function(batch_evaluator, 1) or
             is_function(batch_evaluator, 2) do
      raise ArgumentError,
            "Optimize Anything :batch_evaluator must have arity 1 (pairs) or arity 2 (pairs, optimization_states)"
    end

    :ok
  end

  defp resolve_config(nil), do: Config.new()
  defp resolve_config(%Config{} = config), do: config
  defp resolve_config(opts) when is_list(opts), do: Config.new(opts)
  defp resolve_config(map) when is_map(map), do: Config.from_map(map)

  defp resolve_config(value) do
    raise ArgumentError,
          "Optimize Anything :config must be a Config struct, keyword list, or persisted map; got: #{inspect(value)}"
  end

  defp datasets(opts) do
    opts
    |> then(&{Keyword.get(&1, :dataset), Keyword.get(&1, :valset)})
    |> dataset_mode()
  end

  defp dataset_mode({nil, nil}),
    do: {:single_task, [@single_instance], [@single_instance]}

  defp dataset_mode({dataset, nil}) when is_list(dataset) and dataset != [],
    do: {:multi_task, dataset, dataset}

  defp dataset_mode({dataset, valset})
       when is_list(dataset) and dataset != [] and is_list(valset) and valset != [],
       do: {:generalization, dataset, valset}

  defp dataset_mode({nil, valset}) when is_list(valset) do
    raise ArgumentError,
          "Optimize Anything requires :dataset when :valset is provided; the public contract has exactly three modes"
  end

  defp dataset_mode({dataset, valset}) do
    raise ArgumentError,
          "Optimize Anything :dataset and :valset must be non-empty lists or nil, got: " <>
            "#{inspect(dataset)}, #{inspect(valset)}"
  end

  # Python can opt an evaluator into OptimizationState by inspecting the
  # reserved `opt_state` parameter name. Elixir callback parameters have no
  # stable runtime names, but the complete public forms are unambiguous by
  # arity: candidate+state in single-task mode, and
  # candidate+example+state when a dataset is present. An explicit contract
  # remains authoritative, including its fail-closed arity validation.
  defp resolve_evaluator_contract(evaluator, mode, opts) do
    if Keyword.has_key?(opts, :evaluator_contract) do
      Keyword.fetch!(opts, :evaluator_contract)
    else
      inferred_evaluator_contract(evaluator, mode)
    end
  end

  defp inferred_evaluator_contract(evaluator, :single_task)
       when is_function(evaluator, 2),
       do: :with_optimization_state

  defp inferred_evaluator_contract(evaluator, mode)
       when mode in [:multi_task, :generalization] and is_function(evaluator, 3),
       do: :with_optimization_state

  defp inferred_evaluator_contract(_evaluator, _mode), do: :standard

  defp normalize_seed(nil, config, opts, trainset, resume_state) do
    objective = Keyword.get(opts, :objective)

    unless is_binary(objective) and String.trim(objective) != "" do
      raise ArgumentError, "Optimize Anything seedless mode requires a non-empty :objective"
    end

    lm = config.reflection.reflection_lm

    if is_nil(lm) do
      raise ArgumentError, "Optimize Anything seedless mode requires reflection.reflection_lm"
    end

    generated =
      if is_nil(resume_state) do
        generate_seed!(lm, objective, Keyword.get(opts, :background), trainset)
      else
        resumed_seed!(resume_state)
      end

    {%{@string_candidate_key => generated}, :string, @string_candidate_key, nil}
  end

  defp normalize_seed(seed, _config, _opts, _trainset, _resume_state) when is_binary(seed),
    do: {%{@string_candidate_key => seed}, :string, @string_candidate_key, nil}

  defp normalize_seed(seed, config, _opts, _trainset, _resume_state) when is_map(seed) do
    if Enum.all?(seed, fn {_component, value} -> is_binary(value) end) do
      {Candidate.validate!(seed), :named, nil, nil}
    else
      strategy_identity =
        case config.reflection.structured_strategy do
          nil -> nil
          strategy -> StructuredStrategy.identity(strategy)
        end

      codec =
        StructuredCandidate.new!(
          seed,
          config.reflection.structured_response_format,
          strategy_identity
        )

      {StructuredCandidate.encode_candidate!(codec, seed), :structured, nil, codec}
    end
  end

  defp normalize_seed(seed, _config, _opts, _trainset, _resume_state) do
    raise ArgumentError,
          "Optimize Anything seed must be a binary, a named text map, a JSON-safe structured map, or nil; got: #{inspect(seed)}"
  end

  defp generate_seed!(lm, objective, background, trainset) do
    samples = trainset |> Enum.reject(&(&1 == @single_instance)) |> Enum.take(3)

    prompt =
      [
        "Generate an initial candidate that will be iteratively optimized.",
        "Goal:\n#{objective}",
        optional_section("Domain context and constraints", background),
        optional_section(
          "Sample inputs",
          if(samples == [], do: nil, else: inspect(samples, pretty: true, limit: 20))
        ),
        "Return only the complete candidate inside a fenced code block."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    lm
    |> Imp.LM.generate([%{role: :user, content: prompt}], [])
    |> lm_text!()
    |> extract_fenced_text()
  end

  defp resumed_seed!(%{"candidates" => [%{"candidate" => encoded} | _]}) do
    case Imp.Optimizer.Report.decode_term(encoded) do
      %{@string_candidate_key => seed} when is_binary(seed) -> seed
      _other -> raise ArgumentError, "Optimize Anything seedless resume state has no text seed"
    end
  rescue
    error in [ArgumentError, KeyError] ->
      reraise ArgumentError,
              [
                message:
                  "Optimize Anything seedless resume state is invalid: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp resumed_seed!(_state) do
    raise ArgumentError, "Optimize Anything seedless resume state is invalid"
  end

  defp proposer(config, opts, structured_codec) do
    cond do
      not is_nil(config.reflection.reflection_strategy) or
          not is_nil(config.reflection.structured_strategy) ->
        # The released GEPA strategy API owns reflective mutation. Engine.run/6
        # still accepts a proposer for the non-strategy path, so keep that
        # requirement explicit without accidentally invoking another proposal
        # source or requiring a reflection LM.
        fn _candidate, _component, _records, _iteration ->
          raise "configured strategy owns Optimize Anything proposals"
        end

      is_function(config.reflection.custom_candidate_proposer, 4) ->
        wrap_structured_proposer(
          config.reflection.custom_candidate_proposer,
          structured_codec
        )

      not is_nil(config.reflection.reflection_lm) ->
        reflection_proposer(config, opts, structured_codec)

      is_function(Keyword.get(opts, :fallback_proposer), 4) ->
        wrap_structured_proposer(Keyword.fetch!(opts, :fallback_proposer), structured_codec)

      true ->
        raise ArgumentError,
              "Optimize Anything requires reflection.reflection_lm or an arity-4 custom candidate proposer"
    end
  end

  defp reflection_proposer(config, opts, structured_codec) do
    lm = config.reflection.reflection_lm
    objective = Keyword.get(opts, :objective)
    background = Keyword.get(opts, :background)
    template = config.reflection.reflection_prompt_template

    if not is_nil(template) and (present?(objective) or present?(background)) do
      raise ArgumentError,
            "Optimize Anything cannot combine :objective/:background with a custom reflection prompt template"
    end

    fn candidate, component, records, iteration ->
      {side_information, images} = Multimodal.render(records)
      current = Map.fetch!(candidate, component)

      current_parameter =
        if structured_codec,
          do: StructuredCandidate.render_component(structured_codec, component, current),
          else: current

      prompt =
        render_reflection_prompt(template, %{
          objective: objective,
          background: background,
          component: component,
          current_parameter: current_parameter,
          side_information: side_information,
          iteration: iteration,
          structured?: not is_nil(structured_codec)
        })

      lm_opts = structured_lm_opts(lm, structured_codec, component)

      response =
        lm
        |> Imp.LM.generate(
          [%{role: :user, content: Multimodal.content(prompt, images)}],
          lm_opts
        )
        |> lm_text!()

      if structured_codec,
        do:
          StructuredCandidate.normalize_proposal(structured_codec, component, current, response),
        else: extract_fenced_text(response)
    end
  end

  defp structured_lm_opts(_lm, nil, _component), do: []

  defp structured_lm_opts(_lm, %StructuredCandidate{proposal_contract: :off}, _component),
    do: []

  defp structured_lm_opts(lm, %StructuredCandidate{proposal_contract: :auto} = codec, component) do
    if Imp.LM.response_format_capability(lm).response_schema,
      do: [response_format: StructuredCandidate.response_format(codec, component)],
      else: []
  end

  defp structured_lm_opts(
         _lm,
         %StructuredCandidate{proposal_contract: :required} = codec,
         component
       ),
       do: [response_format: StructuredCandidate.response_format(codec, component)]

  defp render_reflection_prompt(nil, %{structured?: true} = context) do
    """
    You are improving one named component in a structured artifact.

    Goal:
    #{context.objective || "Maximize the evaluator score."}

    Domain context:
    #{context.background || "No additional context."}

    Component: #{context.component}
    Iteration: #{context.iteration}
    Current JSON value:
    ```json
    #{context.current_parameter}
    ```

    Actionable side information:
    #{context.side_information}

    Return only the complete replacement value for this component as strict JSON.
    Preserve every required nested field, list position, and value type. Do not return
    the complete artifact, commentary, or a patch.

    The response is the component value itself, never an object keyed by the component
    name. For a scalar current value such as `500`, return a scalar such as `1000`, not
    `{"#{context.component}": 1000}`. For an object or list current value, return the
    complete replacement object or list with exactly the same shape.

    When the transport supplies a response schema, follow its exact `{\"value\": ...}`
    wrapper. The wrapper is transport framing, not part of the artifact component.
    """
  end

  defp render_reflection_prompt(nil, context) do
    """
    You are improving one named text parameter in an evaluated system.

    Goal:
    #{context.objective || "Maximize the evaluator score."}

    Domain context:
    #{context.background || "No additional context."}

    Parameter: #{context.component}
    Iteration: #{context.iteration}
    Current value:
    ```
    #{context.current_parameter}
    ```

    Actionable side information:
    #{context.side_information}

    Return only a complete drop-in replacement inside a fenced code block.
    """
  end

  defp render_reflection_prompt(template, context) when is_binary(template) do
    template
    |> String.replace("<curr_param>", context.current_parameter)
    |> String.replace("<side_info>", context.side_information)
  end

  defp render_reflection_prompt(templates, context) when is_map(templates) do
    template =
      Map.get(templates, context.component, Map.get(templates, to_string(context.component)))

    if is_binary(template),
      do: render_reflection_prompt(template, context),
      else:
        raise(
          ArgumentError,
          "missing reflection template for component #{inspect(context.component)}"
        )
  end

  defp lm_text!(result), do: result |> Imp.LM.Result.unwrap() |> lm_output_text!()

  defp lm_output_text!({:ok, text}) when is_binary(text), do: text
  defp lm_output_text!({:ok, %{"instruction" => text}}) when is_binary(text), do: text
  defp lm_output_text!({:ok, %{instruction: text}}) when is_binary(text), do: text
  defp lm_output_text!({:ok, %{"new_instruction" => text}}) when is_binary(text), do: text
  defp lm_output_text!({:ok, %{new_instruction: text}}) when is_binary(text), do: text

  defp lm_output_text!({:error, reason}),
    do: raise(RuntimeError, "Optimize Anything reflection LM failed: #{inspect(reason)}")

  defp lm_output_text!(result),
    do:
      raise(
        ArgumentError,
        "Optimize Anything reflection LM returned an invalid result: #{inspect(result)}"
      )

  defp extract_fenced_text(text) do
    case Regex.run(~r/```[^\n]*\n(.*?)```/s, text, capture: :all_but_first) do
      [candidate] -> String.trim(candidate)
      nil -> String.trim(text)
    end
  end

  defp validate_runtime_support!(config, opts) do
    unless stopping_condition?(config, opts) do
      raise ArgumentError,
            "Optimize Anything requires max_metric_calls, max_candidate_proposals, a stopper, or a run_dir"
    end
  end

  defp validate_candidate_support!(nil, %{reflection: %{structured_strategy: nil}}), do: :ok

  defp validate_candidate_support!(nil, %{reflection: %{structured_strategy: strategy}})
       when not is_nil(strategy) do
    raise ArgumentError,
          "structured_strategy requires a native structured artifact seed; text and named-text candidates must use reflection_strategy"
  end

  defp validate_candidate_support!(%StructuredCandidate{}, config) do
    unsupported =
      [
        {:refiner, config.refiner},
        {:merge, config.merge},
        {:reflection_strategy, config.reflection.reflection_strategy},
        {:custom_module_selector,
         if(config.reflection.module_selector in [:round_robin, :all],
           do: nil,
           else: config.reflection.module_selector
         )},
        {:custom_candidate_selector,
         if(
           config.engine.candidate_selection_strategy in [
             :pareto,
             :current_best,
             :epsilon_greedy,
             :top_k_pareto
           ],
           do: nil,
           else: config.engine.candidate_selection_strategy
         )},
        {:custom_evaluation_policy,
         if(config.engine.val_evaluation_policy in [:full_eval, :full],
           do: nil,
           else: config.engine.val_evaluation_policy
         )},
        {:callbacks, if(config.callbacks == [], do: nil, else: config.callbacks)},
        {:tracking,
         if(
           config.tracking.logger == nil and not config.tracking.use_wandb and
             not config.tracking.use_mlflow,
           do: nil,
           else: config.tracking
         )}
      ]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map(&elem(&1, 0))

    if unsupported != [] do
      raise ArgumentError,
            "structured Optimize Anything candidates do not yet support #{inspect(unsupported)}; " <>
              "these extensions consume the GEPA text-engine representation"
    end

    :ok
  end

  defp put_structured_strategy(opts, %{reflection: %{structured_strategy: nil}}, _codec),
    do: opts

  defp put_structured_strategy(opts, config, %StructuredCandidate{} = codec) do
    Keyword.put(
      opts,
      :reflection_strategy,
      StructuredStrategy.bridge(config.reflection.structured_strategy, codec)
    )
  end

  defp put_structured_strategy(_opts, %{reflection: %{structured_strategy: strategy}}, nil)
       when not is_nil(strategy) do
    raise ArgumentError,
          "structured_strategy requires a native structured artifact seed; text and named-text candidates must use reflection_strategy"
  end

  defp inject_refiner_prompt(candidate, %{refiner: nil}, _opts), do: candidate

  defp inject_refiner_prompt(candidate, _config, opts) do
    if Enum.any?(Map.keys(candidate), &(to_string(&1) == "refiner_prompt")) do
      candidate
    else
      objective = Keyword.get(opts, :objective) || "Maximize the score"
      background = Keyword.get(opts, :background) || "No additional background provided."

      prompt =
        @default_refiner_prompt
        |> String.replace("<objective>", objective)
        |> String.replace("<background>", background)

      Map.put(candidate, :refiner_prompt, prompt)
    end
  end

  defp refiner_options(%{refiner: nil}), do: nil

  defp refiner_options(config) do
    lm = config.refiner.refiner_lm || config.reflection.reflection_lm

    if is_nil(lm) do
      raise ArgumentError, "Optimize Anything refiner requires refiner_lm or reflection_lm"
    end

    [
      refiner_lm: lm,
      refiner_prompt: :refiner_prompt,
      refiner_prompt_component: :refiner_prompt,
      max_refinements: config.refiner.max_refinements
    ]
  end

  defp stopping_condition?(config, opts) do
    not is_nil(config.engine.max_metric_calls) or
      not is_nil(config.engine.max_candidate_proposals) or
      not is_nil(config.engine.max_reflection_cost) or
      not is_nil(config.stopper) or
      not is_nil(config.engine.run_dir) or
      Keyword.has_key?(opts, :fallback_max_iterations)
  end

  defp normalize_iteration_limit(engine_opts, opts) do
    if Keyword.has_key?(engine_opts, :max_iterations),
      do: engine_opts,
      else:
        Keyword.put(
          engine_opts,
          :max_iterations,
          Keyword.get(opts, :fallback_max_iterations, 10_000)
        )
  end

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Optimize Anything expects keyword options, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @option_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown Optimize Anything options: #{inspect(unknown)}"
    end

    validate_resume_state!(opts)
    validate_optional_callback!(opts, :checkpoint_fn, 1)
    validate_optional_callback!(opts, :fallback_proposer, 4)

    case Keyword.get(opts, :fallback_max_iterations) do
      nil ->
        :ok

      limit when is_integer(limit) and limit >= 0 ->
        :ok

      value ->
        raise ArgumentError,
              ":fallback_max_iterations must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp validate_optional_callback!(opts, key, arity) do
    case Keyword.get(opts, key) do
      nil ->
        :ok

      callback when is_function(callback, arity) ->
        :ok

      value ->
        raise ArgumentError,
              ":#{key} must be nil or an arity-#{arity} function, got: #{inspect(value)}"
    end
  end

  defp validate_resume_state!(opts) do
    case Imp.Optimize.Anything.validate_resume_state(Keyword.get(opts, :resume_state)) do
      {:ok, _state} -> :ok
      {:error, message} -> raise ArgumentError, ":resume_state #{message}"
    end
  end

  defp max_concurrency(%{engine: %{parallel: false}}), do: 1
  defp max_concurrency(%{engine: %{max_workers: nil}}), do: System.schedulers_online()
  defp max_concurrency(%{engine: %{max_workers: workers}}), do: workers

  defp runtime_services(config) do
    {tracking_callbacks, tracking_resources} = tracking_service(config)
    {progress_callbacks, progress_resources} = progress_service(config)
    callbacks = tracking_callbacks ++ progress_callbacks
    resources = progress_resources ++ tracking_resources

    case config.engine.run_dir do
      nil ->
        {callbacks, resources}

      run_dir ->
        {callback, writer} =
          BestOutputWriter.open(run_dir, config.engine.track_best_outputs)

        {callbacks ++ [callback], [{:best_output_writer, writer} | resources]}
    end
  end

  defp tracking_service(%{tracking: %{use_wandb: false, use_mlflow: false}}), do: {[], []}

  defp tracking_service(%{tracking: tracking}) do
    {callback, session} = Tracking.open(tracking)
    {[callback], [{:tracking, session}]}
  end

  defp progress_service(%{engine: %{display_progress_bar: false}}), do: {[], []}

  defp progress_service(%{engine: engine, stopper: stopper}) do
    total = minimum_limit(engine.max_metric_calls, stopper_metric_limit(stopper))
    {[Progress.callback(total: total)], []}
  end

  defp open_adapter(evaluator, mode, adapter_opts, runtime_resources) do
    Adapter.new(evaluator, mode, adapter_opts)
  catch
    kind, reason ->
      close_runtime_resources(runtime_resources, :failed)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp close_runtime_resources(resources, status) do
    Enum.each(resources, fn
      {:best_output_writer, writer} -> BestOutputWriter.close(writer)
      {:tracking, session} -> Tracking.close(session, status)
    end)
  end

  defp stopper_metric_limit({:max_metric_calls, limit}), do: limit

  defp stopper_metric_limit({kind, policies}) when kind in [:any, :all] do
    policies
    |> Enum.map(&stopper_metric_limit/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp stopper_metric_limit(_policy), do: nil

  defp minimum_limit(nil, right), do: right
  defp minimum_limit(left, nil), do: left
  defp minimum_limit(left, right), do: min(left, right)

  defp checkpoint_identity(
         config,
         mode,
         trainset,
         valset,
         evaluator,
         batch_evaluator,
         evaluator_contract,
         declared_identity,
         proposal_identity,
         opts
       ) do
    %{
      "type" => "imp_optimize_anything_run_identity",
      "schema_version" => 4,
      "mode" => Atom.to_string(mode),
      "trainset_sha256" => dataset_digest!(trainset, :dataset),
      "valset_sha256" => dataset_digest!(valset, :valset),
      "evaluation_sha256" =>
        evaluation_digest!(
          evaluator,
          batch_evaluator,
          evaluator_contract,
          declared_identity
        ),
      "candidate_selection_sha256" =>
        candidate_selection_digest!(config.engine.candidate_selection_strategy),
      "proposal_sha256" => proposal_digest!(config, opts, proposal_identity)
    }
  end

  defp proposal_digest!(config, opts, declared_identity) do
    %{
      objective: Keyword.get(opts, :objective),
      background: Keyword.get(opts, :background),
      reflection_prompt_template: config.reflection.reflection_prompt_template,
      reflection_lm: runtime_identity(config.reflection.reflection_lm),
      custom_candidate_proposer: callback_identity(config.reflection.custom_candidate_proposer),
      fallback_proposer: callback_identity(Keyword.get(opts, :fallback_proposer)),
      declared_identity: declared_identity
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp candidate_selection_digest!(strategy) do
    strategy
    |> CandidateSelector.checkpoint_identity!()
    |> Config.Persistence.json_safe!([:candidate_selection_strategy])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "Optimize Anything candidate selection strategy cannot be checkpoint-identified: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp evaluation_digest!(evaluator, batch_evaluator, contract, declared_identity) do
    %{
      evaluator: callback_identity(evaluator),
      batch_evaluator: callback_identity(batch_evaluator),
      contract: contract,
      declared_identity: declared_identity
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp callback_identity(nil), do: nil

  defp callback_identity(callback) when is_function(callback) do
    Map.new([:module, :name, :arity, :type, :uniq, :index], fn key ->
      value = callback |> :erlang.fun_info(key) |> elem(1)
      {key, if(is_atom(value), do: Atom.to_string(value), else: value)}
    end)
  end

  defp runtime_identity(callback) when is_function(callback), do: callback_identity(callback)
  defp runtime_identity(%_{} = struct), do: struct |> Map.from_struct() |> runtime_identity()

  defp runtime_identity(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, runtime_identity(value)} end)

  defp runtime_identity(list) when is_list(list), do: Enum.map(list, &runtime_identity/1)

  defp runtime_identity(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&runtime_identity/1) |> List.to_tuple()

  defp runtime_identity(pid) when is_pid(pid), do: :runtime_pid
  defp runtime_identity(reference) when is_reference(reference), do: :runtime_reference
  defp runtime_identity(port) when is_port(port), do: :runtime_port
  defp runtime_identity(value), do: value

  defp validate_evaluator_identity!(nil), do: nil

  defp validate_evaluator_identity!(identity) do
    Config.Persistence.json_safe!(identity, [:evaluator_identity])
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "Optimize Anything :evaluator_identity must be JSON-safe versioned data: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp validate_proposal_identity!(nil), do: nil

  defp validate_proposal_identity!(identity) do
    Config.Persistence.json_safe!(identity, [:proposal_identity])
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "Optimize Anything :proposal_identity must be JSON-safe versioned data: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp dataset_digest!(dataset, name) do
    dataset
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "Optimize Anything #{name} cannot be checkpoint-identified: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp resume_state(_config, state) when not is_nil(state), do: state
  defp resume_state(%{engine: %{run_dir: nil}}, nil), do: nil

  defp resume_state(%{engine: %{run_dir: run_dir}}, nil) do
    path = Path.join(run_dir, "gepa_state.json")
    if File.regular?(path), do: path |> File.read!() |> Jason.decode!()
  end

  defp checkpoint_callback(%{engine: %{run_dir: nil}}, callback), do: callback

  defp checkpoint_callback(%{engine: %{run_dir: run_dir}}, callback) do
    fn checkpoint ->
      File.mkdir_p!(run_dir)
      path = Path.join(run_dir, "gepa_state.json")
      temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
      File.write!(temporary, Jason.encode!(checkpoint, pretty: true))
      File.rename!(temporary, path)
      if callback, do: callback.(checkpoint), else: :ok
    end
  end

  defp optional_section(_title, nil), do: nil
  defp optional_section(_title, ""), do: nil
  defp optional_section(title, value), do: "#{title}:\n#{value}"
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp wrap_structured_proposer(proposer, nil), do: proposer

  defp wrap_structured_proposer(proposer, %StructuredCandidate{} = codec),
    do: StructuredCandidate.wrap_proposer(codec, proposer)

  defp candidate_decoder(nil), do: nil

  defp candidate_decoder(%StructuredCandidate{} = codec),
    do: &StructuredCandidate.decode_candidate!(codec, &1)

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
