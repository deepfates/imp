defmodule Imp.Optimizer.RandomSearch do
  @behaviour Imp.Optimizer
  @moduledoc """
  DSPy 3.2.1 BootstrapFewShotWithRandomSearch / BootstrapRS.

  Candidate seeds, baseline scheduling, chained labeled-demo sampling, tie
  ordering, and rounded percentage scores follow DSPy 3.2.1. Seeded draws use
  Imp's deterministic BEAM-native sampler rather than Python's MT19937 sequence.

  Durable invocations accept `:max_candidates`, `:checkpoint_fn`, and
  `:resume_state`. A candidate is sealed only after both its bootstrap/build
  stage and full validation evaluation finish; interrupted candidates replay as
  a unit, while completed candidates do not. Captured metrics require a stable
  JSON-safe `:metric_identity`. Complete anonymous-metric runs remain available
  in process without a checkpoint.
  """

  alias Imp.Optimizer.{
    BootstrapFewShot,
    DurableCallbackIdentity,
    Report,
    Sampling
  }

  alias Imp.Optimizer.RandomSearch.Checkpoint

  defstruct [
    :metric,
    :metric_identity,
    teacher_settings: [],
    max_bootstrapped_demos: 4,
    max_labeled_demos: 16,
    max_rounds: 1,
    num_candidate_programs: 16,
    num_threads: nil,
    max_errors: nil,
    stop_at_score: nil,
    metric_threshold: nil,
    seed: nil,
    candidates: 16,
    demos_per_candidate: 4
  ]

  @option_schema [
    teacher_settings: [type: :keyword_list, default: []],
    max_bootstrapped_demos: [type: :non_neg_integer, default: 4],
    max_labeled_demos: [type: :non_neg_integer, default: 16],
    max_rounds: [type: :non_neg_integer, default: 1],
    num_candidate_programs: [type: :non_neg_integer, default: 16],
    num_threads: [type: {:custom, __MODULE__, :validate_optional_positive, []}, default: nil],
    max_errors: [type: {:custom, __MODULE__, :validate_optional_max_errors, []}, default: nil],
    stop_at_score: [type: {:custom, __MODULE__, :validate_optional_number, []}, default: nil],
    metric_threshold: [type: {:custom, __MODULE__, :validate_optional_number, []}, default: nil],
    metric_identity: [type: :any, default: nil],
    # Imp-side aliases. They are normalized immediately and do not change
    # DSPy's fixed seed schedule.
    candidates: [type: {:custom, __MODULE__, :validate_optional_non_negative, []}, default: nil],
    demos_per_candidate: [
      type: {:custom, __MODULE__, :validate_optional_non_negative, []},
      default: nil
    ],
    seed: [type: {:custom, __MODULE__, :validate_optional_integer, []}, default: nil]
  ]

  @compile_option_schema [
    teacher: [type: :any, default: nil],
    restrict: [type: {:custom, __MODULE__, :validate_restrict, []}, default: nil],
    labeled_sample: [type: :boolean, default: true],
    resume_state: [
      type: {:custom, Imp.Optimize.Anything, :validate_resume_state, []},
      default: nil
    ],
    checkpoint_fn: [
      type: {:custom, Imp.Optimize.Anything, :validate_checkpoint_fn, []},
      default: nil
    ],
    max_candidates: [type: {:or, [:non_neg_integer, {:in, [:infinity]}]}, default: :infinity]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.RandomSearch.new/2", "metric")
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.RandomSearch.new/2")

    max_bootstrapped_demos = opts[:demos_per_candidate] || opts[:max_bootstrapped_demos]
    num_candidate_programs = opts[:candidates] || opts[:num_candidate_programs]

    %__MODULE__{
      metric: metric,
      metric_identity:
        DurableCallbackIdentity.normalize!(opts[:metric_identity], :metric_identity),
      teacher_settings: opts[:teacher_settings],
      max_bootstrapped_demos: max_bootstrapped_demos,
      max_labeled_demos: opts[:max_labeled_demos],
      max_rounds: opts[:max_rounds],
      num_candidate_programs: num_candidate_programs,
      num_threads: opts[:num_threads],
      max_errors: opts[:max_errors],
      stop_at_score: opts[:stop_at_score],
      metric_threshold: opts[:metric_threshold],
      seed: opts[:seed],
      candidates: num_candidate_programs,
      demos_per_candidate: max_bootstrapped_demos
    }
  end

  @doc false
  def validate_optional_number(nil), do: {:ok, nil}
  def validate_optional_number(value) when is_number(value), do: {:ok, value}
  def validate_optional_number(_value), do: {:error, "expected nil, an integer, or a float"}

  @doc false
  def validate_optional_non_negative(nil), do: {:ok, nil}

  def validate_optional_non_negative(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  def validate_optional_non_negative(_value),
    do: {:error, "expected non negative integer"}

  @doc false
  def validate_optional_integer(nil), do: {:ok, nil}
  def validate_optional_integer(value) when is_integer(value), do: {:ok, value}
  def validate_optional_integer(_value), do: {:error, "expected integer"}

  @doc false
  def validate_optional_positive(nil), do: {:ok, nil}
  def validate_optional_positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  def validate_optional_positive(_value), do: {:error, "expected nil or a positive integer"}

  @doc false
  def validate_optional_max_errors(nil), do: {:ok, nil}
  def validate_optional_max_errors(value), do: Imp.Evaluate.validate_max_errors(value)

  @doc false
  def validate_restrict(nil), do: {:ok, nil}

  def validate_restrict(values) when is_list(values) do
    if Enum.all?(values, &is_integer/1),
      do: {:ok, values},
      else: {:error, "expected nil or a list of integer candidate seeds"}
  end

  def validate_restrict(_value),
    do: {:error, "expected nil or a list of integer candidate seeds"}

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :optional},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    compile_opts = Imp.Optimizer.invocation_options(opts)

    {:ok,
     compile(
       optimizer,
       program,
       Imp.Optimizer.fetch_dataset!(opts, :trainset),
       Keyword.get(opts, :validation),
       compile_opts
     )}
  end

  @impl true
  def validate_invocation_options(opts) do
    _validated = validate_compile_options!(opts)
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc false
  def compile(%__MODULE__{} = optimizer, student, trainset, valset \\ nil, opts \\ [])
      when is_list(opts) do
    opts = validate_compile_options!(opts)
    trainset = Enum.to_list(trainset)
    valset = materialize_valset(valset, trainset)
    teacher = Keyword.get(opts, :teacher)
    restrict = Keyword.get(opts, :restrict)
    labeled_sample = Keyword.get(opts, :labeled_sample, true)
    {max_errors, max_errors_source} = resolve_max_errors!(optimizer.max_errors)
    optimizer = %{optimizer | max_errors: max_errors}
    :ok = DurableCallbackIdentity.validate_normalized!(optimizer.metric_identity, "RandomSearch")

    candidate_seeds =
      optimizer.num_candidate_programs
      |> seeds()
      |> Enum.filter(&allowed?(&1, restrict))

    if candidate_seeds == [] do
      raise RuntimeError, "RandomSearch restrict excluded every DSPy candidate seed"
    end

    durable? =
      DurableCallbackIdentity.durable?(
        optimizer.metric,
        optimizer.metric_identity,
        durable_controls?(opts)
      )

    metric_identity =
      DurableCallbackIdentity.resolve!(
        optimizer.metric,
        optimizer.metric_identity,
        durable?,
        "RandomSearch",
        :metric_identity
      )

    compatibility =
      resume_compatibility(
        student,
        trainset,
        valset,
        optimizer,
        teacher,
        restrict,
        labeled_sample,
        metric_identity,
        max_errors_source
      )

    {state, resumed?} =
      case opts[:resume_state] do
        nil ->
          state = %{records: [], errors: [], next_index: 0, stopped: false}
          emit_checkpoint(opts[:checkpoint_fn], durable?, compatibility, state)
          {state, false}

        checkpoint ->
          state = Checkpoint.load!(checkpoint, compatibility, student)
          validate_resumed_state!(state, candidate_seeds, optimizer.stop_at_score)
          {state, true}
      end

    candidate_limit = invocation_candidate_limit(state.next_index, opts[:max_candidates])

    state =
      run_candidates(
        state,
        candidate_seeds,
        candidate_limit,
        student,
        trainset,
        valset,
        teacher,
        optimizer,
        labeled_sample,
        opts[:checkpoint_fn],
        durable?,
        compatibility
      )

    records = state.records
    errors = state.errors
    complete? = state.stopped or state.next_index == length(candidate_seeds)

    ranked = Enum.sort_by(records, &{-&1.score, &1.evaluation_order})
    best = List.first(ranked)

    report_candidates =
      Enum.map(ranked, fn candidate ->
        candidate
        |> Map.drop([:program, :evaluation_order])
        |> Map.put(:demos, predictor_demos(candidate.program))
      end)

    checkpoint = if durable?, do: Checkpoint.dump(compatibility, state)
    selected = if is_nil(best), do: reset_student(student), else: best.program

    attach_report(
      selected,
      Report.new(%{
        optimizer: :random_search,
        best_score: if(is_nil(best), do: nil, else: best.score),
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: errors,
        metadata: %{
          status: if(errors == [], do: :ok, else: :with_errors),
          candidate_seeds: Enum.map(records, & &1.seed),
          evaluated_candidate_count: length(records),
          valset_size: length(valset),
          trainset_size: length(trainset),
          stop_at_score: optimizer.stop_at_score,
          max_errors: max_errors,
          max_errors_source: max_errors_source,
          score_scale: :percentage,
          sampling_rng: :beam_native,
          sampling_schedule: :dspy_3_2_1_seed_lifecycle,
          durable: durable?,
          metric_identity: metric_identity,
          resumed: resumed?,
          run_status: if(complete?, do: :complete, else: :paused),
          completed_candidates: state.next_index,
          resume_state: checkpoint
        }
      })
    )
  end

  defp run_candidates(
         state,
         candidate_seeds,
         candidate_limit,
         student,
         trainset,
         valset,
         teacher,
         optimizer,
         labeled_sample,
         checkpoint_fn,
         durable?,
         compatibility
       ) do
    cond do
      state.stopped or state.next_index == length(candidate_seeds) ->
        state

      candidate_budget_exhausted?(state.next_index, candidate_limit) ->
        state

      true ->
        evaluation_order = state.next_index
        seed = Enum.fetch!(candidate_seeds, evaluation_order)

        {program, source_metadata} =
          candidate_program(student, trainset, teacher, optimizer, seed, labeled_sample)

        result =
          Imp.Telemetry.span(
            [:imp, :optimizer, :trial],
            %{optimizer: :random_search, trial: evaluation_order, seed: seed},
            fn -> evaluate!(program, valset, optimizer) end
          )

        record =
          Map.merge(source_metadata, %{
            seed: seed,
            score: result.score,
            subscores: result.subscores,
            program: program,
            evaluation_order: evaluation_order
          })

        stopped =
          not is_nil(optimizer.stop_at_score) and result.score >= optimizer.stop_at_score

        state = %{
          records: state.records ++ [record],
          errors: state.errors ++ contextualize_errors(result.errors, seed),
          next_index: evaluation_order + 1,
          stopped: stopped
        }

        emit_checkpoint(checkpoint_fn, durable?, compatibility, state)

        run_candidates(
          state,
          candidate_seeds,
          candidate_limit,
          student,
          trainset,
          valset,
          teacher,
          optimizer,
          labeled_sample,
          checkpoint_fn,
          durable?,
          compatibility
        )
    end
  end

  defp invocation_candidate_limit(_completed, :infinity), do: :infinity
  defp invocation_candidate_limit(completed, maximum), do: completed + maximum

  defp candidate_budget_exhausted?(_completed, :infinity), do: false
  defp candidate_budget_exhausted?(completed, limit), do: completed >= limit

  defp durable_controls?(opts) do
    not is_nil(opts[:resume_state]) or not is_nil(opts[:checkpoint_fn]) or
      opts[:max_candidates] != :infinity
  end

  defp emit_checkpoint(_callback, false, _compatibility, _state), do: :ok
  defp emit_checkpoint(nil, true, _compatibility, _state), do: :ok

  defp emit_checkpoint(callback, true, compatibility, state) do
    callback.(Checkpoint.dump(compatibility, state))
    :ok
  end

  defp resume_compatibility(
         student,
         trainset,
         valset,
         optimizer,
         teacher,
         restrict,
         labeled_sample,
         metric_identity,
         max_errors_source
       ) do
    payload = %{
      datasets: %{trainset: trainset, valset: valset},
      metric: metric_identity,
      optimizer:
        optimizer
        |> Map.from_struct()
        |> Map.drop([:metric, :metric_identity])
        |> runtime_identity()
        |> Map.put(:max_errors_source, max_errors_source),
      invocation: %{
        teacher: runtime_identity(teacher),
        restrict: restrict,
        labeled_sample: labeled_sample
      },
      program_module: student.__struct__,
      predictors:
        Enum.map(Imp.ProgramParameters.predictors(student), fn %{name: name, predictor: predictor} ->
          %{
            name: name,
            signature: predictor.signature,
            demos: predictor.demos,
            config: predictor.config,
            lm: runtime_identity(predictor.lm),
            adapter: runtime_identity(predictor.adapter),
            dynamic_lm?: predictor.dynamic_lm?,
            dynamic_adapter?: predictor.dynamic_adapter?
          }
        end)
    }

    digest =
      payload
      |> Report.encode_term()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{"sha256" => digest}
  end

  defp validate_resumed_state!(state, candidate_seeds, stop_at_score) do
    expected_seeds = Enum.take(candidate_seeds, state.next_index)

    unless state.next_index == length(state.records) and
             Enum.map(state.records, & &1.seed) == expected_seeds and
             Enum.map(state.records, & &1.evaluation_order) ==
               evaluation_indices(state.next_index) do
      raise ArgumentError, "RandomSearch resume state does not follow the candidate seed schedule"
    end

    reached_stop? =
      not is_nil(stop_at_score) and
        Enum.any?(state.records, &(&1.score >= stop_at_score))

    unless state.stopped == reached_stop? do
      raise ArgumentError, "RandomSearch resume state stop condition is inconsistent"
    end

    state
  end

  defp evaluation_indices(0), do: []
  defp evaluation_indices(count), do: Enum.to_list(0..(count - 1))

  defp runtime_identity(callback) when is_function(callback) do
    Map.new([:module, :name, :arity, :type, :uniq, :index], fn key ->
      {key, callback |> :erlang.fun_info(key) |> elem(1)}
    end)
  end

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

  defp validate_compile_options!(opts) do
    Imp.Options.validate!(opts, @compile_option_schema, "Imp.Optimizer.RandomSearch.compile/5")
  end

  defp seeds(count) when count >= 0, do: Enum.to_list(-3..(count - 1))
  defp allowed?(_seed, nil), do: true
  defp allowed?(seed, restrict), do: seed in restrict

  defp candidate_program(student, _trainset, _teacher, _optimizer, -3, _labeled_sample),
    do: {reset_student(student), %{kind: :zero_shot}}

  defp candidate_program(student, trainset, _teacher, optimizer, -2, labeled_sample) do
    {labeled_student(student, trainset, optimizer.max_labeled_demos, labeled_sample),
     %{kind: :labels_only}}
  end

  defp candidate_program(student, trainset, teacher, optimizer, -1, _labeled_sample) do
    {bootstrap(student, trainset, teacher, optimizer, optimizer.max_bootstrapped_demos),
     %{kind: :unshuffled_bootstrap, bootstrap_size: optimizer.max_bootstrapped_demos}}
  end

  defp candidate_program(student, trainset, teacher, optimizer, seed, _labeled_sample) do
    {shuffled, _rng} = Sampling.shuffle(trainset, Sampling.new(seed))
    {offset, _rng} = Sampling.integer(optimizer.max_bootstrapped_demos, Sampling.new(seed))
    size = offset + 1

    {bootstrap(student, shuffled, teacher, optimizer, size),
     %{kind: :shuffled_bootstrap, bootstrap_size: size}}
  end

  defp bootstrap(student, trainset, teacher, optimizer, size) do
    BootstrapFewShot.new(optimizer.metric,
      teacher_settings: optimizer.teacher_settings,
      max_bootstrapped_demos: size,
      max_labeled_demos: optimizer.max_labeled_demos,
      max_rounds: optimizer.max_rounds,
      max_errors: optimizer.max_errors,
      metric_threshold: optimizer.metric_threshold
    )
    |> BootstrapFewShot.compile(student, trainset, teacher: teacher || student)
  end

  defp labeled_student(student, trainset, max_labeled, sample?) do
    {program, _rng} =
      Enum.reduce(
        Imp.ProgramParameters.predictors(student),
        {reset_student(student), Sampling.new(0)},
        fn %{name: name}, {program, rng} ->
          {demos, rng} =
            if sample? do
              sample(trainset, min(max_labeled, length(trainset)), rng)
            else
              {Enum.take(trainset, max_labeled), rng}
            end

          {Imp.ProgramParameters.put_demos(program, name, demos), rng}
        end
      )

    program
  end

  defp sample(_rows, 0, rng), do: {[], rng}

  defp sample(rows, count, rng) do
    {shuffled, rng} = Sampling.shuffle(rows, rng)
    {Enum.take(shuffled, count), rng}
  end

  defp reset_student(program) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      Imp.ProgramParameters.update_predictor(acc, name, fn predictor ->
        predictor
        |> Imp.Predict.Predict.with_demos([])
        |> then(&%{&1 | metadata: Map.delete(&1.metadata, :optimizer_report)})
      end)
    end)
  end

  defp materialize_valset(nil, trainset), do: trainset

  defp materialize_valset(valset, trainset) do
    case Enum.to_list(valset) do
      [] -> trainset
      rows -> rows
    end
  end

  defp evaluate!(program, valset, optimizer) do
    max_concurrency =
      optimizer.num_threads || Imp.Settings.snapshot() |> Map.fetch!(:async_max_workers)

    # Imp.Evaluate halts at errors >= max_errors (DSPy
    # parallelizer semantics); translate into RandomSearch's budget error so
    # the optimizer-facing contract stays the same.
    result =
      try do
        Imp.Evaluate.new(valset, optimizer.metric,
          max_concurrency: max_concurrency,
          max_errors: optimizer.max_errors
        )
        |> Imp.Evaluate.run(program)
      rescue
        cancelled in Imp.EvaluationCancelledError ->
          reraise RuntimeError,
                  "random_search_evaluation error budget exhausted: " <>
                    "#{length(cancelled.errors)} errors (maximum #{optimizer.max_errors})",
                  __STACKTRACE__
      end

    enforce_error_budget!(result.errors, optimizer.max_errors, :random_search_evaluation)

    %{
      score: dspy_percentage_score(result.rows),
      subscores: Enum.map(result.rows, & &1.score),
      errors: result.errors
    }
  end

  defp dspy_percentage_score([]),
    do: raise(ArithmeticError, "DSPy Evaluate cannot score an empty dataset")

  defp dspy_percentage_score(rows) do
    total = Enum.reduce(rows, 0, fn row, sum -> sum + row.score end)
    round_half_even(100 * total / length(rows), 2)
  end

  defp round_half_even(value, _digits) when value == 0.0, do: value

  defp round_half_even(value, digits) when is_float(value) do
    <<sign::1, exponent::11, fraction::52>> = <<value::float-64>>

    if exponent == 0x7FF do
      value
    else
      significand = if exponent == 0, do: fraction, else: Bitwise.bsl(1, 52) + fraction
      binary_exponent = if exponent == 0, do: -1074, else: exponent - 1023 - 52

      {numerator, denominator} =
        if binary_exponent >= 0 do
          {Bitwise.bsl(significand, binary_exponent), 1}
        else
          {significand, Bitwise.bsl(1, -binary_exponent)}
        end

      factor = Integer.pow(10, digits)
      scaled = numerator * factor
      quotient = div(scaled, denominator)
      remainder = rem(scaled, denominator)

      rounded =
        case compare(remainder * 2, denominator) do
          :lt -> quotient
          :gt -> quotient + 1
          :eq -> if rem(quotient, 2) == 0, do: quotient, else: quotient + 1
        end

      signed = if sign == 1, do: -rounded, else: rounded
      signed / factor
    end
  end

  defp compare(left, right) when left < right, do: :lt
  defp compare(left, right) when left > right, do: :gt
  defp compare(_left, _right), do: :eq

  defp enforce_error_budget!([], _max_errors, _stage), do: :ok
  defp enforce_error_budget!(_errors, :infinity, _stage), do: :ok

  defp enforce_error_budget!(errors, max_errors, stage) do
    if length(errors) >= max_errors do
      raise RuntimeError,
            "#{stage} error budget exhausted: #{length(errors)} errors (maximum #{max_errors})"
    end
  end

  defp contextualize_errors(errors, seed) do
    Enum.map(errors, &Map.merge(%{seed: seed, stage: :evaluation}, Map.new(&1)))
  end

  defp resolve_max_errors!(nil), do: resolve_settings_max_errors!()
  defp resolve_max_errors!(value), do: {validate_max_errors!(value), :explicit}

  defp resolve_settings_max_errors! do
    {Imp.Settings.fetch!(:max_errors) |> validate_max_errors!(), :settings}
  end

  defp validate_max_errors!(value) do
    case Imp.Evaluate.validate_max_errors(value) do
      {:ok, max_errors} ->
        max_errors

      {:error, message} ->
        raise ArgumentError, "invalid effective :max_errors setting: #{message}"
    end
  end

  defp predictor_demos(program) do
    Map.new(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      {name, predictor.demos}
    end)
  end

  defp attach_report(program, report) do
    case Imp.ProgramAccess.predict(program) do
      nil ->
        Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
          Imp.ProgramParameters.update_predictor(
            acc,
            name,
            &Imp.Optimizer.Report.attach(&1, report)
          )
        end)

      _predictor ->
        Imp.Optimizer.Report.attach(program, report)
    end
  end
end
