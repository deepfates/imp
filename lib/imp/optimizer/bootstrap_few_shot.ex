defmodule Imp.Optimizer.BootstrapFewShot do
  @behaviour Imp.Optimizer
  @moduledoc """
  DSPy-compatible bootstrap few-shot compilation.

  Successful teacher traces become augmented demonstrations. The student
  working copy resets demonstrations and Imp's optimizer-report compilation
  marker. The untouched input is copied independently as the default teacher,
  so its compiled teacher state cannot leak back into the student.

  DSPy marks compiled modules with `_compiled`. Imp has no top-level compiled
  bit and uses an attached optimizer report as the corresponding heuristic; a
  teacher without that marker is reset before labeled demos are sampled, even
  if it already has manual demos. Teacher settings are dynamic Imp settings for
  each teacher execution and never become predictor generation config.

  `timeout` bounds each teacher execution (default 5000ms) and is a BEAM-native
  execution option: upstream DSPy runs teachers synchronously and unbounded.
  Pass a larger value or `:infinity` when teacher programs are slow — agentic
  or environment-backed teachers routinely run for minutes.

  Seed lifecycles follow DSPy 3.2.1, but `Imp.Optimizer.Sampling` is a
  deterministic BEAM-native RNG and does not reproduce Python MT19937 draws.
  Repeated calls to one predictor retain DSPy's one-demo earlier-or-final branch.
  Imp uses stable SHA-256 byte parity, which has a 1/2 branch model when digest
  bytes are uniform, instead of DSPy's Python Hasher-seeded RNG sequence.
  """

  alias Imp.Optimizer.{Report, Sampling, TrajectoryRunner}

  defstruct [
    :metric,
    metric_threshold: nil,
    teacher_settings: [],
    max_bootstrapped_demos: 4,
    max_labeled_demos: 16,
    max_rounds: 1,
    max_errors: nil,
    timeout: 5_000
  ]

  @option_schema [
    metric_threshold: [type: {:custom, __MODULE__, :validate_optional_number, []}, default: nil],
    teacher_settings: [type: :keyword_list, default: []],
    max_bootstrapped_demos: [type: :non_neg_integer, default: 4],
    max_labeled_demos: [type: :non_neg_integer, default: 16],
    max_rounds: [type: :non_neg_integer, default: 1],
    max_errors: [type: {:custom, __MODULE__, :validate_optional_max_errors, []}, default: nil],
    timeout: [type: {:or, [:timeout, :pos_integer]}, default: 5_000]
  ]

  @compile_option_schema [
    teacher: [type: :any, default: nil]
  ]

  def new, do: new(nil, [])
  def new(opts) when is_list(opts), do: new(nil, opts)
  def new(metric), do: new(metric, [])

  def new(metric, opts) do
    if not is_nil(metric) do
      Imp.FunctionContract.validate!(
        metric,
        [2, 3],
        "Imp.Optimizer.BootstrapFewShot.new/2",
        "metric"
      )
    end

    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.BootstrapFewShot.new/2")

    struct(__MODULE__, Map.new(opts) |> Map.put(:metric, metric))
  end

  def validate_optional_number(nil), do: {:ok, nil}
  def validate_optional_number(value) when is_number(value), do: {:ok, value}
  def validate_optional_number(_value), do: {:error, "expected nil, an integer, or a float"}

  def validate_optional_max_errors(nil), do: {:ok, nil}
  def validate_optional_max_errors(value), do: Imp.Evaluate.validate_max_errors(value)

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :unsupported},
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

  def compile(%__MODULE__{} = optimizer, student, trainset, opts \\ []) when is_list(opts) do
    opts = validate_compile_options!(opts)
    trainset = Enum.to_list(trainset)

    teacher =
      case Keyword.fetch(opts, :teacher) do
        {:ok, nil} -> student
        {:ok, teacher} -> teacher
        :error -> student
      end

    validate_compatible!(student, teacher)

    {max_errors, max_errors_source} = resolve_optimizer_max_errors!(optimizer)
    optimizer = %{optimizer | max_errors: max_errors}
    student = reset_student(student)

    {teacher, teacher_preparation} =
      prepare_teacher(teacher, trainset, optimizer.max_labeled_demos)

    names = Enum.map(Imp.ProgramParameters.predictors(student), & &1.name)

    {traces, bootstrapped, attempts, errors, repeated_call_selections} =
      bootstrap(teacher, trainset, optimizer, names)

    compiled = train_student(student, trainset, bootstrapped, traces, optimizer, names)

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :bootstrap_few_shot,
        best_score: accepted_average(attempts),
        candidate_count: length(attempts),
        candidates: attempts,
        errors: errors,
        metadata: %{
          selected_count: map_size(bootstrapped),
          bootstrap_attempts: length(attempts),
          max_bootstrapped_demos: optimizer.max_bootstrapped_demos,
          max_labeled_demos: optimizer.max_labeled_demos,
          max_rounds: optimizer.max_rounds,
          max_errors: max_errors,
          max_errors_source: max_errors_source,
          sampling_rng: :beam_native,
          sampling_schedule: :dspy_3_2_1_seed_lifecycle,
          teacher_compilation_marker: :optimizer_report,
          teacher_preparation: teacher_preparation,
          student_preparation: :reset_demos_and_optimizer_report,
          trace_selection_rng: :beam_sha256,
          repeated_call_selections: repeated_call_selections,
          predictor_demo_counts:
            Map.new(Imp.ProgramParameters.predictors(compiled), fn %{
                                                                     name: name,
                                                                     predictor: predictor
                                                                   } ->
              {name, length(predictor.demos)}
            end),
          trainset_size: length(trainset),
          validation_size: length(trainset) - map_size(bootstrapped),
          status: if(errors == [], do: :ok, else: :with_errors)
        }
      })

    attach_report(compiled, report)
  end

  defp validate_compile_options!(opts) do
    Imp.Options.validate!(
      opts,
      @compile_option_schema,
      "Imp.Optimizer.BootstrapFewShot.compile/4"
    )
  end

  defp prepare_teacher(teacher, _trainset, 0), do: {teacher, :labels_disabled}

  defp prepare_teacher(teacher, trainset, max_labeled) do
    if compiled_teacher?(teacher) do
      {teacher, :preserved_compiled_teacher}
    else
      teacher = clear_demos(teacher)

      {teacher, _rng} =
        Enum.reduce(Imp.ProgramParameters.predictors(teacher), {teacher, Sampling.new(0)}, fn %{
                                                                                                name:
                                                                                                  name
                                                                                              },
                                                                                              {program,
                                                                                               rng} ->
          {sampled, rng} = Sampling.shuffle(trainset, rng)
          {Imp.ProgramParameters.put_demos(program, name, Enum.take(sampled, max_labeled)), rng}
        end)

      {teacher, :reset_and_labeled}
    end
  end

  defp compiled_teacher?(teacher) do
    match?(%Report{}, Report.fetch(teacher)) or
      Enum.any?(Imp.ProgramParameters.predictors(teacher), fn %{predictor: predictor} ->
        match?(%Report{}, Report.fetch(predictor))
      end)
  end

  defp bootstrap(teacher, trainset, optimizer, names) do
    initial = {teacher, %{}, Map.new(names, &{&1, []}), [], [], 0, []}

    trainset
    |> Enum.with_index()
    |> Enum.reduce_while(initial, fn {example, example_index},
                                     {teacher, accepted, traces, attempts, errors, error_count,
                                      selections} ->
      if map_size(accepted) >= optimizer.max_bootstrapped_demos do
        {:halt, {teacher, accepted, traces, attempts, errors, error_count, selections}}
      else
        case bootstrap_example(teacher, example, example_index, optimizer, names, error_count) do
          {:accepted, teacher, demos, selection_rows, attempt_rows, attempt_errors, error_count} ->
            {:cont,
             {teacher, Map.put(accepted, example_index, true), merge_traces(traces, demos),
              attempts ++ attempt_rows, errors ++ attempt_errors, error_count,
              selections ++ selection_rows}}

          {:rejected, teacher, attempt_rows, attempt_errors, error_count} ->
            {:cont,
             {teacher, accepted, traces, attempts ++ attempt_rows, errors ++ attempt_errors,
              error_count, selections}}
        end
      end
    end)
    |> then(fn {_teacher, accepted, traces, attempts, errors, _error_count, selections} ->
      {traces, accepted, attempts, errors, selections}
    end)
  end

  defp bootstrap_example(
         teacher,
         _example,
         _example_index,
         %{max_rounds: 0},
         _names,
         error_count
       ),
       do: {:rejected, teacher, [], [], error_count}

  defp bootstrap_example(teacher, example, example_index, optimizer, names, error_count) do
    0..max(optimizer.max_rounds - 1, -1)
    |> Enum.reduce_while({teacher, [], [], error_count}, fn round,
                                                            {teacher, attempts, errors,
                                                             error_count} ->
      stripped_teacher = teacher_without_example_demos(teacher, example)

      metric = optimizer.metric || (&accept_successful_call/2)

      trajectory =
        with_teacher_context(optimizer.teacher_settings, round, fn ->
          [trajectory] =
            TrajectoryRunner.run(stripped_teacher, [example], metric,
              runtime: :evaluation,
              rollout_id: round,
              timeout: optimizer.timeout
            )

          trajectory
        end)

      # The 3.2.1 source restores demos after a successful teacher call but not
      # when the teacher itself raises. Preserve that observable failure state.
      teacher = if program_call_failed?(trajectory), do: stripped_teacher, else: teacher

      accepted? = accepted?(trajectory, optimizer.metric_threshold)

      attempt = %{
        index: example_index,
        round: round,
        score: trajectory.score,
        passed?: accepted?,
        selected?: accepted?,
        feedback: trajectory.feedback
      }

      {errors, error_count} =
        add_error(errors, trajectory, example_index, round, error_count, optimizer.max_errors)

      if accepted? do
        {demos, selections} = choose_trace_demos(trajectory, names)

        {:halt,
         {:accepted, teacher, demos, selections, attempts ++ [attempt], errors, error_count}}
      else
        {:cont, {teacher, attempts ++ [attempt], errors, error_count}}
      end
    end)
    |> case do
      {:accepted, teacher, demos, selections, attempts, errors, error_count} ->
        {:accepted, teacher, demos, selections, attempts, errors, error_count}

      {teacher, attempts, errors, error_count} ->
        {:rejected, teacher, attempts, errors, error_count}
    end
  end

  defp program_call_failed?(%{error: nil}), do: false
  defp program_call_failed?(%{error: {:metric_error, _reason}}), do: false
  defp program_call_failed?(_trajectory), do: true

  defp add_error(errors, %{error: nil}, _index, _round, count, _maximum), do: {errors, count}

  defp add_error(errors, trajectory, index, round, count, maximum) do
    count = count + 1

    if maximum != :infinity and count >= maximum do
      raise RuntimeError,
            "bootstrap error budget exhausted: #{count} errors (maximum #{maximum})"
    end

    error =
      case trajectory.error do
        {:metric_error, reason} ->
          %{index: index, round: round, stage: :metric, reason: error_message(reason)}

        reason ->
          %{index: index, round: round, stage: :program_call, reason: error_message(reason)}
      end

    {errors ++ [error], count}
  end

  defp accepted?(%{error: nil, score: score}, threshold)
       when is_nil(threshold) or threshold == 0,
       do: score != 0

  defp accepted?(%{error: nil, score: score}, threshold), do: score >= threshold
  defp accepted?(_trajectory, _threshold), do: false

  defp choose_trace_demos(trajectory, names) do
    raw = trace_demos(trajectory)

    {entries, selections} =
      Enum.map_reduce(names, [], fn name, selections ->
        demos = Map.get(raw, name, [])
        {selected_demos, selection} = choose_demo(demos, trajectory.index, name)
        selections = if selection, do: [selection | selections], else: selections
        {{name, selected_demos}, selections}
      end)

    {Map.new(entries), Enum.reverse(selections)}
  end

  defp trace_demos(%{trace: trace}) do
    Enum.reduce(trace, %{}, fn
      %{predictor: name, inputs: inputs, outputs: outputs}, acc ->
        Map.update(
          acc,
          name,
          [augmented_demo(inputs, outputs)],
          &(&1 ++ [augmented_demo(inputs, outputs)])
        )

      _step, acc ->
        acc
    end)
  end

  defp choose_demo([], _index, _name), do: {[], nil}
  defp choose_demo([demo], _index, _name), do: {[demo], nil}

  @repeated_call_digest :sha256
  @repeated_call_branch_byte_index 0
  @repeated_call_branch_modulus 2
  @repeated_call_earlier_remainder 0
  @repeated_call_earlier_index_byte_index 1

  defp choose_demo(demos, index, name) do
    selection = repeated_call_selection(demos, index, name)

    evidence =
      selection
      |> Map.delete(:selected_demo)
      |> Map.merge(%{predictor: name, trajectory_index: index, call_count: length(demos)})

    {[selection.selected_demo], evidence}
  end

  @doc false
  def repeated_call_selection(demos, index, name)
      when is_list(demos) and length(demos) > 1 and is_integer(index) and index >= 0 do
    # DSPy selects either the final trace or one earlier trace. Derive that
    # Bernoulli choice from immutable trace data rather than process RNG.
    digest = :crypto.hash(@repeated_call_digest, :erlang.term_to_binary({index, name, demos}))
    branch_byte = :binary.at(digest, @repeated_call_branch_byte_index)
    earlier_index_byte = :binary.at(digest, @repeated_call_earlier_index_byte_index)

    {branch, selected_index} =
      if rem(branch_byte, @repeated_call_branch_modulus) == @repeated_call_earlier_remainder,
        do: {:earlier, rem(earlier_index_byte, length(demos) - 1)},
        else: {:final, length(demos) - 1}

    %{
      algorithm: %{
        digest: @repeated_call_digest,
        payload: :erlang_term_trajectory_index_predictor_name_demos,
        branch_byte_index: @repeated_call_branch_byte_index,
        branch_modulus: @repeated_call_branch_modulus,
        earlier_remainder: @repeated_call_earlier_remainder,
        earlier_index_byte_index: @repeated_call_earlier_index_byte_index,
        probability_basis: :uniform_sha256_branch_byte_parity,
        branch_probability_model: %{earlier: 0.5, final: 0.5}
      },
      sha256: Base.encode16(digest, case: :lower),
      branch_byte: branch_byte,
      earlier_index_byte: earlier_index_byte,
      branch: branch,
      selected_index: selected_index,
      selected_demo: Enum.fetch!(demos, selected_index)
    }
  end

  defp augmented_demo(inputs, outputs) do
    inputs = Map.new(inputs)

    inputs
    |> Map.merge(Map.new(outputs))
    |> Map.put(:augmented, true)
    |> Imp.Example.new()
    |> Imp.Example.with_inputs(Map.keys(inputs))
  end

  defp merge_traces(left, right),
    do: Map.merge(left, right, fn _name, demos, additions -> demos ++ additions end)

  defp train_student(student, trainset, bootstrapped, traces, optimizer, names) do
    {validation, _shuffle_rng} =
      trainset
      |> Enum.with_index()
      |> Enum.reject(fn {_example, index} -> Map.has_key?(bootstrapped, index) end)
      |> Enum.map(&elem(&1, 0))
      |> then(&Sampling.shuffle(&1, Sampling.new(0)))

    sampling_rng = Sampling.new(0)

    {compiled, _validation, _rng} =
      Enum.reduce(names, {student, validation, sampling_rng}, fn name,
                                                                 {program, raw_demos, rng} ->
        augmented = traces |> Map.get(name, []) |> Enum.take(optimizer.max_bootstrapped_demos)

        sample_size =
          max(0, min(optimizer.max_labeled_demos - length(augmented), length(raw_demos)))

        {sampled, rng} = sample(raw_demos, sample_size, rng)
        {Imp.ProgramParameters.put_demos(program, name, augmented ++ sampled), sampled, rng}
      end)

    compiled
  end

  defp sample(_rows, 0, rng), do: {[], rng}

  defp sample(rows, count, rng) do
    {shuffled, rng} = Sampling.shuffle(rows, rng)
    {Enum.take(shuffled, count), rng}
  end

  defp clear_demos(program) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      Imp.ProgramParameters.put_demos(acc, name, [])
    end)
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

  defp teacher_without_example_demos(program, example) do
    fields = Imp.Example.to_map(example)

    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{
                                                                         name: name,
                                                                         predictor: predictor
                                                                       },
                                                                       acc ->
      demos = Enum.reject(predictor.demos, &(Imp.Example.to_map(&1) == fields))
      Imp.ProgramParameters.put_demos(acc, name, demos)
    end)
  end

  defp with_teacher_context(settings, round, fun) do
    Imp.Settings.context(settings, fn ->
      if round > 0 do
        lm = Imp.Settings.fetch!(:lm)

        rollout_lm = fn messages, opts ->
          Imp.LM.generate(lm, messages, Keyword.merge(opts, rollout_id: round, temperature: 1.0))
        end

        Imp.Settings.context([lm: rollout_lm], fun)
      else
        fun.()
      end
    end)
  end

  defp resolve_optimizer_max_errors!(%__MODULE__{max_errors: nil} = optimizer) do
    source =
      if Keyword.has_key?(optimizer.teacher_settings, :max_errors),
        do: :teacher_settings,
        else: :settings

    Imp.Settings.context(optimizer.teacher_settings, fn ->
      {Imp.Settings.fetch!(:max_errors) |> validate_max_errors!(), source}
    end)
  end

  defp resolve_optimizer_max_errors!(%__MODULE__{max_errors: value}),
    do: {validate_max_errors!(value), :explicit}

  defp validate_max_errors!(value) do
    case Imp.Evaluate.validate_max_errors(value) do
      {:ok, max_errors} ->
        max_errors

      {:error, message} ->
        raise ArgumentError, "invalid effective :max_errors setting: #{message}"
    end
  end

  defp validate_compatible!(student, teacher) do
    left = Enum.map(Imp.ProgramParameters.predictors(student), &{&1.name, &1.predictor.signature})

    right =
      Enum.map(Imp.ProgramParameters.predictors(teacher), &{&1.name, &1.predictor.signature})

    unless left == right,
      do:
        raise(ArgumentError, "student and teacher must have the same named predictor signatures")
  end

  defp accept_successful_call(_example, _prediction), do: true

  defp accepted_average([]), do: 0.0
  defp accepted_average(attempts), do: Enum.sum(Enum.map(attempts, & &1.score)) / length(attempts)

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

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
