defmodule Imp.Optimizer.GEPA do
  @behaviour Imp.Optimizer
  @moduledoc """
  Program-level GEPA optimizer for Imp programs.

  The optimizer exposes every predictor through `Imp.ProgramParameters`,
  evaluates named candidate maps through a trace-rich adapter, applies strict
  minibatch improvement before validation, and maintains the source-shaped
  per-instance Pareto archive in its internal optimization engine.

  `:candidate_selection_strategy` controls the parent program sampled for the
  next reflection. It defaults to pinned GEPA's `:pareto` policy and also
  accepts `:current_best`, the other released built-ins, or a validated custom
  `Imp.Optimizer.GEPA.CandidateSelector` module/struct.

  The `:callbacks` option accepts callback modules or `{module, context}`
  tuples implementing any subset of the documented GEPA callback contract.
  Hooks are synchronous and observational; failures are isolated from
  optimization.

  `:component_feedback` maps predictor names to strict arity-one callbacks.
  These callbacks shape reflective minibatches and are part of optimization;
  invalid names, invalid output, and callback failures stop the run.

  `:reflection_record_mode` defaults to `:beam_native`, retaining scores and
  traces alongside feedback. `:gepa_v0_1_4` emits the pinned DSPy adapter's
  narrower `Inputs`/`Generated Outputs`/`Feedback` records and exact reflection
  prompt bytes. The pinned mode rejects the separate global `:feedback_fn`
  extension; use metric/component feedback so every reflection receives the
  same information as upstream.

  `:execution_profile` defaults to `:beam_native`. The opt-in
  `:gepa_v0_1_4` profile seals the pinned single-proposal search semantics:
  CPython's persisted MT19937 stream is shared by Pareto selection and
  Fisher-Yates minibatch sampling, perfect minibatches are skipped at `1.0`,
  evaluation caching is disabled, and one failed batched reflection is retried
  once as the corresponding single task. Like pinned GEPA, `max_metric_calls`
  is checked between iterations: an iteration that legally starts is allowed
  to finish. Separate internal metric/reflection envelopes bound that legal
  overshoot; they are not alternate stopping rules.

  `:proposal_concurrency` enables first-party GEPA speculative parallel
  proposals. Contexts are sampled sequentially from one archive and RNG
  snapshot, expensive proposal phases run concurrently, and all effects are
  applied by proposal slot. This is separate from ComBee aggregation: it does
  not combine worker proposals or use map-shuffle-reduce voting.

  `:module_selector` picks which named components each reflective mutation
  updates: `:round_robin` (default, one component per mutation in stable
  order), `:all` (every component per mutation), an arity-five function, or a
  selector module/struct implementing the `Imp.Optimizer.GEPA.ModuleSelector`
  contract. Custom selectors receive the engine state, captured trajectories,
  minibatch scores, candidate index, and candidate map, and must return a
  non-empty list of the candidate's component names; anything else raises.

  `:combee` accepts `true` or its documented keyword options. ComBee duplicates
  and deterministically shuffles reflection records, reduces `floor(sqrt(n))`
  balanced groups concurrently, and performs one ordered final reduction.
  `:proposal_timeout` bounds reflection work and inherits `:timeout` when
  omitted; a finite nested ComBee timeout is an additional upper bound.
  """

  alias Imp.Optimizer.GEPA.{
    Callback,
    Candidate,
    ComBee,
    ComponentFeedback,
    Engine,
    InstructionProposal,
    ProgramAdapter,
    ReflectionStrategy,
    Stopper
  }

  alias Imp.Optimizer.Report
  alias Imp.Optimizer.Artifact

  defstruct [
    :metric,
    :reflection_lm,
    :reflection_strategy,
    callbacks: [],
    execution_profile: :beam_native,
    component_feedback: %{},
    reflection_record_mode: :beam_native,
    feedback_fn: nil,
    candidate_selection_strategy: :pareto,
    module_selector: :round_robin,
    generations: 4,
    combee: false,
    sampling_strategy: :single,
    selection_strategy: :all_improvements,
    proposal_concurrency: 1,
    proposal_timeout: 30_000,
    max_concurrency: 1,
    timeout: 30_000,
    minibatch_size: nil,
    seed: 0,
    use_merge: false,
    max_merge_invocations: 5,
    merge_val_overlap_floor: 5,
    frontier_type: :instance,
    evaluation_policy: :full,
    acceptance_policy: :strict_improvement,
    merge_acceptance_policy: :equal_or_better,
    raise_on_exception: true,
    skip_perfect_score: false,
    perfect_score: nil,
    cache_evaluation: true,
    rng_algorithm: :beam_native,
    reflection_failure_policy: :single_attempt_fail_closed,
    stopper: nil,
    max_metric_calls: :infinity,
    max_full_evaluations: :infinity,
    max_reflection_calls: :infinity,
    max_reflection_cost: nil
  ]

  @option_schema [
    execution_profile: [type: {:in, [:beam_native, :gepa_v0_1_4]}, default: :beam_native],
    callbacks: [type: {:custom, Callback, :validate, []}, default: []],
    component_feedback: [type: {:custom, ComponentFeedback, :validate, []}, default: %{}],
    reflection_record_mode: [
      type: {:in, [:beam_native, :gepa_v0_1_4]},
      default: :beam_native
    ],
    feedback_fn: [type: {:custom, __MODULE__, :validate_feedback_fn, []}, default: nil],
    candidate_selection_strategy: [type: :any, default: :pareto],
    module_selector: [
      type: {:custom, __MODULE__, :validate_module_selector, []},
      default: :round_robin
    ],
    generations: [type: :non_neg_integer, default: 4],
    combee: [type: {:custom, ComBee.Options, :validate, []}, default: false],
    sampling_strategy: [type: :any, default: :single],
    selection_strategy: [type: :any, default: :all_improvements],
    proposal_concurrency: [
      type: {:custom, __MODULE__, :validate_proposal_concurrency, []},
      default: 1
    ],
    proposal_timeout: [type: {:or, [nil, :timeout]}, default: nil],
    max_concurrency: [type: :pos_integer, default: 1],
    timeout: [type: :timeout, default: 30_000],
    minibatch_size: [type: {:or, [nil, :pos_integer]}, default: nil],
    seed: [type: :non_neg_integer, default: 0],
    use_merge: [type: :boolean, default: false],
    max_merge_invocations: [type: :non_neg_integer, default: 5],
    merge_val_overlap_floor: [type: :pos_integer, default: 5],
    frontier_type: [
      type: {:in, [:instance, :objective, :hybrid, :cartesian]},
      default: :instance
    ],
    evaluation_policy: [type: :any, default: :full],
    acceptance_policy: [type: :any, default: :strict_improvement],
    merge_acceptance_policy: [type: :any, default: :equal_or_better],
    raise_on_exception: [type: :boolean, default: true],
    stopper: [type: :any, default: nil],
    reflection_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    reflection_strategy: [type: :any, default: nil],
    max_metric_calls: [type: :any, default: :infinity],
    max_full_evaluations: [type: :any, default: :infinity],
    max_reflection_calls: [type: :any, default: :infinity],
    max_reflection_cost: [type: :any, default: nil]
  ]

  @compile_option_schema [
    resume_state: [
      type: {:custom, Imp.Optimize.Anything, :validate_resume_state, []},
      default: nil
    ],
    checkpoint_fn: [
      type: {:custom, Imp.Optimize.Anything, :validate_checkpoint_fn, []},
      default: nil
    ]
  ]

  @artifact_option_schema @compile_option_schema ++
                            [
                              artifact_id: [
                                type: {:custom, __MODULE__, :validate_artifact_id, []},
                                default: "gepa-champion"
                              ],
                              provenance: [type: :map, default: %{}]
                            ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, 2, "Imp.Optimizer.GEPA.new/2", "metric")
    requested_opts = opts
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.GEPA.new/2")
    opts = resolve_execution_profile!(requested_opts, opts)
    reflection_strategy = ReflectionStrategy.validate!(opts[:reflection_strategy])
    max_reflection_cost = validate_cost_limit!(opts[:max_reflection_cost])

    if max_reflection_cost &&
         not ReflectionStrategy.cost_observable?(reflection_strategy || opts[:reflection_lm]) do
      raise ArgumentError,
            ":max_reflection_cost requires a reflection strategy or LM with observable total_cost"
    end

    if opts[:reflection_record_mode] == :gepa_v0_1_4 and is_function(opts[:feedback_fn], 1) do
      raise ArgumentError,
            ":feedback_fn adds a non-upstream global reflection record; use metric or component feedback with :reflection_record_mode :gepa_v0_1_4"
    end

    %__MODULE__{
      metric: metric,
      execution_profile: opts[:execution_profile],
      callbacks: opts[:callbacks],
      component_feedback: opts[:component_feedback],
      reflection_record_mode: opts[:reflection_record_mode],
      feedback_fn: opts[:feedback_fn],
      candidate_selection_strategy:
        validate_candidate_selection_strategy!(opts[:candidate_selection_strategy]),
      module_selector: opts[:module_selector],
      generations: opts[:generations],
      combee: opts[:combee],
      sampling_strategy: validate_sampling_strategy!(opts[:sampling_strategy]),
      selection_strategy: validate_selection_strategy!(opts[:selection_strategy]),
      proposal_concurrency: opts[:proposal_concurrency],
      proposal_timeout: opts[:proposal_timeout] || opts[:timeout],
      max_concurrency: opts[:max_concurrency],
      timeout: opts[:timeout],
      minibatch_size: opts[:minibatch_size],
      seed: opts[:seed],
      use_merge: opts[:use_merge],
      max_merge_invocations: opts[:max_merge_invocations],
      merge_val_overlap_floor: opts[:merge_val_overlap_floor],
      frontier_type: opts[:frontier_type],
      evaluation_policy: opts[:evaluation_policy],
      acceptance_policy: opts[:acceptance_policy],
      merge_acceptance_policy: opts[:merge_acceptance_policy],
      raise_on_exception: opts[:raise_on_exception],
      skip_perfect_score: opts[:skip_perfect_score],
      perfect_score: opts[:perfect_score],
      cache_evaluation: opts[:cache_evaluation],
      rng_algorithm: opts[:rng_algorithm],
      reflection_failure_policy: opts[:reflection_failure_policy],
      stopper: opts[:stopper],
      reflection_lm: opts[:reflection_lm],
      reflection_strategy: reflection_strategy,
      max_metric_calls: validate_limit!(opts[:max_metric_calls], :max_metric_calls),
      max_full_evaluations: validate_limit!(opts[:max_full_evaluations], :max_full_evaluations),
      max_reflection_calls: validate_limit!(opts[:max_reflection_calls], :max_reflection_calls),
      max_reflection_cost: max_reflection_cost
    }
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :required},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    {:ok,
     compile(
       optimizer,
       program,
       Imp.Optimizer.fetch_dataset!(opts, :trainset),
       Imp.Optimizer.fetch_dataset!(opts, :validation),
       Imp.Optimizer.invocation_options(opts)
     )}
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset, opts \\ []) do
    {compiled, _report} = compile_with_report(optimizer, program, trainset, devset, opts)
    compiled
  end

  @doc "Compiles a program and returns the optimizer report independently of program metadata support."
  def compile_with_report(%__MODULE__{} = optimizer, program, trainset, devset, opts \\ []) do
    opts = Imp.Options.validate!(opts, @compile_option_schema, "Imp.Optimizer.GEPA.compile/5")
    trainset = Enum.to_list(trainset)
    devset = Enum.to_list(devset)
    {feedback, feedback_errors} = feedback(optimizer, trainset)

    reflection_feedback =
      if is_function(optimizer.feedback_fn, 1) and feedback_errors == [], do: feedback

    seed_candidate = Candidate.from_program(program)

    adapter =
      ProgramAdapter.new(program, optimizer.metric,
        max_concurrency: optimizer.max_concurrency,
        timeout: optimizer.timeout,
        component_feedback: optimizer.component_feedback,
        reflection_record_mode: optimizer.reflection_record_mode
      )

    envelope = profile_budget_envelope(optimizer, trainset, devset)

    engine_opts =
      [
        execution_profile: optimizer.execution_profile,
        max_iterations: envelope.max_iterations,
        candidate_selection_strategy: optimizer.candidate_selection_strategy,
        module_selector: optimizer.module_selector,
        combee: optimizer.combee,
        sampling_strategy: optimizer.sampling_strategy,
        selection_strategy: optimizer.selection_strategy,
        proposal_concurrency: optimizer.proposal_concurrency,
        proposal_timeout: optimizer.proposal_timeout,
        minibatch_size: optimizer.minibatch_size || min(3, length(trainset)),
        seed: optimizer.seed,
        use_merge: optimizer.use_merge,
        max_merge_invocations: optimizer.max_merge_invocations,
        merge_val_overlap_floor: optimizer.merge_val_overlap_floor,
        frontier_type: optimizer.frontier_type,
        evaluation_policy: optimizer.evaluation_policy,
        acceptance_policy: optimizer.acceptance_policy,
        merge_acceptance_policy: optimizer.merge_acceptance_policy,
        raise_on_exception: optimizer.raise_on_exception,
        skip_perfect_score: optimizer.skip_perfect_score,
        perfect_score: optimizer.perfect_score,
        cache_evaluation: optimizer.cache_evaluation,
        rng_algorithm: optimizer.rng_algorithm,
        reflection_failure_policy: optimizer.reflection_failure_policy,
        callbacks: optimizer.callbacks,
        stopper: profile_stopper(optimizer, envelope),
        max_metric_calls: envelope.operational_metric_call_cap,
        max_full_evaluations: optimizer.max_full_evaluations,
        max_reflection_calls: envelope.operational_reflection_call_cap,
        max_reflection_cost: optimizer.max_reflection_cost,
        reflection_strategy: optimizer.reflection_strategy,
        reflection_cost_source: optimizer.reflection_strategy || optimizer.reflection_lm,
        evaluation_timeout: optimizer.timeout,
        resume_state: opts[:resume_state],
        checkpoint_fn: opts[:checkpoint_fn]
      ]

    state =
      Engine.run(
        adapter,
        seed_candidate,
        trainset,
        devset,
        proposer(
          optimizer.reflection_lm,
          feedback,
          reflection_feedback,
          optimizer.reflection_record_mode
        ),
        engine_opts
      )

    best = Engine.best(state)
    compiled = Candidate.apply_to_program(program, best.candidate)
    candidates = report_candidates(state)
    errors = feedback_errors ++ evaluation_errors(state)

    report =
      Report.new(%{
        optimizer: :gepa,
        best_score: best.validation.aggregate_score,
        candidate_count: length(candidates),
        candidates: candidates,
        errors: errors,
        metadata: %{
          feedback: feedback,
          component_feedback: optimizer.component_feedback |> Map.keys() |> Enum.sort(),
          reflection_record_mode: optimizer.reflection_record_mode,
          execution_profile: optimizer.execution_profile,
          reflection_failure_policy: optimizer.reflection_failure_policy,
          rng_algorithm: optimizer.rng_algorithm,
          candidate_selection_strategy: policy_name(optimizer.candidate_selection_strategy),
          generations: optimizer.generations,
          minibatch_size: state.combee_policy.effective_batch_size,
          proposal_concurrency: optimizer.proposal_concurrency,
          sampling_strategy: optimizer.sampling_strategy,
          selection_strategy: policy_name(optimizer.selection_strategy),
          proposal_timeout: optimizer.proposal_timeout,
          max_concurrency: optimizer.max_concurrency,
          timeout: optimizer.timeout,
          implementation: __MODULE__,
          engine: Engine,
          frontier_size: length(Engine.frontier(state)),
          frontier_type: optimizer.frontier_type,
          evaluation_policy: optimizer.evaluation_policy,
          acceptance_policy: policy_name(optimizer.acceptance_policy),
          merge_acceptance_policy: policy_name(optimizer.merge_acceptance_policy),
          merge_candidates: Enum.count(state.history, &(&1[:operation] == :merge)),
          merges_accepted: state.total_merges_tested,
          metric_calls: state.budget.metric_calls,
          max_metric_calls: envelope.semantic_max_metric_calls,
          operational_metric_call_cap: state.budget.max_metric_calls,
          reflection_calls: state.budget.reflection_calls,
          max_reflection_calls: state.budget.max_reflection_calls,
          max_reflection_cost: optimizer.max_reflection_cost,
          full_evaluations: state.budget.full_evaluations,
          max_full_evaluations: state.budget.max_full_evaluations,
          rejected_candidates: length(state.rejected),
          stop_reason: state.stop_reason,
          status: if(errors == [], do: :ok, else: :with_errors),
          combee:
            ComBee.metadata(state.combee_policy)
            |> Map.put(:aggregations, state.combee_reports)
        }
      })

    {Report.attach(compiled, report), report}
  end

  @doc """
  Compiles a program and returns a safe, checksummed parameter artifact.

  This is the durable path for consumer-defined multi-predictor modules. The
  artifact contains only named predictor signatures, demonstrations, and
  configuration plus the GEPA report. It never serializes the consumer module,
  LMs, adapters, callbacks, or other executable runtime state. Reconstruct the
  trusted program in the deploying application and apply the artifact with
  `Imp.Optimizer.Artifact.apply/4`.
  """
  def compile_with_artifact(%__MODULE__{} = optimizer, program, trainset, devset, opts \\ []) do
    opts =
      Imp.Options.validate!(
        opts,
        @artifact_option_schema,
        "Imp.Optimizer.GEPA.compile_with_artifact/5"
      )

    compile_opts = Keyword.take(opts, [:resume_state, :checkpoint_fn])
    {compiled, report} = compile_with_report(optimizer, program, trainset, devset, compile_opts)

    artifact =
      Artifact.from_optimized_program(compiled,
        artifact_id: opts[:artifact_id],
        provenance: opts[:provenance]
      )

    {compiled, report, artifact}
  end

  defp proposer(reflection_lm, fallback_feedback, reflection_feedback, reflection_record_mode) do
    fn candidate, component, records, generation, aggregation ->
      case reflection_lm do
        nil ->
          fallback_proposal(
            candidate,
            component,
            records,
            generation,
            fallback_feedback,
            aggregation
          )

        lm ->
          reflection_proposal(
            lm,
            candidate,
            component,
            records,
            generation,
            reflection_feedback,
            aggregation,
            reflection_record_mode
          )
      end
    end
  end

  @doc false
  def fallback_proposal(candidate, component, records, generation, feedback, aggregation) do
    record_feedback =
      records
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {record, index} ->
        value =
          Map.get(record, "ComBeeIntermediateUpdate") || Map.get(record, "Feedback") ||
            inspect(record)

        "[#{index}] #{value}"
      end)

    phase = Map.get(aggregation, :phase, :single)

    [
      Map.fetch!(candidate, component),
      feedback,
      "Reflection #{generation} (#{phase}): #{record_feedback}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp reflection_proposal(
         lm,
         candidate,
         component,
         records,
         _generation,
         feedback,
         _aggregation,
         reflection_record_mode
       ) do
    messages =
      InstructionProposal.messages(
        Map.fetch!(candidate, component),
        records,
        feedback,
        reflection_record_mode
      )

    case lm |> Imp.LM.generate(messages, []) |> Imp.LM.Result.unwrap() do
      {:ok, response} ->
        case InstructionProposal.normalize(response) do
          {:ok, instruction} -> instruction
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:reflection_lm_failed, reason}}
    end
  end

  defp report_candidates(state) do
    accepted =
      Enum.map(state.candidates, fn entry ->
        diagnostics = result_diagnostics(entry.validation)

        %{
          score: entry.validation.aggregate_score,
          instruction: primary_instruction(entry.candidate),
          parameters: entry.candidate,
          id: candidate_id(entry.id),
          parent_id: entry.parent_ids |> List.first() |> candidate_id(),
          mutation: if(entry.id == 0, do: "baseline", else: "accepted reflection"),
          diagnostics: diagnostics
        }
      end)

    rejected =
      state.rejected
      |> Enum.filter(&is_map(&1.candidate))
      |> Enum.map(fn event ->
        diagnostics = rejection_diagnostics(event)

        %{
          score: event.minibatch_candidate_score || 0.0,
          instruction: primary_instruction(event.candidate),
          parameters: event.candidate,
          id: "gepa-#{event.iteration}",
          parent_id: event.parent_ids |> List.first() |> candidate_id(),
          mutation:
            if(diagnostics == [],
              do: "Reflection #{event.iteration}",
              else: "Program call failed: #{Enum.join(diagnostics, "; ")}"
            ),
          diagnostics: diagnostics
        }
      end)

    accepted ++ rejected
  end

  defp evaluation_errors(state) do
    state.candidates
    |> Enum.flat_map(fn entry ->
      case result_diagnostics(entry.validation) do
        [] -> []
        diagnostics -> [%{candidate_id: candidate_id(entry.id), diagnostics: diagnostics}]
      end
    end)
  end

  defp result_diagnostics(result) do
    result.side_information
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&diagnostic_text/1)
    |> Enum.reject(&(&1 in [nil, "successful", "improve"]))
    |> Enum.uniq()
  end

  defp rejection_diagnostics(event) do
    reason =
      case event.reason do
        {:proposal_error, reason} -> [reason]
        _reason -> []
      end

    [
      Map.get(event, :parent_side_information, %{}),
      Map.get(event, :candidate_side_information, %{})
    ]
    |> Enum.flat_map(&(&1 |> Map.values() |> List.flatten()))
    |> Kernel.++(reason)
    |> Enum.map(&diagnostic_text/1)
    |> Enum.reject(&(&1 in [nil, "successful", "improve"]))
    |> Enum.uniq()
  end

  defp diagnostic_text({:metric_error, message}), do: truncate_text(to_string(message), 240)
  defp diagnostic_text({_kind, message}) when is_binary(message), do: truncate_text(message, 240)
  defp diagnostic_text(value) when is_atom(value), do: Atom.to_string(value)
  defp diagnostic_text(nil), do: nil
  defp diagnostic_text(value), do: truncate_text(inspect(value), 240)

  defp primary_instruction(candidate) do
    Map.get(candidate, :main) || Map.get(candidate, "main") || candidate |> Map.values() |> hd()
  end

  defp candidate_id(nil), do: nil
  defp candidate_id(0), do: "baseline"
  defp candidate_id(id), do: "gepa-#{id}"

  defp policy_name({:callback, _callback}), do: :custom
  defp policy_name(policy), do: policy

  defp truncate_text(text, max_graphemes) do
    if String.length(text) <= max_graphemes,
      do: text,
      else: String.slice(text, 0, max_graphemes) <> "..."
  end

  defp feedback(%__MODULE__{feedback_fn: fun}, trainset) when is_function(fun, 1) do
    {to_string(fun.(trainset)), []}
  rescue
    exception ->
      default = default_feedback(trainset)

      {default,
       [
         %{
           stage: :feedback,
           error: Exception.message(exception),
           fallback: default
         }
       ]}
  catch
    kind, reason ->
      default = default_feedback(trainset)

      {default,
       [
         %{
           stage: :feedback,
           error: "#{kind}: #{inspect(reason)}",
           fallback: default
         }
       ]}
  end

  defp feedback(_optimizer, trainset), do: {default_feedback(trainset), []}

  defp default_feedback(trainset),
    do: "Use observed examples carefully. Training examples available: #{length(trainset)}."

  defp resolve_execution_profile!(requested, opts) do
    case opts[:execution_profile] do
      :beam_native ->
        opts
        |> Keyword.put(:skip_perfect_score, false)
        |> Keyword.put(:perfect_score, nil)
        |> Keyword.put(:cache_evaluation, true)
        |> Keyword.put(:rng_algorithm, :beam_native)
        |> Keyword.put(:reflection_failure_policy, :single_attempt_fail_closed)

      :gepa_v0_1_4 ->
        requirements = [
          reflection_record_mode: :gepa_v0_1_4,
          candidate_selection_strategy: :pareto,
          module_selector: :round_robin,
          combee: false,
          sampling_strategy: :single,
          selection_strategy: :all_improvements,
          proposal_concurrency: 1,
          max_concurrency: 1,
          use_merge: false,
          frontier_type: :instance,
          evaluation_policy: :full,
          acceptance_policy: :strict_improvement
        ]

        Enum.each(requirements, fn {key, expected} ->
          if Keyword.has_key?(requested, key) and Keyword.fetch!(requested, key) != expected do
            raise ArgumentError,
                  ":execution_profile :gepa_v0_1_4 requires #{inspect(key)}: #{inspect(expected)}"
          end
        end)

        opts
        |> Keyword.merge(requirements)
        |> Keyword.put(:skip_perfect_score, true)
        |> Keyword.put(:perfect_score, 1.0)
        |> Keyword.put(:cache_evaluation, false)
        |> Keyword.put(:rng_algorithm, :python_v3)
        |> Keyword.put(
          :reflection_failure_policy,
          :gepa_v0_1_4_batch_then_single_retry
        )
    end
  end

  defp profile_budget_envelope(%__MODULE__{execution_profile: :beam_native} = optimizer, _, _) do
    %{
      semantic_max_metric_calls: optimizer.max_metric_calls,
      operational_metric_call_cap: optimizer.max_metric_calls,
      operational_reflection_call_cap: optimizer.max_reflection_calls,
      max_iterations: optimizer.generations
    }
  end

  defp profile_budget_envelope(
         %__MODULE__{execution_profile: :gepa_v0_1_4} = optimizer,
         trainset,
         devset
       ) do
    minibatch_size = optimizer.minibatch_size || min(3, length(trainset))
    required = length(devset) + optimizer.generations * (2 * minibatch_size + length(devset))

    unless optimizer.max_metric_calls in [:infinity, required] do
      raise ArgumentError,
            ":execution_profile :gepa_v0_1_4 requires :max_metric_calls #{required} for " <>
              "this validation set, minibatch, and nominal iteration budget; got: " <>
              inspect(optimizer.max_metric_calls)
    end

    envelope = v014_budget_envelope(length(devset), minibatch_size, required)

    unless optimizer.max_reflection_calls in [:infinity, envelope.max_reflection_calls] do
      raise ArgumentError,
            ":execution_profile :gepa_v0_1_4 requires :max_reflection_calls " <>
              "#{envelope.max_reflection_calls} for every legally started iteration; got: " <>
              inspect(optimizer.max_reflection_calls)
    end

    %{
      semantic_max_metric_calls: required,
      operational_metric_call_cap: envelope.max_metric_calls,
      operational_reflection_call_cap: envelope.max_reflection_calls,
      max_iterations: envelope.max_iterations
    }
  end

  defp profile_stopper(%__MODULE__{execution_profile: :beam_native, stopper: stopper}, _envelope),
    do: stopper

  defp profile_stopper(%__MODULE__{stopper: nil}, envelope),
    do: Stopper.max_metric_calls(envelope.semantic_max_metric_calls)

  defp profile_stopper(%__MODULE__{stopper: stopper}, envelope),
    do: Stopper.any([Stopper.max_metric_calls(envelope.semantic_max_metric_calls), stopper])

  @doc false
  def v014_budget_envelope(validation_size, minibatch_size, semantic_max_metric_calls)
      when is_integer(validation_size) and validation_size >= 0 and
             is_integer(minibatch_size) and minibatch_size > 0 and
             is_integer(semantic_max_metric_calls) and semantic_max_metric_calls >= 0 do
    increments = [minibatch_size, 2 * minibatch_size, 2 * minibatch_size + validation_size]

    reachable =
      reachable_pre_iteration_counts(
        MapSet.new([validation_size]),
        increments,
        semantic_max_metric_calls
      )

    legal_starts = Enum.filter(reachable, &(&1 < semantic_max_metric_calls))

    max_metric_calls =
      case legal_starts do
        [] -> validation_size
        starts -> Enum.max(starts) + Enum.max(increments)
      end

    max_iterations =
      if validation_size < semantic_max_metric_calls do
        div(semantic_max_metric_calls - validation_size + minibatch_size - 1, minibatch_size)
      else
        0
      end

    %{
      max_metric_calls: max_metric_calls,
      max_reflection_calls: 2 * max_iterations,
      max_iterations: max_iterations
    }
  end

  defp reachable_pre_iteration_counts(reachable, increments, limit) do
    expanded =
      Enum.reduce(reachable, reachable, fn count, acc ->
        if count < limit do
          Enum.reduce(increments, acc, fn increment, acc ->
            next = count + increment
            if next < limit, do: MapSet.put(acc, next), else: acc
          end)
        else
          acc
        end
      end)

    if MapSet.size(expanded) == MapSet.size(reachable),
      do: expanded,
      else: reachable_pre_iteration_counts(expanded, increments, limit)
  end

  defp validate_limit!(:infinity, _name), do: :infinity
  defp validate_limit!(value, _name) when is_integer(value) and value >= 0, do: value

  defp validate_limit!(value, name) do
    raise ArgumentError,
          "#{name} must be a non-negative integer or :infinity, got: #{inspect(value)}"
  end

  def validate_feedback_fn(nil), do: {:ok, nil}
  def validate_feedback_fn(feedback_fn) when is_function(feedback_fn, 1), do: {:ok, feedback_fn}

  def validate_feedback_fn(feedback_fn) do
    {:error, "expected nil or an arity-1 function, got: #{inspect(feedback_fn)}"}
  end

  def validate_artifact_id(value) when is_binary(value) and value != "", do: {:ok, value}

  def validate_artifact_id(value),
    do: {:error, "must be a non-empty string, got: #{inspect(value)}"}

  @doc false
  def validate_module_selector(selector) do
    Imp.Optimizer.GEPA.ModuleSelector.validate!(selector)
    {:ok, selector}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def validate_proposal_concurrency(:auto), do: {:ok, :auto}

  def validate_proposal_concurrency(value) when is_integer(value) and value > 0,
    do: {:ok, value}

  def validate_proposal_concurrency(value) do
    {:error, "expected :auto or a positive integer, got: #{inspect(value)}"}
  end

  defp validate_candidate_selection_strategy!(strategy) do
    Imp.Optimizer.GEPA.CandidateSelector.validate!(strategy)
    strategy
  end

  defp validate_sampling_strategy!(:single), do: :single

  defp validate_sampling_strategy!({:same_parent, n} = strategy) when is_integer(n) and n > 0,
    do: strategy

  defp validate_sampling_strategy!({:independent, n} = strategy) when is_integer(n) and n > 0,
    do: strategy

  defp validate_sampling_strategy!({:pxn, p, n} = strategy)
       when is_integer(p) and p > 0 and is_integer(n) and n > 0,
       do: strategy

  defp validate_sampling_strategy!(strategy) do
    raise ArgumentError, "invalid GEPA sampling strategy: #{inspect(strategy)}"
  end

  defp validate_selection_strategy!(strategy) do
    Imp.Optimizer.GEPA.ProposalSelection.validate!(strategy)
    strategy
  end

  defp validate_cost_limit!(nil), do: nil
  defp validate_cost_limit!(value) when is_number(value) and value >= 0, do: value * 1.0

  defp validate_cost_limit!(value) do
    raise ArgumentError,
          ":max_reflection_cost must be nil or a non-negative number, got: #{inspect(value)}"
  end
end
