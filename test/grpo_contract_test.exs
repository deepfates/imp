defmodule GRPOContractTest do
  use ExUnit.Case

  defmodule SessionTrainer do
    @behaviour Imp.Clients.Trainer

    defstruct [:owner, :mode, artifact: "trained/grpo-model"]

    @impl true
    def supported_methods(%__MODULE__{}), do: [:grpo]

    @impl true
    def start_reinforcement(trainer, lm, opts) do
      send(trainer.owner, {:start, lm, opts})

      {:ok,
       Imp.Clients.ReinforcementSession.new(%{
         id: "session-1",
         provider: :fixture,
         model: lm,
         pending_batch_ids: [10, 11],
         backend_state: %{owner: trainer.owner, mode: trainer.mode}
       })}
    end

    @impl true
    def reinforcement_status(_trainer, session) do
      offset = length(session.fulfilled_batch_ids) * 10
      pending = Enum.map([10, 11], &(&1 + offset))
      send(session.backend_state.owner, {:status, pending})
      {:ok, %{session | pending_batch_ids: pending}}
    end

    @impl true
    def reinforcement_step(_trainer, session, groups, _opts) do
      send(session.backend_state.owner, {:step, groups})

      if session.backend_state.mode == :step_error,
        do: {:error, :step_failed},
        else: {:ok, session}
    end

    @impl true
    def terminate_reinforcement(_trainer, session) do
      send(session.backend_state.owner, {:terminate, session.fulfilled_batch_ids})
      {:ok, %{session | status: :succeeded, pending_batch_ids: []}}
    end

    @impl true
    def final_model_artifact(trainer, session) do
      send(trainer.owner, {:artifact, session.status})
      {:ok, trainer.artifact}
    end
  end

  defmodule TwoPredictorProgram do
    @behaviour Imp.Module

    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    @impl true
    def call(program, inputs) do
      with {:ok, first} <- Imp.Module.call(program.first, inputs),
           {:ok, second} <- Imp.Module.call(program.second, inputs) do
        {:ok,
         Imp.Prediction.new(
           Map.merge(Imp.Prediction.to_map(first), Imp.Prediction.to_map(second))
         )}
      end
    end
  end

  defp trainer(mode \\ :ok), do: %SessionTrainer{owner: self(), mode: mode}

  defp program(handler) do
    lm = %{module: Imp.LM.Static, opts: [handler: handler], model: "base-model"}
    Imp.predict("question -> answer", lm: lm)
  end

  defp trainset do
    for question <- ["alpha", "beta", "gamma", "delta"] do
      Imp.example(question: question, answer: question) |> Imp.with_inputs(:question)
    end
  end

  defp question_from(%{messages: messages}) do
    messages
    |> Enum.find(&(&1.role == "user"))
    |> Map.fetch!(:content)
    |> then(fn content ->
      Enum.find(["alpha", "beta", "gamma", "delta"], &String.contains?(content, &1))
    end)
  end

  defp run(seed, opts \\ []) do
    handler = fn messages, lm_opts ->
      question =
        messages
        |> Enum.find(&(Map.get(&1, :role) == :user))
        |> Map.fetch!(:content)
        |> then(fn content ->
          Enum.find(["alpha", "beta", "gamma", "delta"], &String.contains?(content, &1))
        end)

      %{answer: "#{question}-#{Keyword.fetch!(lm_opts, :rollout_id)}"}
    end

    optimizer =
      Imp.Optimizer.GRPO.new(
        fn _example, _prediction -> 1.0 end,
        [
          trainer: trainer(),
          seed: seed,
          num_train_steps: 2,
          num_dspy_examples_per_grpo_step: 2,
          num_rollouts_per_grpo_step: 2,
          status_poll_interval_ms: 0
        ] ++ opts
      )

    assert {:ok, compiled} = Imp.Optimizer.GRPO.compile(optimizer, program(handler), trainset())

    steps = collect_steps([])
    {compiled, steps}
  end

  defp collect_steps(acc) do
    receive do
      {:step, groups} -> collect_steps(acc ++ [groups])
    after
      0 -> acc
    end
  end

  test "orders pending ids, predictor groups, and repeated rollouts structurally" do
    {compiled, [first, second]} = run(7)

    assert Enum.map(first, & &1.batch_id) == [10, 11]
    assert Enum.map(second, & &1.batch_id) == [30, 31]
    assert Enum.map(first, & &1.predictor) == [:main, :main]

    assert MapSet.new(Enum.map(first, & &1.group_id)) ==
             MapSet.new([{0, :main, 0}, {1, :main, 0}])

    assert Enum.all?(first ++ second, &(length(&1.group) == 2))

    assert Enum.all?(first ++ second, fn batch ->
             length(Enum.uniq(Enum.map(batch.group, & &1.completion.content))) == 2 and
               Enum.all?(batch.group, &(question_from(&1) == question_from(hd(batch.group))))
           end)

    assert Imp.ProgramAccess.lm(compiled).model == "trained/grpo-model"
    assert Imp.ProgramAccess.get_metadata(compiled, :training_artifact).method == :grpo
    assert_received {:terminate, [10, 11, 30, 31]}
    assert_received {:artifact, :succeeded}
  end

  test "keeps predictor identity and predictor-major source ordering" do
    lm = %{
      module: Imp.LM.Static,
      model: "base-model",
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

          if String.contains?(prompt, "first_answer"),
            do: %{first_answer: "one"},
            else: %{second_answer: "two"}
        end
      ]
    }

    program = %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: lm),
      second: Imp.predict("question -> second_answer", lm: lm)
    }

    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0
      )

    assert {:ok, compiled} =
             Imp.Optimizer.GRPO.compile(optimizer, program, Enum.take(trainset(), 1))

    assert_received {:step, batches}
    assert MapSet.new(Enum.map(batches, & &1.predictor)) == MapSet.new([:first, :second])

    # Queue assignment is shuffled, so identity is asserted independently of batch order.
    assert MapSet.new(Enum.map(batches, & &1.group_id)) ==
             MapSet.new([{0, :first, 0}, {0, :second, 0}])

    assert Enum.all?(TwoPredictorProgram.optimizer_predictors(compiled), fn {_name, predictor} ->
             predictor.lm.model == "trained/grpo-model"
           end)
  end

  test "the seed fixes example and group ordering" do
    {_compiled, steps_a} = run(19)
    {_compiled, steps_b} = run(19)
    {_compiled, steps_c} = run(20)

    projection = fn steps ->
      for groups <- steps, group <- groups do
        {group.group_id, question_from(hd(group.group))}
      end
    end

    assert projection.(steps_a) == projection.(steps_b)
    refute projection.(steps_a) == projection.(steps_c)
  end

  test "format and execution failures receive distinct configured rewards" do
    parse_failure = program(fn _messages, _opts -> %{} end)

    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2,
        failure_score: -2,
        format_failure_score: -5,
        status_poll_interval_ms: 0
      )

    assert {:ok, _compiled} =
             Imp.Optimizer.GRPO.compile(optimizer, parse_failure, Enum.take(trainset(), 1))

    assert_received {:step, parse_batches}
    parse_group = parse_batches |> hd() |> Map.fetch!(:group)
    assert Enum.map(parse_group, & &1.reward) == [-5.0, -5.0]
    assert Enum.all?(parse_group, &is_binary(&1.completion.content))

    execution_failure = program(fn _messages, _opts -> raise "rollout failed" end)

    assert {:ok, _compiled} =
             Imp.Optimizer.GRPO.compile(optimizer, execution_failure, Enum.take(trainset(), 1))

    assert_received {:step, execution_batches}
    execution_group = execution_batches |> hd() |> Map.fetch!(:group)
    assert Enum.map(execution_group, & &1.reward) == [-2.0, -2.0]
  end

  test "terminates a started session when a training step fails" do
    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer(:step_error),
        num_train_steps: 1,
        status_poll_interval_ms: 0
      )

    assert {:error, :step_failed} =
             Imp.Optimizer.GRPO.compile(
               optimizer,
               program(fn _messages, _opts -> %{answer: "ok"} end),
               Enum.take(trainset(), 1)
             )

    assert_received {:terminate, []}
    refute_received {:artifact, _}
  end

  test "validates before training, periodically, and on the final step" do
    parent = self()

    validation = fn _program, dataset, context ->
      send(parent, {:validation, length(dataset), context.step, context.final?})
      :ok
    end

    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        validation_fn: validation,
        num_train_steps: 3,
        num_steps_for_val: 2,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0
      )

    assert {:ok, _compiled} =
             Imp.Optimizer.GRPO.compile(
               optimizer,
               program(fn _messages, opts -> %{answer: to_string(opts[:rollout_id])} end),
               Enum.take(trainset(), 1),
               valset: Enum.take(trainset(), 2)
             )

    assert_received {:validation, 2, -1, false}
    assert_received {:validation, 2, 1, false}
    assert_received {:validation, 2, 2, true}
    refute_received {:validation, _, 0, _}
  end

  test "OpenAI remains SFT-only at the reinforcement boundary" do
    openai = Imp.Clients.OpenAITrainer.new(base_url: "https://example.invalid/v1")

    assert {:error, {:unsupported_training_method, :grpo}} =
             Imp.Clients.Trainer.start_reinforcement(
               openai,
               Imp.req_llm("gpt-test"),
               []
             )
  end
end
