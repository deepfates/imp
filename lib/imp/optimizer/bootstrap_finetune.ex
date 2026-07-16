defmodule Imp.Optimizer.BootstrapFinetune.TrainingPlan do
  @moduledoc false

  alias Imp.Clients.TrainingJob

  @type key :: {term(), non_neg_integer() | nil}

  @type row :: %{
          required(:id) => {non_neg_integer(), non_neg_integer(), non_neg_integer()},
          required(:predictor_index) => non_neg_integer(),
          required(:predictor_name) => Imp.ProgramParameters.name(),
          required(:source_predictor) => struct(),
          required(:example) => Imp.Example.t()
        }

  @type entry :: %{
          required(:key) => key(),
          required(:lm) => term(),
          required(:predictor_indices) => [non_neg_integer()],
          required(:predictor_names) => [Imp.ProgramParameters.name()],
          required(:rows) => [row()],
          required(:adapter) => module() | nil,
          required(:train_kwargs) => keyword(),
          required(:job) => TrainingJob.t() | nil
        }

  @enforce_keys [:multitask, :entries]
  defstruct [
    :multitask,
    :entries,
    max_concurrency: 1,
    teacher_count: 0,
    trace_count: 0,
    selected_trace_count: 0
  ]

  @type t :: %__MODULE__{
          multitask: boolean(),
          entries: [entry()],
          max_concurrency: pos_integer(),
          teacher_count: non_neg_integer(),
          trace_count: non_neg_integer(),
          selected_trace_count: non_neg_integer()
        }
end

