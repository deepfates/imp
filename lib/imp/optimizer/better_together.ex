defmodule Imp.Optimizer.BetterTogether do
  @behaviour Imp.Optimizer
  @moduledoc """
  Evaluate-and-select meta-optimizer for prompt and weight optimization sequences.

  Imp evaluates the original program and every successfully compiled strategy
  prefix. With validation data it returns the highest-scoring candidate, with
  earlier candidates winning ties; without validation it returns the latest
  successful candidate. Compilation stops at the first failed step.

  Training steps contribute a candidate only after returning a completed,
  rebound `Imp.Optimizer.TrainingResult`. `Imp.Clients.TrainingJob` results are
  polled to a terminal state under a bounded timeout and pending jobs receive a
  bounded cancellation attempt; the sequence never advances on a merely
  submitted job. Generic asynchronous optimizers must return this job type. The
  default weight optimizer has no inferred provider: callers must replace it or
  configure a BootstrapFinetune trainer before a weight-bearing strategy can run.
  """

  alias Imp.Clients.TrainingJob
  alias Imp.Optimizer.{BootstrapFinetune, Report, Sampling, TrainingError}
  alias Imp.Optimizer.BootstrapFinetune.TrainingPlan

  @type teacher :: struct() | [struct()] | nil
  @type step_request :: %{
          optimizer: struct(),
          program: struct(),
          trainset: list(),
          validation: list() | nil,
          teacher: teacher(),
          invocation_opts: keyword(),
          training_launch_timeout: pos_integer(),
          training_timeout: non_neg_integer(),
          training_poll_interval: non_neg_integer(),
          training_cancellation_timeout: non_neg_integer()
        }

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
    optimizer_compile_args: [
      type: {:custom, __MODULE__, :validate_optimizer_compile_args, []},
      default: %{}
    ],
    teacher: [type: {:custom, BootstrapFinetune, :validate_teacher, []}, default: nil],
    max_errors: [
      type: {:custom, Imp.Evaluate, :validate_max_errors, []},
      default: :infinity
    ],
    max_concurrency: [type: :pos_integer, default: 1],
    training_launch_timeout: [type: :pos_integer, default: 300_000],
    training_timeout: [type: :non_neg_integer, default: 300_000],
    training_poll_interval: [type: :non_neg_integer, default: 1_000],
    training_cancellation_timeout: [type: :non_neg_integer, default: 5_000]
  ]

  def new(metric, optimizers \\ %{}) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.BetterTogether.new/2", "metric")
    optimizers = normalize_optimizers!(optimizers)

    optimizers =
      if map_size(optimizers) == 0 do
        %{
          p: Imp.Optimizer.RandomSearch.new(metric),
          w: BootstrapFinetune.new(metric)
        }
      else
        optimizers
      end

    %__MODULE__{metric: metric, optimizers: optimizers}
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :optional},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    {:ok,
     compile(
       optimizer,
       program,
       Imp.Optimizer.fetch_dataset!(opts, :trainset),
       Keyword.get(opts, :validation),
       Imp.Optimizer.invocation_options(opts)
     )}
  end

  def compile(%__MODULE__{} = bt, student, trainset, valset, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.BetterTogether.compile/5")
    :ok = ensure_report_storage(student)
    steps = strategy_steps(opts[:strategy])
    {trainset, valset} = prepare_validation!(trainset, valset, opts[:valset_ratio])
    evaluator = evaluator(bt.metric, valset, opts)

    baseline = evaluate_candidate(student, [], nil, evaluator, 0)
    rng = Sampling.new(opts[:seed])

    execution = %{
      valset: valset,
      evaluator: evaluator,
      shuffle?: opts[:shuffle_trainset_between_steps],
      optimizer_compile_args: opts[:optimizer_compile_args],
      teacher: opts[:teacher],
      training_launch_timeout: opts[:training_launch_timeout],
      training_timeout: opts[:training_timeout],
      training_poll_interval: opts[:training_poll_interval],
      training_cancellation_timeout: opts[:training_cancellation_timeout]
    }

    {candidates, errors, _rng} =
      run_steps(
        bt,
        steps,
        student,
        trainset,
        execution,
        rng,
        [baseline],
        []
      )

    selected = select_candidate(candidates, valset)
    baseline = hd(candidates)
    report_candidates = report_candidates(candidates)

    attach_report!(
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
          provider_training_semantics: :bounded_await_and_atomic_rebind,
          training_launch_timeout: opts[:training_launch_timeout],
          training_launch_timeout_semantics:
            :bounds_local_compile_and_callbacks_but_cannot_disprove_late_provider_acceptance,
          training_timeout: opts[:training_timeout],
          training_poll_interval: opts[:training_poll_interval],
          training_cancellation_timeout: opts[:training_cancellation_timeout],
          weight_provider_boundary: weight_provider_boundary(bt.optimizers)
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

  def validate_optimizer_compile_args(value) do
    value
    |> Map.new()
    |> Enum.reduce_while({:ok, %{}}, fn {key, opts}, {:ok, normalized} ->
      if valid_strategy_step?(key) and is_list(opts) and Keyword.keyword?(opts) and
           not Keyword.has_key?(opts, :student) do
        {:cont, {:ok, Map.put(normalized, key, opts)}}
      else
        {:halt,
         {:error,
          "expected a map of optimizer keys to keyword compile options, got: #{inspect(value)}"}}
      end
    end)
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] ->
      {:error,
       "expected a map of optimizer keys to keyword compile options, got: #{inspect(value)}"}
  end

  defp prepare_validation!(trainset, valset, ratio) do
    trainset = enumerable_to_list!(trainset, "trainset")

    if trainset == [] do
      raise ArgumentError, "Imp.Optimizer.BetterTogether.compile/5: trainset cannot be empty"
    end

    case valset do
      nil when ratio == 0 ->
        {trainset, nil}

      nil ->
        Enum.split(trainset, floor(ratio * length(trainset)))
        |> then(fn {validation, training} -> {training, validation} end)

      provided ->
        {trainset, enumerable_to_list!(provided, "valset")}
    end
  end

  defp enumerable_to_list!(value, name) do
    if Enumerable.impl_for(value) do
      Enum.to_list(value)
    else
      raise ArgumentError,
            "Imp.Optimizer.BetterTogether.compile/5: #{name} must be enumerable, got: #{inspect(value)}"
    end
  end

  defp evaluator(_metric, nil, _opts), do: nil
  defp evaluator(_metric, [], _opts), do: nil

  defp evaluator(metric, valset, opts) do
    Imp.Evaluate.new(valset, metric,
      max_errors: opts[:max_errors],
      max_concurrency: opts[:max_concurrency]
    )
  end

  defp run_steps(
         _bt,
         [],
         _student,
         _trainset,
         _execution,
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
         execution,
         rng,
         candidates,
         errors
       ) do
    {step_trainset, rng} = maybe_shuffle(trainset, execution.shuffle?, rng)
    strategy = Enum.map(candidates, & &1.key) |> Enum.reject(&is_nil/1) |> Kernel.++([key])
    index = length(candidates)

    result =
      with {:ok, optimizer} <- fetch_optimizer(bt.optimizers, key),
           {:ok, compiled, compile_metadata} <-
             safely_compile_step(
               optimizer,
               student,
               step_trainset,
               execution.valset,
               compile_args_for(execution.optimizer_compile_args, key),
               execution
             ) do
        {:ok,
         evaluate_candidate(compiled, strategy, key, execution.evaluator, index)
         |> Map.put(:compile_metadata, compile_metadata)}
      end

    case result do
      {:ok, candidate} ->
        run_steps(
          bt,
          rest,
          candidate.program,
          trainset,
          execution,
          rng,
          candidates ++ [candidate],
          errors
        )

      {:error, reason, diagnostics} ->
        failed = %{
          index: index,
          key: key,
          strategy: strategy_label(strategy),
          status: :error,
          error: reason,
          diagnostics: diagnostics
        }

        {candidates ++ [failed],
         errors ++ [%{index: index, key: key, error: reason, diagnostics: diagnostics}], rng}

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
    result = Imp.Evaluate.run(evaluator, program)

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

  # Preserve the established Imp error-only report shape when the first step
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

  defp compile_step(optimizer, program, trainset, valset, step_opts, execution) do
    with {:ok, capabilities} <- Imp.Optimizer.capabilities(optimizer),
         :ok <- allowed_step_kind(capabilities.kind),
         {:ok, request} <-
           build_step_request(
             optimizer,
             program,
             trainset,
             valset,
             step_opts,
             capabilities,
             execution
           ) do
      execute_step(request, capabilities)
    end
  end

  defp safely_compile_step(optimizer, program, trainset, valset, step_opts, execution) do
    compile_step(optimizer, program, trainset, valset, step_opts, execution)
  rescue
    error ->
      {:error, {:optimizer_step_raised, optimizer.__struct__, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:optimizer_step_threw, optimizer.__struct__, kind, reason}}
  end

  @spec build_step_request(
          struct(),
          struct(),
          term(),
          term(),
          keyword(),
          Imp.Optimizer.capabilities(),
          map()
        ) :: {:ok, step_request()} | {:error, term()}
  defp build_step_request(
         optimizer,
         program,
         trainset,
         valset,
         step_opts,
         capabilities,
         execution
       ) do
    teacher = Keyword.get(step_opts, :teacher, execution.teacher)

    with {:ok, teacher} <- BootstrapFinetune.validate_teacher(teacher) do
      invocation_opts =
        capabilities
        |> step_opts_for_capabilities(
          trainset,
          valset,
          Keyword.delete(step_opts, :teacher)
        )

      {:ok,
       %{
         optimizer: optimizer,
         program: program,
         trainset: Keyword.fetch!(invocation_opts, :trainset),
         validation: Keyword.get(invocation_opts, :validation),
         teacher: teacher,
         invocation_opts: invocation_opts,
         training_launch_timeout: execution.training_launch_timeout,
         training_timeout: execution.training_timeout,
         training_poll_interval: execution.training_poll_interval,
         training_cancellation_timeout: execution.training_cancellation_timeout
       }}
    else
      {:error, reason} -> {:error, {:invalid_step_teacher, optimizer.__struct__, reason}}
    end
  end

  defp execute_step(
         %{optimizer: %Imp.Optimizer.GEPA{}, teacher: teacher},
         _capabilities
       )
       when not is_nil(teacher),
       do: {:error, {:teacher_not_supported, Imp.Optimizer.GEPA}}

  defp execute_step(
         %{optimizer: %Imp.Optimizer.BootstrapFewShot{} = optimizer} = request,
         %{kind: :program}
       ) do
    with :ok <- reject_compile_options(request, Imp.Optimizer.BootstrapFewShot),
         {:ok, teacher} <- single_teacher(request.teacher) do
      opts = if is_nil(teacher), do: [], else: [teacher: teacher]

      compiled =
        Imp.Optimizer.BootstrapFewShot.compile(optimizer, request.program, request.trainset, opts)

      {:ok, compiled,
       %{
         optimizer: Imp.Optimizer.BootstrapFewShot,
         kind: :program,
         teacher: teacher_presence(teacher)
       }}
    end
  end

  defp execute_step(
         %{optimizer: %BootstrapFinetune{} = optimizer} = request,
         %{kind: :training}
       ) do
    with :ok <- reject_compile_options(request, BootstrapFinetune) do
      optimizer =
        if is_nil(request.teacher), do: optimizer, else: %{optimizer | teacher: request.teacher}

      case bounded_bootstrap_compile(request, optimizer) do
        %{program: compiled, plan: %TrainingPlan{} = plan, error: reason} ->
          bootstrap_start_error(compiled, plan, reason)

        %{program: compiled, error: reason} ->
          {:error, {:training_not_started, reason, compiled}}

        %{program: compiled, plan: %TrainingPlan{} = plan} ->
          resolve_bootstrap_step(request, optimizer, compiled, plan)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_step(request, %{kind: :training} = capabilities) do
    invocation_opts = maybe_put_teacher(request.invocation_opts, request.teacher)

    with :ok <- validate_generic_datasets(capabilities.datasets, invocation_opts),
         {:ok, compiled} <- invoke_generic_training_optimizer(request, invocation_opts) do
      case compiled do
        %Imp.Optimizer.TrainingResult{status: :completed} = result ->
          case validate_generic_training_result(result) do
            :ok ->
              {:ok, result.program,
               %{
                 optimizer: request.optimizer.__struct__,
                 kind: :training,
                 training_status: result.status,
                 awaited: false
               }}

            {:error, reason} ->
              reject_invalid_training_result(request, result, reason)
          end

        %Imp.Optimizer.TrainingResult{status: :job_created} = result ->
          case validate_generic_training_result(result) do
            :ok -> resolve_generic_training_step(request, result)
            {:error, reason} -> reject_invalid_training_result(request, result, reason)
          end

        %Imp.Optimizer.TrainingResult{} = result ->
          reject_noncanonical_training_result(request, result)
      end
    end
  end

  defp execute_step(request, capabilities) do
    invocation_opts = maybe_put_teacher(request.invocation_opts, request.teacher)

    with {:ok, compiled} <-
           Imp.Optimizer.run_resolved(
             request.optimizer,
             request.program,
             invocation_opts,
             capabilities
           ) do
      {:ok, compiled, %{optimizer: request.optimizer.__struct__, kind: :program}}
    end
  end

  defp bounded_bootstrap_compile(request, optimizer) do
    reference = make_ref()

    optimizer = %{
      optimizer
      | launch_timeout: min(optimizer.launch_timeout, request.training_launch_timeout),
        cancellation_timeout:
          min(optimizer.cancellation_timeout, request.training_cancellation_timeout),
        lifecycle_observer: {self(), reference}
    }

    task =
      Task.Supervisor.async_nolink(Imp.UnlinkedTaskSupervisor, fn ->
        result = BootstrapFinetune.compile(optimizer, request.program, request.trainset)
        {result, drain_compile_messages()}
      end)

    case Task.yield(task, request.training_launch_timeout) do
      {:ok, {result, messages}} ->
        relay_compile_messages(messages)
        drain_bootstrap_lifecycle(reference)
        result

      {:exit, reason} ->
        events = drain_bootstrap_lifecycle(reference)
        bootstrap_launch_failure(request, events, {:training_launch_task_exit, reason})

      nil ->
        Task.shutdown(task, :brutal_kill)
        events = drain_bootstrap_lifecycle(reference)

        bootstrap_launch_failure(
          request,
          events,
          {:training_step_launch_timeout, BootstrapFinetune, request.training_launch_timeout}
        )
    end
  rescue
    error ->
      {:error, {:training_launch_task_failed, BootstrapFinetune, Exception.message(error)}}
  end

  defp drain_bootstrap_lifecycle(reference, events \\ []) do
    receive do
      {BootstrapFinetune, ^reference, event} ->
        drain_bootstrap_lifecycle(reference, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp drain_compile_messages(messages \\ []) do
    receive do
      message -> drain_compile_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp relay_compile_messages(messages), do: Enum.each(messages, &send(self(), &1))

  defp bootstrap_launch_failure(request, events, reason) do
    case observed_training_plan(events) do
      %TrainingPlan{} = plan ->
        {cancelled, cancellations} =
          BootstrapFinetune.__cancel_training_plan__(plan, :all_started,
            deadline: cancellation_deadline(request)
          )

        {:error, bootstrap_launch_reason(reason, training_plan_summary(cancelled), cancellations)}

      nil ->
        {:error, bootstrap_launch_reason(reason, [], [])}
    end
  end

  defp bootstrap_launch_reason(
         {:training_step_launch_timeout, optimizer, timeout},
         summaries,
         cancellations
       ) do
    {:training_step_launch_timeout, optimizer, timeout, summaries, cancellations,
     :provider_acceptance_after_callback_timeout_cannot_be_observed}
  end

  defp bootstrap_launch_reason(reason, summaries, cancellations) do
    {:training_launch_failed, reason, summaries, cancellations,
     :provider_acceptance_after_callback_timeout_cannot_be_observed}
  end

  defp observed_training_plan(events) do
    Enum.reduce(events, nil, fn
      {:plan, %TrainingPlan{} = plan}, _current ->
        plan

      {:started, index, %TrainingJob{} = job}, %TrainingPlan{} = plan ->
        %{plan | entries: List.update_at(plan.entries, index, &%{&1 | job: job})}

      _event, current ->
        current
    end)
  end

  defp invoke_generic_training_optimizer(%{optimizer: %module{} = optimizer} = request, opts) do
    case module.run(optimizer, request.program, opts) do
      {:ok, %Imp.Optimizer.TrainingResult{} = result} -> {:ok, result}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_optimizer_result, :training_result, other}}
    end
  rescue
    error -> {:error, {:optimizer_failed, module, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:optimizer_failed, module, {kind, reason}}}
  end

  defp validate_generic_training_result(%Imp.Optimizer.TrainingResult{} = result) do
    cond do
      not executable_program?(result.program) ->
        {:error, {:invalid_optimizer_program, result.program}}

      not is_map(result.metadata) ->
        {:error, {:invalid_training_metadata, result.metadata}}

      result.status == :job_created and is_nil(result.job) ->
        {:error, :training_job_required}

      result.status == :completed and match?(%TrainingJob{}, result.job) and
          TrainingJob.active_status?(result.job.status) ->
        {:error, {:completed_training_job_active, training_job_summary(result.job)}}

      true ->
        :ok
    end
  end

  defp executable_program?(%module{}),
    do: Code.ensure_loaded?(module) and function_exported?(module, :call, 2)

  defp executable_program?(_program), do: false

  defp validate_generic_datasets(requirements, opts) do
    Enum.reduce_while(requirements, :ok, fn {name, requirement}, :ok ->
      present? = Keyword.has_key?(opts, name)
      value = Keyword.get(opts, name)

      result =
        case requirement do
          :required when not present? -> {:error, {:missing_dataset, name}}
          :required -> validate_generic_dataset_value(name, value)
          :optional when not present? -> :ok
          :optional -> validate_generic_dataset_value(name, value)
          :unsupported when present? -> {:error, {:unsupported_dataset, name}}
          :unsupported -> :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_generic_dataset_value(name, nil), do: {:error, {:invalid_dataset, name, nil}}

  defp validate_generic_dataset_value(name, value) do
    if Enumerable.impl_for(value), do: :ok, else: {:error, {:invalid_dataset, name, value}}
  end

  defp reject_invalid_training_result(request, result, reason) do
    reason = {:invalid_training_result, request.optimizer.__struct__, reason}

    case result.job do
      %TrainingJob{status: status} = job ->
        if TrainingJob.active_status?(status),
          do: generic_training_cleanup(request, job, reason),
          else: {:error, reason}

      _other ->
        {:error, reason}
    end
  end

  defp reject_noncanonical_training_result(request, result) do
    reason =
      {:invalid_training_result_status, request.optimizer.__struct__, result.status,
       malformed_training_job_summary(result.job)}

    case result.job do
      %TrainingJob{status: status} = job ->
        if TrainingJob.active_status?(status),
          do: generic_training_cleanup(request, job, reason),
          else: {:error, reason}

      _other ->
        {:error, reason}
    end
  end

  defp malformed_training_job_summary(%TrainingJob{} = job), do: training_job_summary(job)
  defp malformed_training_job_summary(job), do: %{job: Report.json_safe(job)}

  defp resolve_generic_training_step(
         request,
         %Imp.Optimizer.TrainingResult{job: %TrainingJob{status: status} = job} = result
       ) do
    cond do
      TrainingJob.terminal_status?(status) ->
        resolve_generic_terminal(request, result, job, false)

      TrainingJob.active_status?(status) ->
        deadline = monotonic_ms() + request.training_timeout
        do_await_generic_training_step(request, result, job, deadline)

      true ->
        {:error, {:unknown_training_status, request.optimizer.__struct__, status, job.metadata}}
    end
  end

  defp resolve_generic_training_step(request, %Imp.Optimizer.TrainingResult{job: job}) do
    {:error, {:training_job_protocol_required, request.optimizer.__struct__, TrainingJob, job}}
  end

  defp do_await_generic_training_step(request, result, job, deadline) do
    if monotonic_ms() >= deadline do
      generic_training_timeout(request, job)
    else
      remaining = max(deadline - monotonic_ms(), 0)

      case bounded_job_refresh(job, remaining) do
        {:ok, %TrainingJob{} = refreshed} ->
          cond do
            TrainingJob.terminal_status?(refreshed.status) ->
              resolve_generic_terminal(request, result, refreshed, true)

            TrainingJob.active_status?(refreshed.status) ->
              sleep_until_next_poll(request.training_poll_interval, deadline)
              do_await_generic_training_step(request, result, refreshed, deadline)

            true ->
              {:error,
               {:unknown_training_status, request.optimizer.__struct__, refreshed.status,
                refreshed.metadata}}
          end

        {:error, reason} ->
          generic_training_cleanup(
            request,
            job,
            {:training_step_refresh_failed, request.optimizer.__struct__,
             [
               %{job_id: job.id, status: job.status, reason: reason}
             ]}
          )

        :timeout ->
          generic_training_timeout(request, job)
      end
    end
  end

  defp resolve_generic_terminal(
         request,
         %Imp.Optimizer.TrainingResult{program: program},
         %TrainingJob{status: :succeeded} = job,
         awaited?
       ) do
    case TrainingJob.rebind(job, program) do
      {:ok, rebound} ->
        {:ok, rebound,
         %{
           optimizer: request.optimizer.__struct__,
           kind: :training,
           training_status: :completed,
           awaited: awaited?
         }}

      {:error, reason} ->
        {:error, {:training_rebind_failed, reason}}
    end
  end

  defp resolve_generic_terminal(
         _request,
         _result,
         %TrainingJob{status: status, metadata: metadata},
         _awaited?
       ) do
    {:error, {:training_failed, status, metadata}}
  end

  defp generic_training_timeout(request, job) do
    generic_training_cleanup(
      request,
      job,
      {:training_step_timeout, request.optimizer.__struct__, request.training_timeout,
       training_job_summary(job)}
    )
  end

  defp generic_training_cleanup(request, job, reason) do
    {_cancelled_job, cancellation} = cancel_generic_training_job(request, job)
    {:error, with_generic_cancellation(reason, cancellation)}
  end

  defp cancel_generic_training_job(request, %TrainingJob{} = job) do
    if not TrainingJob.active_status?(job.status) do
      {job, nil}
    else
      timeout = max(cancellation_deadline(request) - monotonic_ms(), 0)

      outcome =
        case bounded_job_cancel(job, timeout) do
          {:ok, %TrainingJob{status: status} = cancelled} ->
            %{
              job_id: job.id,
              prior_status: job.status,
              status: status,
              result: :ok,
              job: cancelled
            }

          {:error, {:training_cancel_incomplete, status, metadata} = reason} ->
            %{
              job_id: job.id,
              prior_status: job.status,
              status: status,
              result: {:error, reason},
              job: %{job | status: status, metadata: metadata}
            }

          {:error, reason} ->
            %{
              job_id: job.id,
              prior_status: job.status,
              status: job.status,
              result: {:error, reason},
              job: job
            }

          other ->
            %{
              job_id: job.id,
              prior_status: job.status,
              status: job.status,
              result: {:error, {:invalid_result, other}},
              job: job
            }
        end

      {outcome.job, Map.delete(outcome, :job)}
    end
  rescue
    error ->
      {job,
       %{
         job_id: job.id,
         prior_status: job.status,
         status: job.status,
         result: {:error, Exception.message(error)}
       }}
  catch
    kind, reason ->
      {job,
       %{
         job_id: job.id,
         prior_status: job.status,
         status: job.status,
         result: {:error, {kind, reason}}
       }}
  end

  defp bounded_job_cancel(_job, 0), do: {:error, {:training_cancel_timeout, 0}}

  defp bounded_job_cancel(%TrainingJob{} = job, timeout) do
    task =
      Task.Supervisor.async_nolink(Imp.UnlinkedTaskSupervisor, fn ->
        TrainingJob.cancel(job)
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:training_cancel_task_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:training_cancel_timeout, timeout}}
    end
  rescue
    error -> {:error, {:training_cancel_task_failed, Exception.message(error)}}
  end

  defp with_generic_cancellation({:training_step_timeout, optimizer, timeout, summary}, nil),
    do: {:training_step_timeout, optimizer, timeout, [summary], []}

  defp with_generic_cancellation(
         {:training_step_timeout, optimizer, timeout, summary},
         cancellation
       ),
       do: {:training_step_timeout, optimizer, timeout, [summary], [cancellation]}

  defp with_generic_cancellation(reason, nil), do: reason

  defp with_generic_cancellation(
         {:training_step_refresh_failed, optimizer, errors},
         cancellation
       ),
       do: {:training_step_refresh_failed, optimizer, errors, [cancellation]}

  defp with_generic_cancellation(reason, cancellation),
    do: {:training_terminal_error, reason, [cancellation]}

  defp training_job_summary(%TrainingJob{} = job),
    do: %{job_id: job.id, status: job.status, metadata: job.metadata}

  defp resolve_bootstrap_step(request, optimizer, program, plan) do
    case BootstrapFinetune.__resolve_training_plan__(optimizer, program, plan) do
      {:ok, %Imp.Optimizer.TrainingResult{status: :completed} = result} ->
        completed_training_step(result, false)

      {:ok, %Imp.Optimizer.TrainingResult{status: :job_created}} ->
        await_bootstrap_step(request, optimizer, program, plan)

      {:error, %TrainingError{} = failure} ->
        terminal_training_error(request, failure)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp completed_training_step(result, awaited?) do
    {:ok, result.program,
     %{
       optimizer: BootstrapFinetune,
       kind: :training,
       training_status: result.status,
       awaited: awaited?
     }}
  end

  defp await_bootstrap_step(request, optimizer, program, plan) do
    deadline = monotonic_ms() + request.training_timeout

    do_await_bootstrap_step(
      request,
      optimizer,
      program,
      plan,
      deadline
    )
  end

  defp do_await_bootstrap_step(request, optimizer, program, plan, deadline) do
    if monotonic_ms() >= deadline do
      resolve_at_deadline(request, optimizer, program, plan, [])
    else
      case refresh_training_plan(plan, deadline) do
        {:ok, refreshed} ->
          case BootstrapFinetune.__resolve_training_plan__(optimizer, program, refreshed) do
            {:ok, %Imp.Optimizer.TrainingResult{status: :completed} = result} ->
              completed_training_step(result, true)

            {:ok, %Imp.Optimizer.TrainingResult{status: :job_created}} ->
              sleep_until_next_poll(request.training_poll_interval, deadline)
              do_await_bootstrap_step(request, optimizer, program, refreshed, deadline)

            {:error, %TrainingError{} = failure} ->
              terminal_training_error(request, failure)

            {:error, reason} ->
              {:error, reason}
          end

        {:timeout, timed_out_plan, refresh_errors} ->
          resolve_at_deadline(
            request,
            optimizer,
            program,
            timed_out_plan,
            refresh_errors
          )

        {:error, reason, failed_plan} ->
          resolve_refresh_failure(request, optimizer, program, failed_plan, reason)
      end
    end
  end

  defp refresh_training_plan(%TrainingPlan{} = plan, deadline) do
    plan.entries
    |> Enum.with_index()
    |> Enum.reduce_while({[], []}, fn {entry, index}, {entries, errors} ->
      case refresh_training_entry(entry, deadline) do
        {:ok, refreshed} ->
          {:cont, {entries ++ [refreshed], errors}}

        {:error, reason} ->
          error = %{
            predictor_names: entry.predictor_names,
            job_id: entry.job && entry.job.id,
            reason: reason
          }

          {:cont, {entries ++ [entry], errors ++ [error]}}

        :timeout ->
          remaining = Enum.drop(plan.entries, index + 1)
          {:halt, {:timeout, entries ++ [entry] ++ remaining, errors}}
      end
    end)
    |> case do
      {:timeout, entries, errors} ->
        {:timeout, %{plan | entries: entries}, errors}

      {entries, []} ->
        {:ok, %{plan | entries: entries}}

      {entries, errors} ->
        {:error, {:training_step_refresh_failed, BootstrapFinetune, errors},
         %{plan | entries: entries}}
    end
  end

  defp refresh_training_entry(%{job: %TrainingJob{} = job} = entry, deadline) do
    if TrainingJob.active_status?(job.status) do
      remaining = max(deadline - monotonic_ms(), 0)

      case bounded_job_refresh(job, remaining) do
        {:ok, refreshed} -> {:ok, %{entry | job: refreshed}}
        {:error, reason} -> {:error, reason}
        :timeout -> :timeout
      end
    else
      {:ok, entry}
    end
  end

  defp refresh_training_entry(_entry, _deadline), do: {:error, :training_job_missing}

  defp bounded_job_refresh(_job, 0), do: :timeout

  defp bounded_job_refresh(%TrainingJob{status_url: nil} = job, _timeout),
    do: TrainingJob.refresh(job)

  defp bounded_job_refresh(%TrainingJob{} = job, timeout) do
    task =
      Task.Supervisor.async_nolink(Imp.UnlinkedTaskSupervisor, fn ->
        TrainingJob.refresh(job)
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:training_refresh_task_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  rescue
    error -> {:error, {:training_refresh_task_failed, Exception.message(error)}}
  end

  defp training_timeout(request, plan) do
    {cancelled_plan, cancellations} =
      BootstrapFinetune.__cancel_training_plan__(plan, :pending,
        deadline: cancellation_deadline(request)
      )

    {:error,
     {:training_step_timeout, BootstrapFinetune, request.training_timeout,
      training_plan_summary(cancelled_plan), cancellations}}
  end

  defp resolve_at_deadline(request, optimizer, program, plan, refresh_errors) do
    case BootstrapFinetune.__resolve_training_plan__(optimizer, program, plan) do
      {:ok, %Imp.Optimizer.TrainingResult{status: :completed} = result} ->
        completed_training_step(result, true)

      {:error, %TrainingError{} = failure} ->
        terminal_training_error(request, failure)

      {:error, reason} ->
        {:error, reason}

      {:ok, %Imp.Optimizer.TrainingResult{status: :job_created}} when refresh_errors != [] ->
        cancel_pending_training(
          request,
          plan,
          {:training_step_refresh_failed, BootstrapFinetune, refresh_errors}
        )

      {:ok, %Imp.Optimizer.TrainingResult{status: :job_created}} ->
        training_timeout(request, plan)
    end
  end

  defp resolve_refresh_failure(request, optimizer, program, plan, refresh_reason) do
    case BootstrapFinetune.__resolve_training_plan__(optimizer, program, plan) do
      {:ok, %Imp.Optimizer.TrainingResult{status: :completed} = result} ->
        completed_training_step(result, true)

      {:ok, %Imp.Optimizer.TrainingResult{status: :job_created}} ->
        cancel_pending_training(request, plan, refresh_reason)

      {:error, %TrainingError{} = failure} ->
        terminal_training_error(request, failure)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_pending_training(request, plan, reason) do
    {_cancelled_plan, cancellations} =
      BootstrapFinetune.__cancel_training_plan__(plan, :pending,
        deadline: cancellation_deadline(request)
      )

    {:error, with_cancellation_outcomes(reason, cancellations)}
  end

  defp terminal_training_error(request, %TrainingError{} = failure) do
    failure =
      BootstrapFinetune.__cancel_training_error__(failure, :pending,
        deadline: cancellation_deadline(request)
      )

    diagnostics =
      bootstrap_diagnostics(failure.program, %{
        status: failure.status,
        reason: failure.reason,
        metadata: failure.metadata
      })

    {:error, failure.reason, diagnostics}
  end

  defp bootstrap_diagnostics(program, failure) do
    report =
      case Report.fetch(program) do
        %Report{} = report -> Report.dump(report)
        _missing -> nil
      end

    %{
      "optimizer" => "bootstrap_finetune",
      "failure" => Report.json_safe(failure),
      "report" => report
    }
    |> Imp.Redaction.redact()
  end

  defp cancellation_deadline(request),
    do: monotonic_ms() + request.training_cancellation_timeout

  defp with_cancellation_outcomes({:training_failed, status, metadata}, cancellations),
    do: {:training_failed, status, metadata, cancellations}

  defp with_cancellation_outcomes(
         {:training_plan_failed, failures, jobs},
         cancellations
       ),
       do: {:training_plan_failed, failures, jobs, cancellations}

  defp with_cancellation_outcomes(
         {:training_step_refresh_failed, optimizer, errors},
         cancellations
       ),
       do: {:training_step_refresh_failed, optimizer, errors, cancellations}

  defp with_cancellation_outcomes(reason, cancellations),
    do: {:training_terminal_error, reason, cancellations}

  defp sleep_until_next_poll(interval, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)
    Process.sleep(min(max(interval, 1), remaining))
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp training_plan_summary(plan) do
    Enum.map(plan.entries, fn entry ->
      %{
        predictor_names: entry.predictor_names,
        job_id: entry.job && entry.job.id,
        status: entry.job && entry.job.status
      }
    end)
  end

  defp bootstrap_start_error(compiled, plan, reason) do
    diagnostics = bootstrap_diagnostics(compiled, %{status: :start_failed, reason: reason})

    if Enum.any?(plan.entries, &match?(%TrainingJob{}, &1.job)) do
      {:error, {:training_plan_start_failed, reason, training_plan_summary(plan)}, diagnostics}
    else
      {:error, {:training_not_started, reason}, diagnostics}
    end
  end

  defp reject_compile_options(request, optimizer_module) do
    options = Imp.Optimizer.invocation_options(request.invocation_opts)

    if options == [],
      do: :ok,
      else:
        {:error, {:unsupported_optimizer_compile_args, optimizer_module, Keyword.keys(options)}}
  end

  defp single_teacher(nil), do: {:ok, nil}
  defp single_teacher([teacher]), do: {:ok, teacher}
  defp single_teacher([_first | _rest]), do: {:error, :multiple_teachers_not_supported}
  defp single_teacher(teacher), do: {:ok, teacher}

  defp teacher_presence(nil), do: :student
  defp teacher_presence(_teacher), do: :provided

  defp maybe_put_teacher(opts, nil), do: opts
  defp maybe_put_teacher(opts, teacher), do: Keyword.put(opts, :teacher, teacher)

  defp allowed_step_kind(kind) when kind in [:program, :training], do: :ok

  defp allowed_step_kind(kind),
    do: {:error, {:optimizer_kind_mismatch, [:program, :training], kind}}

  defp step_opts_for_capabilities(capabilities, trainset, valset, step_opts) do
    [trainset: trainset]
    |> maybe_put_validation(capabilities.datasets, valset)
    |> Keyword.merge(step_opts)
  end

  defp maybe_put_validation(opts, _datasets, nil), do: opts

  defp maybe_put_validation(opts, datasets, valset) do
    if Map.get(datasets, :validation) == :unsupported,
      do: opts,
      else: Keyword.put(opts, :validation, valset)
  end

  defp compile_args_for(compile_args, key) do
    Map.get(compile_args, key, Map.get(compile_args, existing_atom_or_string(key), []))
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

  defp weight_provider_boundary(optimizers) do
    if Enum.any?(optimizers, fn
         {_key, %BootstrapFinetune{trainer: nil}} -> true
         _entry -> false
       end),
       do: :explicit_trainer_required,
       else: :configured_or_not_required
  end

  defp ensure_report_storage(program) do
    probe = Report.new(%{optimizer: :better_together_storage_probe})

    if report_storage?(program, probe) do
      :ok
    else
      report_storage_error!(program)
    end
  end

  defp attach_report!(program, report) do
    attached = Report.attach(program, report)

    if Report.fetch(attached) == report do
      attached
    else
      report_storage_error!(program)
    end
  end

  defp report_storage?(program, report),
    do: program |> Report.attach(report) |> Report.fetch() == report

  defp report_storage_error!(program) do
    module = if is_struct(program), do: program.__struct__, else: program

    raise ArgumentError,
          "Imp.Optimizer.BetterTogether.compile/5 cannot store optimizer reports on #{inspect(module)}; custom programs must expose a map-valued :metadata field or use a supported Imp program wrapper"
  end

  defp normalize_optimizers!(optimizers) do
    Map.new(optimizers)
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      reraise ArgumentError,
              "Imp.Optimizer.BetterTogether.new/2 expects optimizers to be an enumerable of key/value pairs; got: #{inspect(optimizers)} (#{Exception.message(error)})",
              __STACKTRACE__
  end
end
