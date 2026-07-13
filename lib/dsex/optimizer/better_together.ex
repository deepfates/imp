defmodule DSEx.Optimizer.BetterTogether do
  @moduledoc """
  Evaluate-and-select meta-optimizer for prompt and weight optimization sequences.

  DSEx evaluates the original program and every successfully compiled strategy
  prefix. With validation data it returns the highest-scoring candidate, with
  earlier candidates winning ties; without validation it returns the latest
  successful candidate. Compilation stops at the first failed step.

  Unlike upstream DSPy, DSEx provider training does not manage model process
  lifecycles or rebind a completed fine-tuned model. A `BootstrapFinetune`
  provider error is therefore reported as a failed step rather than represented
  as successful weight optimization.
  """

  alias DSEx.Optimizer.{BootstrapFinetune, Report, Sampling}

  defstruct [:metric, optimizers: %{}]

  @option_schema [
    strategy: [
      type: {:custom, __MODULE__, :validate_strategy, []},
      default: "p -> w -> p"
    ],
    valset_ratio: [
      type: {:custom, __MODULE__, :validate_valset_ratio, []},
      default: 0.1
    ],
    shuffle_trainset_between_steps: [type: :boolean, default: true],
    seed: [type: :integer, default: 0],
    max_errors: [
      type: {:custom, DSEx.Evaluate, :validate_max_errors, []},
      default: :infinity
    ],
    max_concurrency: [type: :pos_integer, default: 1]
  ]

  def new(metric, optimizers \\ %{}) do
    DSEx.FunctionContract.validate!(metric, 2, "DSEx.Optimizer.BetterTogether.new/2", "metric")
    optimizers = normalize_optimizers!(optimizers)

    optimizers =
      if map_size(optimizers) == 0 do
        %{
          p: DSEx.Optimizer.RandomSearch.new(metric),
          w: BootstrapFinetune.new(metric)
        }
      else
        optimizers
      end

    %__MODULE__{metric: metric, optimizers: optimizers}
  end

  def compile(%__MODULE__{} = bt, student, trainset, valset, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.BetterTogether.compile/5")
    steps = strategy_steps(opts[:strategy])
    {trainset, valset} = prepare_validation!(trainset, valset, opts[:valset_ratio])
    evaluator = evaluator(bt.metric, valset, opts)

    baseline = evaluate_candidate(student, [], nil, evaluator, 0)
    rng = Sampling.new(opts[:seed])

    {candidates, errors, _rng} =
      run_steps(
        bt,
        steps,
        student,
        trainset,
        valset,
        evaluator,
        opts[:shuffle_trainset_between_steps],
        rng,
        [baseline],
        []
      )

    selected = select_candidate(candidates, valset)
    baseline = hd(candidates)
    report_candidates = report_candidates(candidates)

    Report.attach(
      selected.program,
      Report.new(%{
        optimizer: :better_together,
        best_score: selected.score,
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: errors,
        metadata: %{
          strategy: opts[:strategy],
          steps: steps,
          selected_strategy: selected.strategy,
          baseline_score: baseline.score,
          baseline_evaluation: baseline.evaluation,
          validation_size: validation_size(valset),
          trainset_size: length(trainset),
          compilation_error_occurred: errors != [],
          stopped_early: errors != [],
          provider_training_semantics:
            :jobs_are_reported_but_trained_model_rebinding_and_lifecycle_are_not_available
        }
      })
    )
  end

  def validate_strategy(strategy) do
    case strategy_steps(strategy) do
      [_ | _] = steps ->
        if Enum.all?(steps, &valid_strategy_step?/1) do
          {:ok, strategy}
        else
          {:error, "expected a non-empty optimizer key, \"a -> b\" string, or list of keys"}
        end

      _empty ->
        {:error, "expected a non-empty optimizer key, \"a -> b\" string, or list of keys"}
    end
  end

  def validate_valset_ratio(value) when is_number(value) and value >= 0 and value < 1,
    do: {:ok, value}

  def validate_valset_ratio(value),
    do: {:error, "expected a number in the range [0, 1), got: #{inspect(value)}"}

  defp prepare_validation!(trainset, valset, ratio) do
    trainset = enumerable_to_list!(trainset, "trainset")

    if trainset == [] do
      raise ArgumentError, "DSEx.Optimizer.BetterTogether.compile/5: trainset cannot be empty"
    end

    case optional_enumerable_to_list!(valset, "valset") do
      [_ | _] = provided ->
        {trainset, provided}

      [] when ratio == 0 ->
        {trainset, nil}

      [] ->
        Enum.split(trainset, floor(ratio * length(trainset)))
        |> then(fn {validation, training} -> {training, validation} end)
    end
  end

  defp enumerable_to_list!(value, name) do
    if Enumerable.impl_for(value) do
      Enum.to_list(value)
    else
      raise ArgumentError,
            "DSEx.Optimizer.BetterTogether.compile/5: #{name} must be enumerable, got: #{inspect(value)}"
    end
  end

  defp optional_enumerable_to_list!(nil, _name), do: []
  defp optional_enumerable_to_list!(value, name), do: enumerable_to_list!(value, name)

  defp evaluator(_metric, nil, _opts), do: nil
  defp evaluator(_metric, [], _opts), do: nil

  defp evaluator(metric, valset, opts) do
    DSEx.Evaluate.new(valset, metric,
      max_errors: opts[:max_errors],
      max_concurrency: opts[:max_concurrency]
    )
  end

  defp run_steps(
         _bt,
         [],
         _student,
         _trainset,
         _valset,
         _evaluator,
         _shuffle?,
         rng,
         candidates,
         errors
       ),
       do: {candidates, errors, rng}

  defp run_steps(
         bt,
         [key | rest],
         student,
         trainset,
         valset,
         evaluator,
         shuffle?,
         rng,
         candidates,
         errors
       ) do
    {step_trainset, rng} = maybe_shuffle(trainset, shuffle?, rng)
    strategy = Enum.map(candidates, & &1.key) |> Enum.reject(&is_nil/1) |> Kernel.++([key])
    index = length(candidates)

    result =
      with {:ok, optimizer} <- fetch_optimizer(bt.optimizers, key),
           {:ok, compiled, compile_metadata} <-
             compile_step(optimizer, student, step_trainset, valset) do
        {:ok,
         evaluate_candidate(compiled, strategy, key, evaluator, index)
         |> Map.put(:compile_metadata, compile_metadata)}
      end

    case result do
      {:ok, candidate} ->
        run_steps(
          bt,
          rest,
          candidate.program,
          trainset,
          valset,
          evaluator,
          shuffle?,
          rng,
          candidates ++ [candidate],
          errors
        )

      {:error, reason} ->
        failed = %{
          index: index,
          key: key,
          strategy: strategy_label(strategy),
          status: :error,
          error: reason
        }

        {candidates ++ [failed], errors ++ [%{index: index, key: key, error: reason}], rng}
    end
  end

  defp evaluate_candidate(program, strategy, key, nil, index) do
    %{
      index: index,
      key: key,
      strategy: strategy_label(strategy),
      score: nil,
      status: :ok,
      evaluation: %{validation_size: 0, errors: []},
      program: program
    }
  end

  defp evaluate_candidate(program, strategy, key, evaluator, index) do
    result = DSEx.Evaluate.run(evaluator, program)

    %{
      index: index,
      key: key,
      strategy: strategy_label(strategy),
      score: result.score,
      status: :ok,
      evaluation: %{
        validation_size: length(result.rows),
        error_count: length(result.errors),
        errors: result.errors
      },
      program: program
    }
  end

  # Preserve the established DSEx error-only report shape when the first step
  # cannot compile. Baseline diagnostics remain available in report metadata.
  defp report_candidates([
         %{key: nil, status: :ok},
         %{status: :error} = failed
       ]) do
    [Map.take(failed, [:key, :status, :error])]
  end

  defp report_candidates(candidates), do: Enum.map(candidates, &Map.delete(&1, :program))

  defp select_candidate(candidates, nil), do: latest_successful(candidates)
  defp select_candidate(candidates, []), do: latest_successful(candidates)

  defp select_candidate(candidates, _valset) do
    candidates
    |> Enum.filter(&(&1.status == :ok))
    |> Enum.max_by(& &1.score, fn -> raise "BetterTogether produced no candidate" end)
  end

  defp latest_successful(candidates) do
    candidates
    |> Enum.filter(&(&1.status == :ok))
    |> List.last()
  end

  defp maybe_shuffle(trainset, false, rng), do: {trainset, rng}
  defp maybe_shuffle(trainset, true, rng), do: Sampling.shuffle(trainset, rng)

  defp validation_size(nil), do: 0
  defp validation_size(valset), do: length(valset)

  defp strategy_label([]), do: ""

  defp strategy_label(strategy),
    do: Enum.map_join(strategy, " -> ", &to_string/1)

  defp strategy_steps(strategy) when is_binary(strategy) do
    strategy
    |> String.split(~r/\s*->\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strategy_steps(strategy), do: List.wrap(strategy)

  defp valid_strategy_step?(step) when is_atom(step), do: true
  defp valid_strategy_step?(step) when is_binary(step), do: String.trim(step) != ""
  defp valid_strategy_step?(_step), do: false

  defp compile_step(%BootstrapFinetune{} = optimizer, program, trainset, _valset) do
    case safe_call(fn -> BootstrapFinetune.compile(optimizer, program, trainset) end) do
      {:ok, %{program: compiled, error: reason}} ->
        {:error,
         {:provider_training_failed, reason, %{compiled_program_available: compiled != nil}}}

      {:ok, %{program: compiled, job: job}} ->
        {:ok, compiled,
         %{
           optimizer: BootstrapFinetune,
           job: job,
           trained_model_rebound?: false,
           provider_lifecycle_managed?: false
         }}

      {:ok, other} ->
        {:error, {:invalid_optimizer_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_step(optimizer, program, trainset, valset) do
    cond do
      not is_map(optimizer) or not Map.has_key?(optimizer, :__struct__) ->
        {:error, {:invalid_optimizer, optimizer}}

      not optimizer_module_loaded?(optimizer.__struct__) ->
        {:error, {:optimizer_not_loaded, optimizer.__struct__}}

      function_exported?(optimizer.__struct__, :compile, 4) ->
        safe_compile(optimizer, fn ->
          optimizer.__struct__.compile(optimizer, program, trainset, valset)
        end)

      function_exported?(optimizer.__struct__, :compile, 3) ->
        safe_compile(optimizer, fn ->
          optimizer.__struct__.compile(optimizer, program, trainset)
        end)

      true ->
        {:error, {:unsupported_optimizer, optimizer.__struct__}}
    end
  end

  defp safe_compile(optimizer, fun) do
    case safe_call(fun) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, compiled} -> {:ok, compiled, %{optimizer: optimizer.__struct__}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optimizer_module_loaded?(module) when is_atom(module), do: Code.ensure_loaded?(module)
  defp optimizer_module_loaded?(_module), do: false

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fetch_optimizer(optimizers, key) do
    cond do
      Map.has_key?(optimizers, key) ->
        {:ok, Map.fetch!(optimizers, key)}

      Map.has_key?(optimizers, existing_atom_or_string(key)) ->
        {:ok, Map.fetch!(optimizers, existing_atom_or_string(key))}

      true ->
        {:error, {:unknown_optimizer, key}}
    end
  end

  defp existing_atom_or_string(key) when is_atom(key), do: Atom.to_string(key)

  defp existing_atom_or_string(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp existing_atom_or_string(key), do: key

  defp normalize_optimizers!(optimizers) do
    Map.new(optimizers)
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      reraise ArgumentError,
              "DSEx.Optimizer.BetterTogether.new/2 expects optimizers to be an enumerable of key/value pairs; got: #{inspect(optimizers)} (#{Exception.message(error)})",
              __STACKTRACE__
  end
end
