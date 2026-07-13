defmodule DSEx.Optimizer.GRPO do
  @moduledoc """
  Provider-neutral, iterative GRPO compilation.

  The optimizer owns rollout and grouping semantics; a trainer owns only the
  reinforcement session lifecycle and model artifact.
  """

  alias DSEx.Clients.{ReinforcementSession, Trainer}
  alias DSEx.Optimizer.TrajectoryRunner

  defstruct [
    :reward_fn,
    :trainer,
    :validation_fn,
    num_train_steps: 100,
    seed: 0,
    num_dspy_examples_per_grpo_step: 1,
    num_rollouts_per_grpo_step: 1,
    use_train_as_val: false,
    num_steps_for_val: 5,
    report_train_scores: false,
    failure_score: 0.0,
    format_failure_score: -1.0,
    variably_invoked_predictor_grouping_mode: :truncate,
    variably_invoked_predictor_fill_strategy: nil,
    status_poll_interval_ms: 1_000,
    max_status_polls: 300,
    train_kwargs: []
  ]

  @option_schema [
    trainer: [type: {:custom, DSEx.Clients.Trainer, :validate_provider, []}, default: nil],
    validation_fn: [type: {:or, [{:fun, 3}, nil]}, default: nil],
    num_train_steps: [type: :non_neg_integer, default: 100],
    seed: [type: :integer, default: 0],
    num_dspy_examples_per_grpo_step: [type: :pos_integer, default: 1],
    num_rollouts_per_grpo_step: [type: :pos_integer, default: 1],
    use_train_as_val: [type: :boolean, default: false],
    num_steps_for_val: [type: :pos_integer, default: 5],
    report_train_scores: [type: :boolean, default: false],
    failure_score: [type: {:or, [:integer, :float]}, default: 0.0],
    format_failure_score: [type: {:or, [:integer, :float]}, default: -1.0],
    variably_invoked_predictor_grouping_mode: [
      type: {:in, [:truncate, :fill, :ragged]},
      default: :truncate
    ],
    variably_invoked_predictor_fill_strategy: [
      type: {:or, [{:in, [:randint, :max]}, nil]},
      default: nil
    ],
    status_poll_interval_ms: [type: :non_neg_integer, default: 1_000],
    max_status_polls: [type: :pos_integer, default: 300],
    train_kwargs: [type: :keyword_list, default: []]
  ]

  def new(reward_fn, opts \\ []) do
    validate_reward!(reward_fn)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.GRPO.new/2")

    if opts[:failure_score] <= opts[:format_failure_score] do
      raise ArgumentError,
            "DSEx.Optimizer.GRPO.new/2 requires failure_score > format_failure_score"
    end

    if opts[:use_train_as_val] and not opts[:report_train_scores] do
      raise ArgumentError,
            "DSEx.Optimizer.GRPO.new/2 requires report_train_scores when use_train_as_val is true"
    end

    if opts[:variably_invoked_predictor_grouping_mode] == :fill and
         is_nil(opts[:variably_invoked_predictor_fill_strategy]) do
      raise ArgumentError,
            "DSEx.Optimizer.GRPO.new/2 requires a fill strategy when grouping mode is :fill"
    end

    struct!(__MODULE__, Keyword.put(opts, :reward_fn, reward_fn))
  end

  def compile(%__MODULE__{} = optimizer, program, trainset),
    do: compile(optimizer, program, trainset, [])

  def compile(%__MODULE__{trainer: nil}, _program, _trainset, _opts),
    do: {:error, :trainer_required}

  def compile(%__MODULE__{} = optimizer, program, trainset, opts) when is_list(opts) do
    valset = Keyword.get(opts, :valset)

    with :ok <- validate_compile_inputs(optimizer, program, trainset, valset),
         :ok <- Trainer.supports_method(optimizer.trainer, :grpo),
         lm <- program_lm(program),
         {:ok, session} <-
           Trainer.start_reinforcement(
             optimizer.trainer,
             lm,
             Keyword.put(
               optimizer.train_kwargs,
               :num_generations,
               optimizer.num_rollouts_per_grpo_step
             )
           ) do
      run_started_session(optimizer, program, trainset, valset, session)
    end
  end

  def compile(%__MODULE__{}, _program, _trainset, opts),
    do:
      raise(
        ArgumentError,
        "DSEx.Optimizer.GRPO.compile/4 expects keyword options, got: #{inspect(opts)}"
      )

  defp run_started_session(optimizer, program, trainset, valset, session) do
    trainset = repeat_short_trainset(trainset, optimizer.num_dspy_examples_per_grpo_step)

    initial_state = %{
      session: session,
      program: program,
      rng: seed_state(optimizer.seed),
      shuffled_ids: [],
      frequencies: %{},
      frequency_order: [],
      epoch: -1,
      group_queue: []
    }

    result =
      with :ok <- maybe_validate(optimizer, program, trainset, valset, -1),
           {:ok, state} <- run_steps(optimizer, trainset, valset, initial_state) do
        {:ok, state}
      end

    case result do
      {:ok, state} ->
        with {:ok, terminated} <-
               Trainer.terminate_reinforcement(optimizer.trainer, state.session),
             {:ok, artifact} <-
               Trainer.final_model_artifact(optimizer.trainer, terminated),
             {:ok, rebound} <- rebind_program(state.program, artifact, terminated) do
          {:ok, rebound}
        end

      {:error, reason, state} ->
        _ = Trainer.terminate_reinforcement(optimizer.trainer, state.session)
        {:error, reason}

      {:error, reason} ->
        _ = Trainer.terminate_reinforcement(optimizer.trainer, initial_state.session)
        {:error, reason}
    end
  end

  defp run_steps(%{num_train_steps: 0}, _trainset, _valset, state),
    do: {:ok, state}

  defp run_steps(optimizer, trainset, valset, state) do
    Enum.reduce_while(0..(optimizer.num_train_steps - 1), {:ok, state}, fn step, {:ok, state} ->
      case run_step(optimizer, trainset, valset, step, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  defp run_step(optimizer, trainset, valset, step, state) do
    with {:ok, selected, state} <- select_examples(optimizer, trainset, step, state),
         {:ok, session} <- await_pending(optimizer, state.session, optimizer.max_status_polls) do
      state = %{state | session: session}

      with {:ok, groups, state} <- build_groups(optimizer, state.program, selected, step, state),
           {:ok, batches, state} <- assign_batches(groups, session, state),
           {:ok, stepped} <- Trainer.reinforcement_step(optimizer.trainer, session, batches) do
        program = rebind_current_model(state.program, stepped.current_model)
        state = %{state | session: stepped, program: program}

        case maybe_validate(optimizer, program, trainset, valset, step) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, state}
        end
      else
        {:error, reason} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp await_pending(_optimizer, _session, 0),
    do: {:error, :reinforcement_pending_batch_timeout}

  defp await_pending(optimizer, session, polls_left) do
    with {:ok, refreshed} <- Trainer.reinforcement_status(optimizer.trainer, session) do
      available =
        Enum.reject(refreshed.pending_batch_ids, &(&1 in refreshed.fulfilled_batch_ids))

      if available == [] do
        Process.sleep(optimizer.status_poll_interval_ms)
        await_pending(optimizer, refreshed, polls_left - 1)
      else
        {:ok, %{refreshed | pending_batch_ids: available}}
      end
    end
  end

  defp select_examples(optimizer, trainset, step, state) do
    width = optimizer.num_dspy_examples_per_grpo_step
    base = step * width
    epoch = if state.epoch == -1, do: 0, else: div(base, max(length(state.shuffled_ids), 1))

    {state, epoch} =
      if epoch > state.epoch do
        {ids, rng} = shuffle(Enum.to_list(0..(length(trainset) - 1)), state.rng)

        frequencies =
          Enum.reduce(ids, state.frequencies, &Map.update(&2, &1, 1, fn n -> n + 1 end))

        frequency_order =
          state.frequency_order ++ Enum.reject(ids, &(&1 in state.frequency_order))

        padding = width - rem(length(trainset), width)
        {ids, frequencies} = pad_ids(ids, frequencies, frequency_order, padding)

        {%{
           state
           | shuffled_ids: ids,
             frequencies: frequencies,
             frequency_order: frequency_order,
             epoch: epoch,
             rng: rng
         }, epoch}
      else
        {state, epoch}
      end

    base = rem(step * width, length(state.shuffled_ids))
    ids = Enum.slice(state.shuffled_ids, base, width)

    if length(ids) == width do
      {:ok, Enum.map(ids, &Enum.at(trainset, &1)), %{state | epoch: epoch}}
    else
      {:error, :invalid_grpo_selection_state}
    end
  end

  # This preserves the pinned implementation's extra full batch when the
  # dataset size is already divisible by the per-step width.
  defp pad_ids(ids, frequencies, frequency_order, count) do
    Enum.reduce(1..count, {ids, frequencies}, fn _, {ids, frequencies} ->
      selected =
        frequencies
        |> Enum.min_by(fn {id, frequency} ->
          {frequency, -Enum.find_index(frequency_order, &(&1 == id))}
        end)
        |> elem(0)

      {ids ++ [selected], Map.update!(frequencies, selected, &(&1 + 1))}
    end)
  end

  defp build_groups(optimizer, program, examples, step, state) do
    predictors = DSEx.ProgramParameters.predictors(program)

    trajectories =
      for rollout <- 0..(optimizer.num_rollouts_per_grpo_step - 1),
          reduce: [] do
        acc ->
          rollout_program = bind_rollout(program, step, rollout)

          round =
            TrajectoryRunner.run(
              rollout_program,
              examples,
              trajectory_metric(optimizer.reward_fn),
              max_concurrency: 1,
              rollout_id: rollout
            )
            |> Enum.with_index()
            |> Enum.map(fn {trajectory, example_index} ->
              %{trajectory: trajectory, rollout: rollout, example_index: example_index}
            end)

          acc ++ round
      end

    {groups, rng} =
      Enum.reduce(predictors, {[], state.rng}, fn predictor, acc ->
        Enum.reduce(Enum.with_index(examples), acc, fn {_example, example_index}, {groups, rng} ->
          rollouts =
            trajectories
            |> Enum.filter(&(&1.example_index == example_index))
            |> Enum.sort_by(& &1.rollout)

          {predictor_groups, rng} =
            groups_for_predictor(optimizer, predictor, rollouts, example_index, rng)

          {groups ++ predictor_groups, rng}
        end)
      end)

    if groups == [],
      do: {:error, :no_grpo_training_data},
      else: {:ok, groups, %{state | rng: rng}}
  end

  defp groups_for_predictor(
         optimizer,
         %{name: name, predictor: predictor},
         rollouts,
         example_index,
         rng
       ) do
    invocations =
      Enum.map(rollouts, fn %{trajectory: trajectory} ->
        matching = Enum.filter(trajectory.trace || [], &(fetch(&1, :predictor) == name))

        if matching == [] do
          failure_invocations(optimizer, predictor, trajectory)
        else
          Enum.map(matching, &successful_invocation(optimizer, predictor, trajectory, &1))
        end
      end)

    if invocations == [] or Enum.any?(invocations, &(&1 == [])) do
      {[], rng}
    else
      {invocations, rng} = normalize_invocation_counts(optimizer, invocations, rng)
      max_count = invocations |> Enum.map(&length/1) |> Enum.max()

      groups =
        for invocation_index <- 0..(max_count - 1),
            group = Enum.flat_map(invocations, &List.wrap(Enum.at(&1, invocation_index))),
            group != [] do
          group = pad_group(group, optimizer.num_rollouts_per_grpo_step)

          %{
            predictor: name,
            group_id: {example_index, name, invocation_index},
            group: group
          }
        end

      {groups, rng}
    end
  end

  defp normalize_invocation_counts(
         %{variably_invoked_predictor_grouping_mode: :truncate},
         lists,
         rng
       ) do
    count = lists |> Enum.map(&length/1) |> Enum.min()
    {Enum.map(lists, &Enum.take(&1, count)), rng}
  end

  defp normalize_invocation_counts(
         %{variably_invoked_predictor_grouping_mode: :ragged},
         lists,
         rng
       ),
       do: {lists, rng}

  defp normalize_invocation_counts(%{variably_invoked_predictor_fill_strategy: :max}, lists, rng) do
    count = lists |> Enum.map(&length/1) |> Enum.max()
    {Enum.map(lists, &fill_to(&1, count, List.last(&1))), rng}
  end

  defp normalize_invocation_counts(
         %{variably_invoked_predictor_fill_strategy: :randint},
         lists,
         rng
       ) do
    count = lists |> Enum.map(&length/1) |> Enum.max()

    Enum.map_reduce(lists, rng, fn list, rng ->
      if length(list) >= count do
        {list, rng}
      else
        Enum.reduce((length(list) + 1)..count, {list, rng}, fn _, {filled, rng} ->
          {index, rng} = uniform(length(list), rng)
          {filled ++ [Enum.at(list, index - 1)], rng}
        end)
      end
    end)
  end

  defp successful_invocation(_optimizer, predictor, trajectory, trace) do
    inputs = fetch(trace, :inputs, %{})
    outputs = fetch(trace, :outputs, %{})
    adapter = predictor_adapter(predictor)

    %{
      messages: normalize_messages(adapter.format(predictor.signature, inputs, demos: [])),
      completion: completion_message(adapter, predictor.signature, inputs, outputs),
      reward: trajectory.score * 1.0
    }
  end

  defp failure_invocations(optimizer, predictor, trajectory) do
    case failure_trace(trajectory.error) do
      %{messages: messages, raw: raw} ->
        [
          %{
            messages: normalize_messages(messages),
            completion: %{role: "assistant", content: completion_content(raw)},
            reward: optimizer.format_failure_score * 1.0
          }
        ]

      _other ->
        inputs = trajectory.example |> DSEx.Example.inputs() |> DSEx.Example.to_map()
        adapter = predictor_adapter(predictor)

        [
          %{
            messages: normalize_messages(adapter.format(predictor.signature, inputs, demos: [])),
            completion: %{role: "assistant", content: ""},
            reward: optimizer.failure_score * 1.0
          }
        ]
    end
  end

  defp assign_batches(groups, %ReinforcementSession{} = session, state) do
    available =
      Enum.reject(session.pending_batch_ids, &(&1 in session.fulfilled_batch_ids))

    {queue, rng} = refill_queue(state.group_queue, groups, length(available), state.rng)
    {selected, queue} = Enum.split(queue, length(available))

    batches =
      Enum.zip(available, selected)
      |> Enum.map(fn {batch_id, group} -> Map.put(group, :batch_id, batch_id) end)

    if batches == [],
      do: {:error, :no_pending_reinforcement_batches},
      else: {:ok, batches, %{state | group_queue: queue, rng: rng}}
  end

  defp refill_queue(queue, _groups, needed, rng) when length(queue) >= needed,
    do: {queue, rng}

  defp refill_queue(queue, groups, needed, rng) do
    {shuffled, rng} = shuffle(groups, rng)
    refill_queue(queue ++ shuffled, groups, needed, rng)
  end

  defp maybe_validate(optimizer, program, trainset, valset, step) do
    due? =
      step == -1 or step == optimizer.num_train_steps - 1 or
        rem(step + 1, optimizer.num_steps_for_val) == 0

    dataset = validation_dataset(optimizer, trainset, valset)

    if due? and dataset != [] do
      context = %{step: step, final?: step == optimizer.num_train_steps - 1}

      case optimizer.validation_fn do
        nil ->
          _ =
            TrajectoryRunner.run(program, dataset, trajectory_metric(optimizer.reward_fn),
              max_concurrency: 1
            )

          :ok

        fun ->
          case fun.(program, dataset, context) do
            :ok -> :ok
            {:ok, _result} -> :ok
            {:error, _reason} = error -> error
            other -> {:error, {:invalid_grpo_validation_result, other}}
          end
      end
    else
      :ok
    end
  end

  defp validation_dataset(%{report_train_scores: true}, trainset, valset) when is_list(valset),
    do: valset ++ trainset

  defp validation_dataset(_optimizer, _trainset, valset) when is_list(valset), do: valset
  defp validation_dataset(%{use_train_as_val: true}, trainset, nil), do: trainset
  defp validation_dataset(_optimizer, _trainset, nil), do: []

  defp validate_compile_inputs(optimizer, program, trainset, valset) do
    cond do
      not is_list(trainset) or trainset == [] ->
        {:error, :empty_grpo_trainset}

      Enum.any?(trainset, &(not match?(%DSEx.Example{}, &1))) ->
        {:error, :invalid_grpo_trainset}

      not is_nil(valset) and not is_list(valset) ->
        {:error, :invalid_grpo_valset}

      is_list(valset) and Enum.any?(valset, &(not match?(%DSEx.Example{}, &1))) ->
        {:error, :invalid_grpo_valset}

      optimizer.use_train_as_val and not is_nil(valset) ->
        {:error, :grpo_train_and_val_conflict}

      optimizer.report_train_scores and is_nil(valset) and not optimizer.use_train_as_val ->
        {:error, :grpo_train_scores_require_validation}

      DSEx.ProgramParameters.predictors(program) == [] ->
        {:error, :grpo_predictor_required}

      Enum.any?(DSEx.ProgramParameters.predictors(program), &is_nil(&1.predictor.lm)) ->
        {:error, :grpo_predictor_lm_required}

      unique_lms(program) != 1 ->
        {:error, :grpo_single_student_lm_required}

      true ->
        :ok
    end
  end

  defp rebind_program(program, artifact, session) do
    rebound =
      Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
        DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
          %{predictor | lm: rebind_lm(predictor.lm, artifact), dynamic_lm?: false}
        end)
      end)
      |> DSEx.ProgramAccess.put_metadata(:training_artifact, %{
        provider: session.provider,
        session_id: session.id,
        result_model: artifact,
        method: :grpo
      })

    {:ok, rebound}
  rescue
    error -> {:error, {:grpo_rebind_failed, Exception.message(error)}}
  end

  defp rebind_lm(%DSEx.Clients.ReqLLM{} = lm, artifact), do: %{lm | model: artifact}
  defp rebind_lm(%{model: _} = lm, artifact), do: Map.put(lm, :model, artifact)
  defp rebind_lm(lm, artifact) when is_map(lm), do: Map.put(lm, :model, artifact)
  defp rebind_lm(_lm, _artifact), do: raise(ArgumentError, "student LM is not rebindable")

  defp rebind_current_model(program, nil), do: program

  defp rebind_current_model(program, model) when is_binary(model) and model != "" do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
        %{predictor | lm: rebind_lm(predictor.lm, model), dynamic_lm?: false}
      end)
    end)
  end

  defp bind_rollout(program, step, rollout) do
    rollout_id = step * 1_000_000 + rollout

    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
        %{predictor | config: Keyword.put(predictor.config, :rollout_id, rollout_id)}
      end)
    end)
  end

  defp completion_message(adapter, signature, inputs, outputs) do
    demo =
      inputs
      |> Map.merge(outputs)
      |> DSEx.Example.new()

    adapter.format(signature, %{}, demos: [demo])
    |> Enum.find(&(message_role(&1) == "assistant"))
    |> normalize_message()
  end

  defp predictor_adapter(%{dynamic_adapter?: true}), do: DSEx.Settings.get().adapter
  defp predictor_adapter(%{adapter: nil}), do: DSEx.Settings.get().adapter
  defp predictor_adapter(%{adapter: adapter}), do: adapter

  defp normalize_messages(messages), do: Enum.map(messages, &normalize_message/1)

  defp normalize_message(message) do
    %{role: message_role(message), content: fetch(message, :content, "")}
  end

  defp message_role(message), do: message |> fetch(:role, "assistant") |> to_string()

  defp failure_trace(%{trace: trace}) when is_map(trace), do: trace
  defp failure_trace(%{"trace" => trace}) when is_map(trace), do: trace
  defp failure_trace(_error), do: nil

  defp completion_content(content) when is_binary(content), do: content
  defp completion_content(content), do: Jason.encode!(content)

  defp pad_group(group, size) when length(group) >= size, do: Enum.take(group, size)
  defp pad_group([], _size), do: []

  defp pad_group(group, size),
    do: pad_group(group ++ Enum.take(group, size - length(group)), size)

  defp fill_to(list, count, _item) when length(list) >= count, do: list
  defp fill_to(list, count, item), do: fill_to(list ++ [item], count, item)

  defp unique_lms(program) do
    program
    |> DSEx.ProgramParameters.predictors()
    |> Enum.map(&:erlang.term_to_binary(&1.predictor.lm, [:deterministic]))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp program_lm(program),
    do:
      program
      |> DSEx.ProgramParameters.predictors()
      |> hd()
      |> Map.fetch!(:predictor)
      |> Map.fetch!(:lm)

  defp repeat_short_trainset(trainset, width) when length(trainset) < width do
    multiplier = div(width + length(trainset) - 1, length(trainset))
    List.duplicate(trainset, multiplier) |> List.flatten()
  end

  defp repeat_short_trainset(trainset, _width), do: trainset

  defp seed_state(seed) do
    value = abs(seed) + 1
    :rand.seed_s(:exsss, {value, value * 2 + 1, value * 3 + 7})
  end

  defp shuffle(list, rng) do
    Enum.reduce(Enum.reverse(1..length(list)), {list, rng}, fn
      index, {items, rng} when index > 1 ->
        {swap_index, rng} = uniform(index, rng)
        {swap(items, index - 1, swap_index - 1), rng}

      _index, state ->
        state
    end)
  end

  defp uniform(max, rng), do: :rand.uniform_s(max, rng)

  defp swap(list, index, index), do: list

  defp swap(list, left, right) do
    left_value = Enum.at(list, left)
    right_value = Enum.at(list, right)

    list
    |> List.replace_at(left, right_value)
    |> List.replace_at(right, left_value)
  end

  defp fetch(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp trajectory_metric(reward_fn) when is_function(reward_fn, 3), do: reward_fn
  defp trajectory_metric(reward_fn) when is_function(reward_fn, 2), do: reward_fn
  defp trajectory_metric(reward_fn), do: fn example, _prediction -> reward_fn.(example) end

  defp validate_reward!(reward_fn) do
    unless is_function(reward_fn) and
             Enum.any?([1, 2, 3], &:erlang.is_function(reward_fn, &1)) do
      raise ArgumentError,
            "DSEx.Optimizer.GRPO.new/2 expects a reward function with arity 1, 2, or 3"
    end
  end
end
