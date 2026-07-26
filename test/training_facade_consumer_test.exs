defmodule Imp.TrainingFacadeConsumerTest do
  use ExUnit.Case

  alias Imp.Clients.{ReinforcementSession, TrainingJob}
  alias Imp.Optimizer.TrainingResult

  defmodule LocalLM do
    @behaviour Imp.LM

    defstruct [:model]

    @impl true
    def generate(messages, _opts) do
      question =
        messages
        |> Enum.map_join("\n", &Map.get(&1, :content, ""))
        |> then(fn prompt -> if prompt =~ "2+2", do: "4", else: "unknown" end)

      {:ok, %{answer: question}}
    end
  end

  defmodule LocalGRPOTrainer do
    @behaviour Imp.Clients.Trainer

    defstruct [:owner]

    @impl true
    def supported_methods(%__MODULE__{}), do: [:grpo]

    @impl true
    def start_reinforcement(%__MODULE__{owner: owner}, lm, opts) do
      send(owner, {:grpo_started, lm, opts})

      {:ok,
       ReinforcementSession.new(%{
         id: "local-grpo-session",
         provider: :local,
         model: lm,
         status: :running,
         pending_batch_ids: ["batch-1"]
       })}
    end

    @impl true
    def reinforcement_status(_trainer, session), do: {:ok, session}

    @impl true
    def reinforcement_step(%__MODULE__{owner: owner}, session, groups, _opts) do
      send(owner, {:grpo_groups, groups})
      {:ok, session}
    end

    @impl true
    def terminate_reinforcement(_trainer, session) do
      {:ok, %{session | status: :succeeded, pending_batch_ids: []}}
    end

    @impl true
    def final_model_artifact(_trainer, _session), do: {:ok, "local/grpo-trained"}
  end

  defmodule StableGRPOCallbacks do
    def reward(_example, _prediction, %{"value" => value}), do: value

    def validate(_program, rows, context, %{"path" => path}) do
      record = %{"rows" => Enum.map(rows, &Imp.get(&1, :question)), "context" => context}
      File.write!(path, Jason.encode!(record) <> "\n", [:append, :sync])
      :ok
    end
  end

  defp program do
    Imp.predict("question -> answer", lm: %LocalLM{model: "local/base"})
  end

  defp example(question \\ "2+2?") do
    Imp.example(question: question, answer: "4")
    |> Imp.with_inputs(:question)
  end

  test "Imp.train completes BootstrapFinetune through a local trainer callback" do
    trainer = fn lm, rows, opts ->
      assert lm.model == "local/base"
      assert length(rows) == 1
      assert opts[:method] == :sft

      {:ok,
       TrainingJob.new(%{
         id: "local-sft-job",
         provider: :local,
         model: lm.model,
         status: :succeeded,
         result_model: "local/sft-trained"
       })}
    end

    optimizer =
      Imp.Optimizer.BootstrapFinetune.new(Imp.exact_match(:answer), trainer: trainer)

    assert {:ok,
            %TrainingResult{
              status: :completed,
              program: trained,
              metadata: %{method: :sft, job_count: 1}
            }} = Imp.train(program(), optimizer, Stream.map([example()], & &1))

    assert Imp.ProgramAccess.lm(trained).model == "local/sft-trained"
    assert {:ok, prediction} = Imp.call(trained, %{question: "2+2?"})
    assert Imp.get(prediction, :answer) == "4"
  end

  test "a pending BootstrapFinetune result can be checkpointed, refreshed, and rebound" do
    checkpoint =
      Path.join(
        System.tmp_dir!(),
        "imp-sft-consumer-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(checkpoint) end)

    status_transport = fn _url, _headers, _body, _opts ->
      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{status: "succeeded", result_model: "local/sft-resumed"})
       }}
    end

    trainer = fn lm, _rows, _opts ->
      {:ok,
       TrainingJob.new(%{
         id: "local-pending-sft",
         provider: :local,
         model: lm.model,
         status: :running,
         status_url: "local://training/local-pending-sft"
       })}
    end

    optimizer =
      Imp.Optimizer.BootstrapFinetune.new(Imp.exact_match(:answer), trainer: trainer)

    assert {:ok,
            %TrainingResult{
              status: :job_created,
              job: %TrainingJob{} = job,
              program: prepared
            }} = Imp.train(program(), optimizer, [example()])

    assert :ok = TrainingJob.save!(job, checkpoint)

    resumed = TrainingJob.load!(checkpoint, transport: status_transport)
    assert {:ok, completed} = TrainingJob.refresh(resumed)
    assert completed.status == :succeeded
    assert completed.result_model == "local/sft-resumed"

    assert {:ok, trained} = TrainingJob.rebind(completed, prepared)
    assert Imp.ProgramAccess.lm(trained).model == "local/sft-resumed"
  end

  test "Imp.train materializes GRPO train and validation streams for a local backend" do
    checkpoint =
      Path.join(
        System.tmp_dir!(),
        "imp-grpo-consumer-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(checkpoint) end)

    validation_path = checkpoint <> ".validation"
    on_exit(fn -> File.rm(validation_path) end)

    reward =
      Imp.Optimizer.GRPO.Callback.reward(StableGRPOCallbacks, :reward,
        id: "consumer-constant-reward-v1",
        config: %{"value" => 1.0}
      )

    validation =
      Imp.Optimizer.GRPO.Callback.validation(StableGRPOCallbacks, :validate,
        id: "consumer-validation-v1",
        config: %{"path" => validation_path}
      )

    optimizer =
      Imp.Optimizer.GRPO.new(
        reward,
        trainer: %LocalGRPOTrainer{owner: self()},
        validation_fn: validation,
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0,
        checkpoint_path: checkpoint
      )

    trainset = Stream.map([example()], & &1)
    validation = Stream.map([example("validation 2+2?")], & &1)

    assert {:ok,
            %TrainingResult{
              status: :completed,
              program: trained,
              metadata: %{method: :grpo}
            }} = Imp.train(program(), optimizer, trainset, validation: validation)

    assert_received {:grpo_started, %LocalLM{model: "local/base"}, start_opts}
    assert is_binary(start_opts[:dispatch_id])
    assert start_opts[:num_generations] == 2
    assert start_opts[:imp_reinforcement_contract]["optimizer"]["name"] == "grpo"

    assert_received {:grpo_groups, [%{group: group}]}
    assert length(group) == 2

    assert validation_path |> File.stream!() |> Enum.map(&Jason.decode!/1) == [
             %{"rows" => ["validation 2+2?"], "context" => %{"step" => -1, "final?" => false}},
             %{"rows" => ["validation 2+2?"], "context" => %{"step" => 0, "final?" => true}}
           ]

    assert Imp.ProgramAccess.lm(trained).model == "local/grpo-trained"
    assert Imp.ProgramAccess.get_metadata(trained, :training_artifact).method == :grpo
    refute File.exists?(checkpoint)
  end

  test "Imp.train rejects unknown GRPO invocation options instead of ignoring them" do
    optimizer =
      Imp.Optimizer.GRPO.new(
        fn _example, _prediction -> 1.0 end,
        trainer: %LocalGRPOTrainer{owner: self()},
        num_train_steps: 0
      )

    assert {:error, {:unsupported_optimizer_options, [:mystery]}} =
             Imp.train(program(), optimizer, [example()], mystery: :silently_ignored_before)

    refute_received {:grpo_started, _, _}
  end

  test "GRPO rejects the SFT-only callback shorthand at construction" do
    assert_raise ArgumentError,
                 ~r/trainer module or struct implementing the GRPO reinforcement lifecycle/,
                 fn ->
                   Imp.Optimizer.GRPO.new(fn _example -> 1.0 end,
                     trainer: fn _lm, _examples, _opts -> {:ok, :not_a_grpo_lifecycle} end
                   )
                 end
  end
end
