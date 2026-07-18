defmodule Imp.Optimizer.RandomSearch do
  @behaviour Imp.Optimizer
  @moduledoc """
  DSPy 3.2.1 BootstrapFewShotWithRandomSearch / BootstrapRS.

  Candidate seeds, baseline scheduling, chained labeled-demo sampling, and tie
  ordering match the authority. Seeded draws use Imp's deterministic
  BEAM-native sampler, so they do not claim Python MT19937 sequence parity.
  Candidate evaluation scores use DSPy's rounded percentage scale.
  """

  alias Imp.Optimizer.{BootstrapFewShot, Sampling}

  defstruct [
    :metric,
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
    # Historical Imp spellings. They are normalized immediately and do not
    # change DSPy's fixed seed schedule.
    candidates: [type: {:custom, __MODULE__, :validate_optional_non_negative, []}, default: nil],
    demos_per_candidate: [
      type: {:custom, __MODULE__, :validate_optional_non_negative, []},
      default: nil
    ],
    seed: [type: {:custom, __MODULE__, :validate_optional_integer, []}, default: nil]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.RandomSearch.new/2", "metric")
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.RandomSearch.new/2")

    max_bootstrapped_demos = opts[:demos_per_candidate] || opts[:max_bootstrapped_demos]
    num_candidate_programs = opts[:candidates] || opts[:num_candidate_programs]

    %__MODULE__{
      metric: metric,
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

  def validate_optional_number(nil), do: {:ok, nil}
  def validate_optional_number(value) when is_number(value), do: {:ok, value}
  def validate_optional_number(_value), do: {:error, "expected nil, an integer, or a float"}

  def validate_optional_non_negative(nil), do: {:ok, nil}

  def validate_optional_non_negative(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  def validate_optional_non_negative(_value),
    do: {:error, "expected non negative integer"}

  def validate_optional_integer(nil), do: {:ok, nil}
  def validate_optional_integer(value) when is_integer(value), do: {:ok, value}
  def validate_optional_integer(_value), do: {:error, "expected integer"}

  def validate_optional_positive(nil), do: {:ok, nil}
  def validate_optional_positive(value) when is_integer(value) and value > 0, do: {:ok, value}
  def validate_optional_positive(_value), do: {:error, "expected nil or a positive integer"}

  def validate_optional_max_errors(nil), do: {:ok, nil}
  def validate_optional_max_errors(value), do: Imp.Evaluate.validate_max_errors(value)

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :optional},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok,
       compile(
         optimizer,
         program,
         Imp.Optimizer.fetch_dataset!(opts, :trainset),
         Keyword.get(opts, :validation)
       )}
    end
  end

  def compile(%__MODULE__{} = optimizer, student, trainset, valset \\ nil, opts \\ [])
      when is_list(opts) do
    trainset = Enum.to_list(trainset)
    valset = materialize_valset(valset, trainset)
    teacher = Keyword.get(opts, :teacher)
    restrict = Keyword.get(opts, :restrict)
    labeled_sample = Keyword.get(opts, :labeled_sample, true)
    {max_errors, max_errors_source} = resolve_max_errors!(optimizer.max_errors)
    optimizer = %{optimizer | max_errors: max_errors}

    candidate_seeds =
      optimizer.num_candidate_programs
      |> seeds()
      |> Enum.filter(&allowed?(&1, restrict))

    if candidate_seeds == [] do
      raise RuntimeError, "RandomSearch restrict excluded every DSPy candidate seed"
    end

    {records, errors} =
      candidate_seeds
      |> Enum.with_index()
      |> Enum.reduce_while({[], []}, fn {seed, evaluation_order}, {records, errors} ->
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

        records = records ++ [record]
        errors = errors ++ contextualize_errors(result.errors, seed)

        if not is_nil(optimizer.stop_at_score) and result.score >= optimizer.stop_at_score do
          {:halt, {records, errors}}
        else
          {:cont, {records, errors}}
        end
      end)

    ranked = Enum.sort_by(records, &{-&1.score, &1.evaluation_order})
    best = hd(ranked)

    report_candidates =
      Enum.map(ranked, fn candidate ->
        candidate
        |> Map.drop([:program, :evaluation_order])
        |> Map.put(:demos, predictor_demos(candidate.program))
      end)

    attach_report(
      best.program,
      Imp.Optimizer.Report.new(%{
        optimizer: :random_search,
        best_score: best.score,
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
          sampling_schedule: :dspy_3_2_1_seed_lifecycle
        }
      })
    )
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

    result =
      Imp.Evaluate.new(valset, optimizer.metric,
        max_concurrency: max_concurrency,
        max_errors: evaluator_error_limit(optimizer.max_errors)
      )
      |> Imp.Evaluate.run(program)

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

  defp evaluator_error_limit(:infinity), do: :infinity
  defp evaluator_error_limit(max_errors), do: max(max_errors - 1, 0)

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