defmodule Imp.Optimizer.BootstrapFinetune do
  @behaviour Imp.Optimizer
  @moduledoc """
  Builds SFT jobs from successful, predictor-attributed teacher traces.

  With `multitask: true`, predictors sharing an LM share one job and every
  unique-LM job receives all accepted module calls. With `multitask: false`,
  each predictor receives an independent job containing only its calls. Jobs
  are rebound only when every entry has a succeeded provider artifact.

  DSPy 3.2.1 accidentally shadows its `pred_ind` filter and feeds every call
  to every predictor-specific job. Imp intentionally corrects that bug by
  attributing trace calls to stable `Imp.ProgramParameters` predictor names.
  `:max_concurrency` is the BEAM-native `num_threads` boundary: it controls
  teacher trace workers and must also cover the number of provider jobs.
  """

  alias Imp.Clients.{TrainingJob, Trainer}
  alias Imp.Optimizer.{Report, Sampling, TrainingError, TrainingResult, TrajectoryRunner}
  alias Imp.Optimizer.BootstrapFinetune.TrainingPlan

  @source_field :imp_bootstrap_source

  defstruct [
    :metric,
    :trainer,
    :teacher,
    :adapter,
    max_demos: :infinity,
    max_concurrency: 8,
    multitask: true,
    exclude_demos: false,
    train_kwargs: []
  ]

  @option_schema [
    trainer: [type: {:custom, Trainer, :validate_provider, []}, default: nil],
    teacher: [type: {:custom, __MODULE__, :validate_teacher, []}, default: nil],
    adapter: [type: {:custom, __MODULE__, :validate_adapter_config, []}, default: nil],
    max_demos: [type: {:custom, __MODULE__, :validate_demo_limit, []}, default: :infinity],
    max_concurrency: [type: :pos_integer, default: 8],
    multitask: [type: :boolean, default: true],
    exclude_demos: [type: :boolean, default: false],
    train_kwargs: [type: {:custom, __MODULE__, :validate_train_kwargs, []}, default: []]
  ]

  def new(metric, opts \\ []) do
    unless is_nil(metric) do
      Imp.FunctionContract.validate!(
        metric,
        [2, 3],
        "Imp.Optimizer.BootstrapFinetune.new/2",
        "metric"
      )
    end

    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.BootstrapFinetune.new/2")

    struct!(__MODULE__, Keyword.put(opts, :metric, metric))
  end

  @doc false
  def validate_demo_limit(:infinity), do: {:ok, :infinity}
  def validate_demo_limit(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def validate_demo_limit(_value), do: {:error, "expected non negative integer"}

  @doc false
  def validate_train_kwargs(value) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, value},
      else: {:error, "expected a keyword list or an LM-keyed map of keyword lists"}
  end

  def validate_train_kwargs(value) when map_size(value) == 0, do: {:ok, []}

  def validate_train_kwargs(value) when is_map(value) do
    if Enum.all?(value, fn {_lm, opts} -> is_list(opts) and Keyword.keyword?(opts) end),
      do: {:ok, value},
      else: {:error, "expected a keyword list or an LM-keyed map of keyword lists"}
  end

  def validate_train_kwargs(_value),
    do: {:error, "expected a keyword list or an LM-keyed map of keyword lists"}

  @doc false
  def validate_adapter_config(value) when is_atom(value) or is_nil(value),
    do: Imp.Adapter.validate_adapter(value)

  def validate_adapter_config(value) when map_size(value) == 0, do: {:ok, nil}

  def validate_adapter_config(value) when is_map(value) do
    if Enum.all?(value, fn {_lm, adapter} ->
         match?({:ok, _adapter}, Imp.Adapter.validate_adapter(adapter))
       end),
       do: {:ok, value},
       else: {:error, "expected an adapter module or an LM-keyed map of adapter modules"}
  end

  def validate_adapter_config(_value),
    do: {:error, "expected an adapter module or an LM-keyed map of adapter modules"}

  def validate_teacher(nil), do: {:ok, nil}

  def validate_teacher([_ | _] = teachers) do
    if Enum.all?(teachers, &executable_program?/1),
      do: {:ok, teachers},
      else: {:error, "expected nil, an executable teacher program, or a non-empty list of them"}
  end

  def validate_teacher(teacher) do
    if executable_program?(teacher),
      do: {:ok, teacher},
      else: {:error, "expected nil, an executable teacher program, or a non-empty list of them"}
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :training,
      datasets: %{trainset: :required, validation: :unsupported},
      result: :training_result
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      case compile(optimizer, program, Imp.Optimizer.fetch_dataset!(opts, :trainset)) do
        %{program: compiled, plan: %TrainingPlan{} = plan, error: reason} ->
          if Enum.any?(plan.entries, &match?(%TrainingJob{}, &1.job)) do
            {:error,
             {:training_plan_start_failed, reason, Enum.map(plan.entries, &job_summary/1),
              compiled}}
          else
            {:error, {:training_not_started, reason, compiled}}
          end

        %{program: compiled, error: reason} ->
          {:error, {:training_not_started, reason, compiled}}

        %{program: compiled, plan: %TrainingPlan{} = plan} ->
          case __resolve_training_plan__(optimizer, compiled, plan) do
            {:error, %TrainingError{} = failure} ->
              {:error, __cancel_training_error__(failure, :pending)}

            result ->
              result
          end
      end
    end
  end

  @doc false
  def __resolve_training_plan__(
        %__MODULE__{} = optimizer,
        program,
        %TrainingPlan{} = plan
      ) do
    training_result(optimizer, program, plan)
  end

  @doc false
  def __cancel_training_plan__(plan, scope, opts \\ [])

  def __cancel_training_plan__(%TrainingPlan{} = plan, scope, opts)
      when scope in [:all_started, :pending] and is_list(opts) do
    deadline = Keyword.get(opts, :deadline, :infinity)

    if deadline == :infinity do
      cancel_training_plan_sync(plan, scope)
    else
      cancel_training_plan_bounded(plan, scope, deadline)
    end
  end

  @doc false
  def __cancel_training_error__(failure, scope, opts \\ [])

  def __cancel_training_error__(
        %TrainingError{job: %TrainingPlan{} = plan} = failure,
        scope,
        opts
      )
      when scope in [:all_started, :pending] and is_list(opts) do
    {cancelled_plan, outcomes} = __cancel_training_plan__(plan, scope, opts)
    reason = with_cancellation_outcomes(failure.reason, outcomes)

    program =
      attach_terminal_failure_report(failure.program, reason, cancelled_plan, outcomes)

    %{
      failure
      | reason: reason,
        program: program,
        job: cancelled_plan,
        metadata: terminal_failure_metadata(cancelled_plan, outcomes)
    }
  end

  defp cancel_training_plan_sync(%TrainingPlan{} = plan, scope) do
    {entries, outcomes} =
      Enum.map_reduce(plan.entries, [], fn entry, outcomes ->
        if cancellation_candidate?(entry, scope) do
          {entry, outcome} = cancel_training_entry(entry)
          {entry, [outcome | outcomes]}
        else
          {entry, outcomes}
        end
      end)

    {%{plan | entries: entries}, Enum.reverse(outcomes)}
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    with {:ok, trainset} <- materialize_trainset(trainset),
         {:ok, predictors} <- validate_student(program, optimizer.trainer),
         {:ok, teachers} <- prepare_teachers(program, optimizer.teacher),
         {:ok, trace_data} <-
           collect_trace_data(
             teachers,
             trainset,
             trajectory_metric(optimizer.metric),
             optimizer.max_concurrency
           ),
         {selected, candidates} <- select_trace_data(trace_data, optimizer.max_demos),
         {:ok, rows} <- trace_rows(selected, teachers, predictors, optimizer.exclude_demos),
         plan <- build_plan(optimizer, predictors, rows, teachers, trace_data, selected),
         {:ok, plan} <- configure_plan(plan, optimizer),
         :ok <- validate_job_concurrency(plan, optimizer.max_concurrency),
         prepared <- attach_report(program, optimizer, trainset, teachers, plan, candidates) do
      start_training(optimizer, prepared, plan)
    else
      {:error, reason} -> %{program: program, error: reason}
    end
  rescue
    error ->
      %{program: program, error: {:bootstrap_finetune_prepare_failed, Exception.message(error)}}
  catch
    kind, reason ->
      %{program: program, error: {:bootstrap_finetune_prepare_failed, {kind, reason}}}
  end

  defp materialize_trainset(trainset) do
    {:ok, Enum.to_list(trainset)}
  rescue
    error -> {:error, {:bootstrap_finetune_invalid_trainset, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:bootstrap_finetune_invalid_trainset, {kind, reason}}}
  end

  defp validate_student(program, trainer) do
    case Imp.ProgramParameters.predictors(program) do
      [] ->
        {:error, :bootstrap_finetune_predictor_required}

      predictors ->
        validate_student_lms(predictors, trainer)
    end
  rescue
    error -> {:error, {:bootstrap_finetune_predictor_inspection_failed, Exception.message(error)}}
  end

  # Preserve Imp's explicit-backend error precedence when no provider could
  # consume a plan. Any configured provider still gets DSPy's strict LM check.
  defp validate_student_lms(predictors, nil), do: {:ok, predictors}

  defp validate_student_lms(predictors, _trainer) do
    case Enum.find_index(predictors, &is_nil(&1.predictor.lm)) do
      nil -> {:ok, predictors}
      index -> {:error, {:bootstrap_finetune_student_lm_required, index}}
    end
  end

  defp prepare_teachers(student, nil), do: {:ok, [student]}

  defp prepare_teachers(student, configured) do
    teachers = List.wrap(configured)

    Enum.reduce_while(teachers, {:ok, []}, fn teacher, {:ok, prepared} ->
      with :ok <- structurally_equivalent(student, teacher),
           :ok <- reject_shared_teacher_values(student, teacher) do
        {:cont, {:ok, prepared ++ [teacher]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # BEAM values have no object identity. Exact predictor-value equality is the
  # conservative representable analogue to DSPy's explicit shared-object guard.
  defp reject_shared_teacher_values(student, teacher) do
    student_predictors = Enum.map(Imp.ProgramParameters.predictors(student), & &1.predictor)
    teacher_predictors = Enum.map(Imp.ProgramParameters.predictors(teacher), & &1.predictor)

    if Enum.any?(student_predictors, fn student_predictor ->
         Enum.any?(teacher_predictors, &(&1 === student_predictor))
       end),
       do: {:error, :bootstrap_finetune_teacher_shares_student_predictors},
       else: :ok
  end

  defp structurally_equivalent(student, teacher) do
    if predictor_shape(student) == predictor_shape(teacher),
      do: :ok,
      else: {:error, :bootstrap_finetune_teacher_structure_mismatch}
  rescue
    error ->
      {:error,
       {:bootstrap_finetune_teacher_structure_inspection_failed, Exception.message(error)}}
  end

  defp predictor_shape(program) do
    Enum.map(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      {name, predictor.__struct__}
    end)
  end

  defp collect_trace_data(teachers, trainset, metric, max_concurrency) do
    trace_data =
      teachers
      |> Enum.with_index()
      |> Enum.flat_map(fn {teacher, teacher_index} ->
        teacher
        |> TrajectoryRunner.run(trainset, metric,
          runtime: :evaluation,
          max_concurrency: max_concurrency
        )
        |> Enum.map(&%{teacher_index: teacher_index, trajectory: &1})
      end)

    {:ok, trace_data}
  rescue
    error -> {:error, {:bootstrap_finetune_trace_collection_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:bootstrap_finetune_trace_collection_failed, {kind, reason}}}
  end

  defp select_trace_data(trace_data, limit) do
    {selected, candidates, _count} =
      trace_data
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {%{trajectory: trajectory} = item, index},
                                     {selected, candidates, count} ->
        passed? = is_nil(trajectory.error) and trajectory.score != 0
        selected? = passed? and below_limit?(count, limit)

        candidate = %{
          index: index,
          teacher_index: item.teacher_index,
          score: trajectory.score,
          passed?: passed?,
          selected?: selected?,
          feedback: trajectory.feedback,
          error: trajectory.error
        }

        if selected?,
          do: {selected ++ [item], candidates ++ [candidate], count + 1},
          else: {selected, candidates ++ [candidate], count}
      end)

    {selected, candidates}
  end

  defp below_limit?(_count, :infinity), do: true
  defp below_limit?(count, limit), do: count < limit

  defp trace_rows(selected, teachers, student_predictors, exclude_demos?) do
    student_indices =
      student_predictors
      |> Enum.with_index()
      |> Map.new(fn {%{name: name}, index} -> {name, index} end)

    selected
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, rows} ->
      teacher_predictors =
        teachers
        |> Enum.at(item.teacher_index)
        |> Imp.ProgramParameters.predictors()
        |> Map.new(&{&1.name, &1.predictor})

      item.trajectory.trace
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, rows}, fn {step, trace_index}, {:ok, rows} ->
        name = fetch(step, :predictor)

        with {:ok, predictor_index} <- Map.fetch(student_indices, name),
             {:ok, source_predictor} <- Map.fetch(teacher_predictors, name),
             {:ok, example} <- training_example(step, source_predictor, exclude_demos?) do
          row = %{
            id: {item.teacher_index, item.trajectory.index, trace_index},
            predictor_index: predictor_index,
            predictor_name: name,
            source_predictor: source_predictor,
            example: example
          }

          {:cont, {:ok, rows ++ [row]}}
        else
          :error ->
            {:halt,
             {:error, {:bootstrap_finetune_trace_predictor_unknown, item.teacher_index, name}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, rows} -> {:cont, {:ok, rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp training_example(step, source_predictor, exclude_demos?) do
    inputs = Map.new(fetch(step, :inputs, %{}))
    outputs = Map.new(fetch(step, :outputs, %{}))
    demos = if exclude_demos?, do: [], else: source_predictor.demos

    example =
      inputs
      |> Map.merge(outputs)
      |> Imp.Example.new()
      |> Imp.Example.with_inputs(Map.keys(inputs))
      |> Imp.Example.with_demos(demos)

    {:ok, example}
  rescue
    error -> {:error, {:bootstrap_finetune_invalid_trace_row, Exception.message(error)}}
  end

  defp build_plan(optimizer, predictors, rows, teachers, trace_data, selected) do
    {entries, _positions} =
      predictors
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {%{name: name, predictor: predictor}, predictor_index},
                                   {entries, positions} ->
        data_index = if optimizer.multitask, do: nil, else: predictor_index
        key = {predictor.lm, data_index}

        case Map.fetch(positions, key) do
          {:ok, entry_index} ->
            entries =
              List.update_at(entries, entry_index, fn entry ->
                %{
                  entry
                  | predictor_indices: entry.predictor_indices ++ [predictor_index],
                    predictor_names: entry.predictor_names ++ [name]
                }
              end)

            {entries, positions}

          :error ->
            entry = %{
              key: key,
              lm: predictor.lm,
              predictor_indices: [predictor_index],
              predictor_names: [name],
              rows: [],
              adapter: nil,
              train_kwargs: [],
              job: nil
            }

            {entries ++ [entry], Map.put(positions, key, length(entries))}
        end
      end)

    entries =
      Enum.map(entries, fn entry ->
        entry_rows =
          if optimizer.multitask,
            do: rows,
            else: Enum.filter(rows, &(&1.predictor_index in entry.predictor_indices))

        {entry_rows, _rng} = Sampling.shuffle(entry_rows, Sampling.new(0))
        %{entry | rows: entry_rows}
      end)

    %TrainingPlan{
      multitask: optimizer.multitask,
      entries: entries,
      max_concurrency: optimizer.max_concurrency,
      teacher_count: length(teachers),
      trace_count: length(trace_data),
      selected_trace_count: length(selected)
    }
  end

  defp configure_plan(%TrainingPlan{} = plan, optimizer) do
    plan.entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, entries} ->
      with {:ok, adapter} <- adapter_for_lm(optimizer.adapter, entry),
           {:ok, train_kwargs} <- train_kwargs_for_lm(optimizer.train_kwargs, entry) do
        {:cont, {:ok, entries ++ [%{entry | adapter: adapter, train_kwargs: train_kwargs}]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, %{plan | entries: entries}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter_for_lm(nil, _entry), do: {:ok, nil}
  defp adapter_for_lm(adapter, _entry) when is_atom(adapter), do: {:ok, adapter}

  defp adapter_for_lm(adapters, entry) when is_map(adapters) do
    case Map.fetch(adapters, entry.lm) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:bootstrap_finetune_lm_adapter_missing, public_key(entry.key)}}
    end
  end

  defp train_kwargs_for_lm(train_kwargs, _entry) when is_list(train_kwargs),
    do: {:ok, train_kwargs}

  defp train_kwargs_for_lm(train_kwargs, entry) when is_map(train_kwargs) do
    case Map.fetch(train_kwargs, entry.lm) do
      {:ok, opts} -> {:ok, opts}
      :error -> {:error, {:bootstrap_finetune_lm_train_kwargs_missing, public_key(entry.key)}}
    end
  end

  defp validate_job_concurrency(plan, max_concurrency) do
    job_count = length(plan.entries)

    if job_count <= max_concurrency,
      do: :ok,
      else: {:error, {:bootstrap_finetune_job_concurrency_exceeded, job_count, max_concurrency}}
  end

  defp attach_report(program, optimizer, trainset, teachers, plan, candidates) do
    errors =
      candidates
      |> Enum.reject(&is_nil(&1.error))
      |> Enum.map(fn candidate ->
        %{
          index: candidate.index,
          teacher_index: candidate.teacher_index,
          stage: trace_error_stage(candidate.error),
          reason: inspect(candidate.error)
        }
      end)

    report =
      Report.new(%{
        optimizer: :bootstrap_finetune,
        best_score: average_score(candidates),
        candidate_count: length(candidates),
        candidates: candidates,
        errors: errors,
        metadata: %{
          selected_count: plan.selected_trace_count,
          max_bootstrapped_demos: optimizer.max_demos,
          trainset_size: length(trainset),
          teacher_count: length(teachers),
          training_job_count: length(plan.entries),
          max_concurrency: optimizer.max_concurrency,
          multitask: optimizer.multitask,
          predictor_data_filter: :named_predictor_correctness_deviation,
          status: :ok
        }
      })

    Report.attach(program, report)
  end

  defp attach_terminal_failure_report(program, reason, plan, outcomes) do
    case Report.fetch(program) do
      %Report{} = report ->
        jobs = Enum.map(plan.entries, &job_summary/1)

        errors =
          report.errors
          |> Enum.reject(fn
            %{stage: stage} when stage in [:training_terminal, :training_cancellation] -> true
            _error -> false
          end)
          |> Kernel.++([%{stage: :training_terminal, reason: reason, jobs: jobs}])
          |> maybe_append_cancellation_error(outcomes)

        metadata =
          report.metadata
          |> Map.put(:status, :error)
          |> Map.put(:terminal_reason, reason)
          |> Map.put(:training_jobs, jobs)
          |> maybe_put_cancellations(outcomes)

        Report.attach(program, %{report | errors: errors, metadata: metadata})

      _missing ->
        program
    end
  end

  defp maybe_append_cancellation_error(errors, []), do: errors

  defp maybe_append_cancellation_error(errors, outcomes),
    do: errors ++ [%{stage: :training_cancellation, outcomes: outcomes}]

  defp maybe_put_cancellations(metadata, []), do: Map.delete(metadata, :cancellations)

  defp maybe_put_cancellations(metadata, outcomes),
    do: Map.put(metadata, :cancellations, outcomes)

  defp terminal_failure_metadata(plan, outcomes) do
    %{
      status: :failed,
      jobs: Enum.map(plan.entries, &job_summary/1),
      cancellations: outcomes
    }
  end

  defp start_training(%__MODULE__{trainer: nil}, program, plan),
    do: %{program: program, plan: plan, error: :trainer_required}

  defp start_training(%__MODULE__{} = optimizer, program, plan) do
    plan.entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, started} ->
      examples = training_examples(optimizer.trainer, entry)

      with {:ok, opts} <- trainer_opts(optimizer, entry),
           {:ok, job} <- Trainer.finetune(optimizer.trainer, entry.lm, examples, opts) do
        {:cont, {:ok, started ++ [%{entry | job: job}]}}
      else
        {:error, reason} ->
          failed_plan = %{
            plan
            | entries: started ++ [entry] ++ Enum.drop(plan.entries, index + 1)
          }

          {:halt, {:error, public_key(entry.key), reason, failed_plan}}
      end
    end)
    |> case do
      {:ok, entries} ->
        training_started(program, %{plan | entries: entries})

      {:error, key, reason, failed_plan} ->
        {cancelled_plan, outcomes} = __cancel_training_plan__(failed_plan, :all_started)

        terminal_reason =
          {:bootstrap_finetune_training_start_failed, key, reason, outcomes}

        program =
          attach_terminal_failure_report(program, terminal_reason, cancelled_plan, outcomes)

        %{
          program: program,
          plan: cancelled_plan,
          cancellation_outcomes: outcomes,
          error: terminal_reason
        }
    end
  end

  defp training_started(program, %TrainingPlan{} = plan) do
    jobs = Enum.map(plan.entries, & &1.job)
    aggregate = if length(jobs) == 1, do: hd(jobs), else: plan
    %{program: program, plan: plan, jobs: jobs, job: aggregate}
  end

  defp training_examples(%Imp.Clients.HTTPTrainer{provider: :openai}, entry) do
    Enum.map(entry.rows, fn row ->
      Imp.Example.put(row.example, @source_field, source_token(row.id))
    end)
  end

  defp training_examples(_trainer, entry), do: Enum.map(entry.rows, & &1.example)

  defp trainer_opts(%__MODULE__{} = optimizer, entry) do
    opts =
      entry.train_kwargs
      |> maybe_put_adapter(entry.adapter)
      |> Keyword.put(:method, :sft)

    case optimizer.trainer do
      %Imp.Clients.HTTPTrainer{provider: :openai} ->
        opts = Keyword.delete(opts, :adapter)

        {:ok,
         Keyword.put_new(
           opts,
           :example_encoder,
           openai_example_encoder(entry.rows, entry.adapter)
         )}

      %Imp.Clients.HTTPTrainer{} ->
        {:ok, Keyword.delete(opts, :adapter)}

      _trainer ->
        {:ok, opts}
    end
  end

  defp maybe_put_adapter(opts, nil), do: opts
  defp maybe_put_adapter(opts, adapter), do: Keyword.put(opts, :adapter, adapter)

  defp openai_example_encoder(rows, configured_adapter) do
    sources = Map.new(rows, &{source_token(&1.id), &1})

    fn example ->
      with token when is_binary(token) <- Imp.Example.get(example, @source_field),
           {:ok, row} <- Map.fetch(sources, token) do
        example = Imp.Example.delete(example, @source_field)
        predictor = row.source_predictor
        adapter = configured_adapter || resolve_adapter(predictor)
        render_openai_row(adapter, predictor.signature, example, example.demos)
      else
        _other -> {:error, :openai_training_source_unavailable}
      end
    end
  end

  defp render_openai_row(adapter, signature, example, demos) do
    messages =
      adapter.format(signature, %{},
        demos: demos ++ [example],
        response_instruction: false
      )

    {systems, turns} = Enum.split_while(messages, &(message_role(&1) == :system))
    turns = drop_empty_input_sentinel(turns)

    if systems != [] and valid_chat_turns?(turns) do
      {:ok, %{messages: systems ++ turns}}
    else
      {:error, :openai_chat_messages_unavailable}
    end
  rescue
    error -> {:error, {:openai_chat_render_failed, Exception.message(error)}}
  end

  defp valid_chat_turns?(turns) when turns != [] and rem(length(turns), 2) == 0 do
    turns
    |> Enum.chunk_every(2)
    |> Enum.all?(fn [user, assistant] ->
      message_role(user) == :user and message_role(assistant) == :assistant
    end)
  end

  defp valid_chat_turns?(_turns), do: false

  defp drop_empty_input_sentinel(turns) do
    case List.last(turns) do
      nil ->
        turns

      message ->
        if message_role(message) == :user and message_content(message) == "",
          do: Enum.drop(turns, -1),
          else: turns
    end
  end

  defp training_result(optimizer, program, %TrainingPlan{} = plan) do
    failures =
      Enum.reject(plan.entries, fn entry ->
        status = job_status(entry)
        status == :succeeded or TrainingJob.active_status?(status)
      end)

    cond do
      failures != [] ->
        terminal_training_failure(program, plan, failures)

      Enum.all?(plan.entries, &(job_status(&1) == :succeeded)) ->
        completed_training_result(optimizer, program, plan)

      true ->
        {:ok,
         %TrainingResult{
           program: program,
           job: aggregate_job(plan),
           status: :job_created,
           metadata: training_metadata(plan)
         }}
    end
  end

  defp training_failure(%TrainingPlan{entries: [entry]}, [entry]) do
    job = entry.job
    {:error, {:training_failed, job.status, job.metadata}}
  end

  defp training_failure(plan, failures) do
    {:error,
     {:training_plan_failed, Enum.map(failures, &job_summary/1),
      Enum.map(plan.entries, &job_summary/1)}}
  end

  defp terminal_training_failure(program, plan, failures) do
    {:error, reason} = training_failure(plan, failures)

    reported_program = attach_terminal_failure_report(program, reason, plan, [])

    {:error,
     %TrainingError{
       reason: reason,
       program: reported_program,
       job: plan,
       status: :failed,
       metadata: terminal_failure_metadata(plan, [])
     }}
  end

  defp with_cancellation_outcomes(reason, []), do: reason

  defp with_cancellation_outcomes({:training_failed, status, metadata}, cancellations),
    do: {:training_failed, status, metadata, cancellations}

  defp with_cancellation_outcomes(
         {:training_plan_failed, failures, jobs},
         cancellations
       ),
       do: {:training_plan_failed, failures, jobs, cancellations}

  defp completed_training_result(optimizer, program, plan) do
    case rebind_training_plan(program, plan, optimizer.exclude_demos) do
      {:ok, rebound} ->
        {:ok,
         %TrainingResult{
           program: rebound,
           job: aggregate_job(plan),
           status: :completed,
           metadata: training_metadata(plan)
         }}

      {:error, reason} when length(plan.entries) == 1 ->
        {:error, {:training_rebind_failed, reason}}

      {:error, reason} ->
        {:error, {:training_plan_rebind_failed, reason}}
    end
  end

  defp rebind_training_plan(program, plan, exclude_demos?) do
    Enum.reduce_while(plan.entries, {:ok, program, []}, fn entry, {:ok, candidate, artifacts} ->
      source = predictor_for_name(candidate, hd(entry.predictor_names))

      case rebind_entry(entry, source) do
        {:ok, rebound_source} ->
          lm = Imp.ProgramAccess.lm(rebound_source)
          artifact = Imp.ProgramAccess.get_metadata(rebound_source, :training_artifact)

          candidate =
            Enum.reduce(entry.predictor_names, candidate, fn name, candidate ->
              Imp.ProgramParameters.update_predictor(candidate, name, fn predictor ->
                demos = if exclude_demos?, do: [], else: predictor.demos

                %{
                  predictor
                  | lm: lm,
                    dynamic_lm?: false,
                    demos: demos,
                    metadata: Map.put(predictor.metadata, :training_artifact, artifact)
                }
              end)
            end)

          {:cont, {:ok, candidate, artifacts ++ [artifact]}}

        {:error, reason} ->
          {:halt, {:error, %{key: public_key(entry.key), reason: reason}}}
      end
    end)
    |> case do
      {:ok, rebound, artifacts} ->
        {:ok, Imp.ProgramAccess.put_metadata(rebound, :training_artifacts, artifacts)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:bootstrap_finetune_rebind_failed, Exception.message(error)}}
  end

  defp rebind_entry(entry, nil),
    do: {:error, {:training_predictor_missing, public_key(entry.key)}}

  defp rebind_entry(entry, source), do: TrainingJob.rebind(entry.job, source)

  defp predictor_for_name(program, name) do
    program
    |> Imp.ProgramParameters.predictors()
    |> Enum.find_value(fn
      %{name: ^name, predictor: predictor} -> predictor
      _entry -> nil
    end)
  end

  defp aggregate_job(%TrainingPlan{entries: [entry]}), do: entry.job
  defp aggregate_job(%TrainingPlan{} = plan), do: plan

  defp training_metadata(plan) do
    %{
      method: :sft,
      grouping: if(plan.multitask, do: :unique_lm, else: :predictor),
      max_concurrency: plan.max_concurrency,
      predictor_data_filter: :named_predictor_correctness_deviation,
      job_count: length(plan.entries),
      jobs: Enum.map(plan.entries, &job_summary/1)
    }
  end

  defp job_summary(%{job: %TrainingJob{} = job} = entry) do
    %{
      key: public_key(entry.key),
      predictor_names: entry.predictor_names,
      job_id: job.id,
      status: job.status,
      metadata: job.metadata
    }
  end

  defp job_summary(entry) do
    %{
      key: public_key(entry.key),
      predictor_names: entry.predictor_names,
      job_id: nil,
      status: :not_started,
      metadata: %{}
    }
  end

  defp job_status(%{job: %TrainingJob{status: status}}), do: status

  defp cancel_training_plan_bounded(%TrainingPlan{} = plan, scope, deadline)
       when is_integer(deadline) do
    candidates =
      plan.entries
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _index} -> cancellation_candidate?(entry, scope) end)

    timeout = max(deadline - monotonic_ms(), 0)

    results =
      Task.Supervisor.async_stream_nolink(
        Imp.UnlinkedTaskSupervisor,
        candidates,
        fn {entry, _index} -> cancel_training_entry(entry) end,
        ordered: true,
        max_concurrency: max(length(candidates), 1),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {updates, outcomes} =
      candidates
      |> Enum.zip(results)
      |> Enum.reduce({%{}, []}, fn
        {{_entry, index}, {:ok, {updated, outcome}}}, {updates, outcomes} ->
          {Map.put(updates, index, updated), outcomes ++ [outcome]}

        {{entry, index}, {:exit, reason}}, {updates, outcomes} ->
          outcome = cancellation_task_failure(entry, reason, timeout)
          {Map.put(updates, index, entry), outcomes ++ [outcome]}
      end)

    entries =
      plan.entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> Map.get(updates, index, entry) end)

    {%{plan | entries: entries}, outcomes}
  end

  defp cancellation_task_failure(%{job: %TrainingJob{} = job} = entry, :timeout, timeout) do
    cancellation_outcome(
      entry,
      job,
      job.status,
      {:error, {:training_cancel_timeout, timeout}}
    )
  end

  defp cancellation_task_failure(%{job: %TrainingJob{} = job} = entry, reason, _timeout) do
    cancellation_outcome(
      entry,
      job,
      job.status,
      {:error, {:training_cancel_task_exit, reason}}
    )
  end

  defp cancellation_candidate?(%{job: %TrainingJob{status: status}}, scope)
       when scope in [:all_started, :pending],
       do: TrainingJob.active_status?(status)

  defp cancellation_candidate?(_entry, _scope), do: false

  defp cancel_training_entry(%{job: %TrainingJob{} = job} = entry) do
    case TrainingJob.cancel(job) do
      {:ok, %TrainingJob{} = cancelled} ->
        {%{entry | job: cancelled}, cancellation_outcome(entry, job, cancelled.status, :ok)}

      {:error, {:training_cancel_incomplete, status, metadata} = reason} ->
        updated = %{job | status: status, metadata: metadata}

        {%{entry | job: updated}, cancellation_outcome(entry, job, status, {:error, reason})}

      {:error, reason} ->
        {entry, cancellation_outcome(entry, job, job.status, {:error, reason})}

      other ->
        {entry, cancellation_outcome(entry, job, job.status, {:error, {:invalid_result, other}})}
    end
  rescue
    error ->
      {entry, cancellation_outcome(entry, job, job.status, {:error, Exception.message(error)})}
  catch
    kind, reason ->
      {entry, cancellation_outcome(entry, job, job.status, {:error, {kind, reason}})}
  end

  defp cancellation_outcome(entry, job, status, result) do
    %{
      key: public_key(entry.key),
      predictor_names: entry.predictor_names,
      job_id: job.id,
      prior_status: job.status,
      status: status,
      result: result
    }
  end

  defp public_key({lm, predictor_index}) do
    %{lm_fingerprint: lm_fingerprint(lm), predictor_index: predictor_index}
  end

  defp trace_error_stage({:metric_error, _reason}), do: :metric
  defp trace_error_stage(_reason), do: :program_call

  defp lm_fingerprint(lm) do
    lm
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp source_token(id), do: id |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp trajectory_metric(nil), do: fn _example, _prediction -> 1.0 end
  defp trajectory_metric(metric), do: metric

  defp average_score([]), do: 0.0

  defp average_score(candidates) do
    candidates
    |> Enum.map(& &1.score)
    |> Enum.sum()
    |> Kernel./(length(candidates))
  end

  defp executable_program?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :call, 2)
  end

  defp executable_program?(_program), do: false

  defp resolve_adapter(%Imp.Predict.Predict{dynamic_adapter?: true}),
    do: Imp.Settings.get().adapter

  defp resolve_adapter(%Imp.Predict.Predict{adapter: nil}), do: Imp.Settings.get().adapter
  defp resolve_adapter(%Imp.Predict.Predict{adapter: adapter}), do: adapter

  defp message_role(%{role: "system"}), do: :system
  defp message_role(%{role: "user"}), do: :user
  defp message_role(%{role: "assistant"}), do: :assistant
  defp message_role(%{role: role}), do: role
  defp message_role(%{"role" => "system"}), do: :system
  defp message_role(%{"role" => "user"}), do: :user
  defp message_role(%{"role" => "assistant"}), do: :assistant
  defp message_role(_message), do: nil

  defp message_content(%{content: content}) when is_binary(content), do: String.trim(content)
  defp message_content(%{"content" => content}) when is_binary(content), do: String.trim(content)
  defp message_content(_message), do: nil

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
