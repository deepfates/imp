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

      step = div(length(session.fulfilled_batch_ids), 2) + 1

      if session.backend_state.mode == :step_error,
        do: {:error, {:reinforcement_step_not_accepted, :step_failed}},
        else:
          {:ok,
           %{
             session
             | current_model: "trained/step-#{step}",
               result_model: "trained/step-#{step}",
               metadata: %{
                 artifact_sha256: "artifact-step-#{step}",
                 checkpoint_sha256: "checkpoint-step-#{step}"
               }
           }}
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

    @impl true
    def reinforcement_artifact(trainer, _session, selection) do
      send(trainer.owner, {:selected_artifact, selection})
      {:ok, selection}
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

    assert_received {:start, _lm, start_opts}
    assert is_binary(start_opts[:dispatch_id])
    assert start_opts[:dispatch_id] != ""

    assert Enum.map(first, & &1.batch_id) == [10, 11]
    assert Enum.map(second, & &1.batch_id) == [30, 31]
    assert Enum.map(first, & &1.predictor) == [:main, :main]

    assert MapSet.new(Enum.map(first, & &1.group_id)) ==
             MapSet.new([{0, :main, 0}, {1, :main, 0}])

    assert Enum.all?(first ++ second, &(length(&1.group) == 2))

    assert Enum.all?(first, fn group ->
             group.selection_step == 0 and group.source_position == elem(group.group_id, 0) and
               String.starts_with?(group.source_row_sha256, "sha256:")
           end)

    assert Enum.all?(second, fn group ->
             group.selection_step == 1 and group.source_position == elem(group.group_id, 0) and
               String.starts_with?(group.source_row_sha256, "sha256:")
           end)

    assert Enum.all?(first ++ second, fn batch ->
             length(Enum.uniq(Enum.map(batch.group, & &1.completion.content))) == 2 and
               Enum.all?(batch.group, &(question_from(&1) == question_from(hd(batch.group))))
           end)

    assert Imp.ProgramAccess.lm(compiled).model == "trained/grpo-model"
    assert Imp.ProgramAccess.get_metadata(compiled, :training_artifact).method == :grpo
    assert_received {:terminate, [10, 11, 30, 31]}
    assert_received {:artifact, :succeeded}
  end

  test "forwards and seals normalized public trainer configuration" do
    {_compiled, _steps} =
      run(7,
        train_kwargs: [
          learning_rate: 1.0e-6,
          beta: 0.0,
          loss_type: :dapo,
          scale_rewards: :none
        ]
      )

    assert_received {:start, _lm, start_opts}

    assert Keyword.take(start_opts, [:learning_rate, :beta, :loss_type, :scale_rewards]) ==
             [
               learning_rate: 1.0e-6,
               beta: 0.0,
               loss_type: :dapo,
               scale_rewards: :none
             ]

    expected = %{
      "learning_rate" => 1.0e-6,
      "beta" => 0.0,
      "loss_type" => "dapo",
      "scale_rewards" => "none"
    }

    assert get_in(start_opts, [:imp_reinforcement_contract, "optimizer", "config_sha256"]) ==
             Imp.Clients.TRLProtocol.digest(expected)
  end

  test "predeclared validation selects and rebinds the earliest best trained checkpoint" do
    scores = %{0 => 1.0, 1 => 0.5}

    optimizer =
      Imp.Optimizer.GRPO.new(
        fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        validation_fn: fn _program, _dataset, %{step: step} -> {:ok, Map.fetch!(scores, step)} end,
        checkpoint_selection: :best_validation,
        num_train_steps: 2,
        num_steps_for_val: 1,
        num_dspy_examples_per_grpo_step: 2,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0
      )

    static = fn _messages, _opts -> %{answer: "ok"} end

    assert {:ok, compiled} =
             Imp.Optimizer.GRPO.compile(
               optimizer,
               program(static),
               trainset(),
               valset: Enum.take(trainset(), 2)
             )

    assert Imp.ProgramAccess.lm(compiled).model == "trained/step-1"
    artifact = Imp.ProgramAccess.get_metadata(compiled, :training_artifact)
    assert artifact.result_model == "trained/step-1"
    assert artifact.selected_validation_step == 1
    assert artifact.selected_validation_score == 1.0
    assert artifact.final_trained_model == "trained/grpo-model"
    assert Enum.map(artifact.validation_history, &{&1.step, &1.score}) == [{1, 1.0}, {2, 0.5}]

    assert_received {:selected_artifact,
                     %{
                       step: 1,
                       score: 1.0,
                       path: "trained/step-1",
                       artifact_sha256: "artifact-step-1",
                       checkpoint_sha256: "checkpoint-step-1"
                     }}
  end

  test "best checkpoint selection rejects report-only validation results" do
    optimizer =
      Imp.Optimizer.GRPO.new(
        fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        validation_fn: fn _program, _dataset, _context -> :ok end,
        checkpoint_selection: :best_validation,
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0
      )

    assert {:error, {:invalid_grpo_validation_result, :ok}} =
             Imp.Optimizer.GRPO.compile(
               optimizer,
               program(fn _messages, _opts -> %{answer: "ok"} end),
               trainset(),
               valset: Enum.take(trainset(), 1)
             )
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

  test "partially decoded multi-output failures receive structural format credit" do
    partial_failure =
      Imp.predict("question -> answer, confidence",
        lm: %{
          module: Imp.LM.Static,
          model: "base-model",
          opts: [handler: fn _messages, _opts -> %{answer: "present"} end]
        },
        json_fallback: false
      )

    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2,
        failure_score: -1,
        format_failure_score: -5,
        status_poll_interval_ms: 0
      )

    assert {:ok, _compiled} =
             Imp.Optimizer.GRPO.compile(optimizer, partial_failure, Enum.take(trainset(), 1))

    assert_received {:step, batches}
    group = batches |> hd() |> Map.fetch!(:group)
    assert Enum.map(group, & &1.reward) == [-3.0, -3.0]
    assert Enum.all?(group, &(not Map.has_key?(&1, :outputs)))
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

  test "terminates a started session when validation raises" do
    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer(),
        validation_fn: fn _program, _dataset, _context -> raise "validation exploded" end,
        num_train_steps: 1,
        status_poll_interval_ms: 0
      )

    assert {:error, {:grpo_execution_failed, "validation exploded"}} =
             Imp.Optimizer.GRPO.compile(
               optimizer,
               program(fn _messages, _opts -> %{answer: "ok"} end),
               Enum.take(trainset(), 1),
               valset: Enum.take(trainset(), 1)
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
