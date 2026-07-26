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
    Tracking
  }

  alias Imp.Optimizer.GEPA.{Candidate, Engine}

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
    :fallback_max_iterations,
    :fallback_proposer,
    :objective,
    :optimization_state,
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
    validate_runtime_support!(config, opts)

    {candidate, candidate_format, string_key, structured_codec} =
      normalize_seed(seed_candidate, config, opts, trainset)

    validate_candidate_support!(structured_codec, config)
    candidate = inject_refiner_prompt(candidate, config, opts)

    adapter_opts =
      [
        candidate_format: candidate_format,
        candidate_key: string_key || @string_candidate_key,
        structured_codec: structured_codec,
        evaluator_contract: Keyword.get(opts, :evaluator_contract, :standard),
        batch_evaluator: Keyword.get(opts, :batch_evaluator),
        raise_on_exception: config.engine.raise_on_exception,
        best_example_evals_k: config.engine.best_example_evals_k,
        capture_stdio: config.engine.capture_stdio,
        refiner: refiner_options(config),
        max_concurrency: max_concurrency(config),
        timeout: Keyword.get(opts, :timeout, 30_000)
      ]
      |> maybe_put(:optimization_state, Keyword.get(opts, :optimization_state))

    resolved_resume_state = resume_state(config, Keyword.get(opts, :resume_state))

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

  defp normalize_seed(nil, config, opts, trainset) do
    objective = Keyword.get(opts, :objective)

    unless is_binary(objective) and String.trim(objective) != "" do
      raise ArgumentError, "Optimize Anything seedless mode requires a non-empty :objective"
    end

    lm = config.reflection.reflection_lm

    if is_nil(lm) do
      raise ArgumentError, "Optimize Anything seedless mode requires reflection.reflection_lm"
    end

    generated = generate_seed!(lm, objective, Keyword.get(opts, :background), trainset)
    {%{@string_candidate_key => generated}, :string, @string_candidate_key, nil}
  end

  defp normalize_seed(seed, _config, _opts, _trainset) when is_binary(seed),
    do: {%{@string_candidate_key => seed}, :string, @string_candidate_key, nil}

  defp normalize_seed(seed, _config, _opts, _trainset) when is_map(seed) do
    if Enum.all?(seed, fn {_component, value} -> is_binary(value) end) do
      {Candidate.validate!(seed), :named, nil, nil}
    else
      codec = StructuredCandidate.new!(seed)
      {StructuredCandidate.encode_candidate!(codec, seed), :structured, nil, codec}
    end
  end

  defp normalize_seed(seed, _config, _opts, _trainset) do
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

  defp proposer(config, opts, structured_codec) do
    cond do
      not is_nil(config.reflection.reflection_strategy) ->
        # The released GEPA strategy API owns reflective mutation. Engine.run/6
        # still accepts a proposer for the non-strategy path, so keep that
        # requirement explicit without accidentally invoking another proposal
        # source or requiring a reflection LM.
        fn _candidate, _component, _records, _iteration ->
          raise "reflection_strategy owns Optimize Anything proposals"
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

      response =
        lm
        |> Imp.LM.generate([%{role: :user, content: Multimodal.content(prompt, images)}], [])
        |> lm_text!()

      if structured_codec,
        do:
          StructuredCandidate.normalize_proposal(structured_codec, component, current, response),
        else: extract_fenced_text(response)
    end
  end

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

  defp validate_candidate_support!(nil, _config), do: :ok

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
