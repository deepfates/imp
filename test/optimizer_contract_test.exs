defmodule Imp.OptimizerContractTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{TrainingError, TrainingResult}

  defmodule CapturingProgramOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:owner]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :required},
        result: :program
      }

    @impl true
    def run(%__MODULE__{owner: owner}, program, opts) do
      send(owner, {:optimizer_options, opts})
      {:ok, program}
    end
  end

  defmodule InvalidCapabilities do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__, do: %{kind: :mystery}

    @impl true
    def run(_optimizer, program, _opts), do: {:ok, program}
  end

  defmodule InvalidResult do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(_optimizer, _program, _opts), do: {:ok, %{not: :a_program_struct}}
  end

  defmodule FlippingCapabilities do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__ do
      calls = Process.get({__MODULE__, :calls}, 0)
      Process.put({__MODULE__, :calls}, calls + 1)

      if calls == 0,
        do: %{
          kind: :program,
          datasets: %{trainset: :required, validation: :unsupported},
          result: :program
        },
        else: %{
          kind: :training,
          datasets: %{trainset: :required, validation: :unsupported},
          result: :training_result
        }
    end

    @impl true
    def run(_optimizer, program, _opts), do: {:ok, program}
  end

  defmodule RaisingCapabilities do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__, do: raise("capability probe exploded")

    @impl true
    def run(_optimizer, program, _opts), do: {:ok, program}
  end

  defmodule CustomTraining do
    @behaviour Imp.Optimizer
    defstruct [:result]

    @impl true
    def __optimizer__,
      do: %{
        kind: :training,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :training_result
      }

    @impl true
    def run(%__MODULE__{result: result}, _program, _opts), do: {:ok, result}
  end

  defmodule RunOnly do
    defstruct [:owner]

    def run(%__MODULE__{owner: owner}, program, _opts) do
      send(owner, :forged_optimizer_executed)
      {:ok, program}
    end
  end

  defmodule MalformedWorkflow do
    @behaviour Imp.Optimizer
    defstruct []

    defmodule Result do
      defstruct [:value]
    end

    @impl true
    def __optimizer__,
      do: %{
        kind: :workflow,
        datasets: %{trainset: :required},
        result: {:workflow_result, Result}
      }

    @impl true
    def run(%__MODULE__{}, _program, _opts), do: {:ok, %{not: :the_declared_result}}
  end

  @canonical_modules [
    Imp.Optimizer.LabeledFewShot,
    Imp.Optimizer.BootstrapFewShot,
    Imp.Optimizer.RandomSearch,
    Imp.Optimizer.COPRO,
    Imp.Optimizer.MIPROv2,
    Imp.Optimizer.SIMBA,
    Imp.Optimizer.InferRules,
    Imp.Optimizer.SignatureOptimizer,
    Imp.Optimizer.GEPA,
    Imp.Optimizer.Avatar,
    Imp.Optimizer.BetterTogether,
    Imp.Optimizer.BootstrapFinetune,
    Imp.Optimizer.GRPO,
    Imp.Optimizer.Ensemble,
    Imp.Optimizer.KNNFewShot,
    Imp.Optimizer.Playbook
  ]

  test "every executable optimizer family declares one canonical contract" do
    for module <- @canonical_modules do
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, :__optimizer__, 0)
      assert function_exported?(module, :run, 3)

      assert %{
               kind: kind,
               datasets: datasets,
               result: result
             } = module.__optimizer__()

      assert kind in [:program, :training, :constructor, :workflow]
      assert map_size(datasets) > 0

      assert Enum.all?(datasets, fn {name, requirement} ->
               is_atom(name) and requirement in [:required, :optional, :unsupported]
             end)

      assert result in [
               :program,
               :training_result,
               :constructed_program,
               {:workflow_result, Imp.Optimizer.Playbook.Result}
             ]
    end

    assert Imp.Optimizer.Playbook.__optimizer__().datasets == %{
             trainset: :required,
             promotionset: :required,
             auditset: :required,
             validation: :unsupported
           }
  end

  test "facade forwards named datasets and invocation options without arity inference" do
    program = Imp.predict("question -> answer")
    trainset = [Imp.example(question: "train", answer: "a")]
    validation = [Imp.example(question: "validation", answer: "a")]
    optimizer = %CapturingProgramOptimizer{owner: self()}

    assert ^program =
             Imp.optimize(program, optimizer, trainset, validation, checkpoint_fn: :checkpoint)

    assert_receive {:optimizer_options, opts}
    assert opts[:trainset] == trainset
    assert opts[:validation] == validation
    assert opts[:checkpoint_fn] == :checkpoint
  end

  test "MIPROv2 cannot receive a trainset as invocation options through optimize/3" do
    metric = Imp.exact_match(:answer)
    optimizer = Imp.Optimizer.MIPROv2.new(metric)

    assert_raise ArgumentError, ~r/requires a validation set/, fn ->
      Imp.optimize(Imp.predict("question -> answer"), optimizer, [])
    end
  end

  test "dataset contracts reject nil and scalar values while admitting empty and streaming splits" do
    program = Imp.predict("question -> answer")
    optimizer = %CapturingProgramOptimizer{owner: self()}

    assert {:error, {:missing_dataset, :validation}} =
             Imp.Optimizer.run(optimizer, program, trainset: [])

    assert {:error, {:invalid_dataset, :trainset, nil}} =
             Imp.Optimizer.run(optimizer, program, trainset: nil, validation: [])

    assert {:error, {:invalid_dataset, :validation, :not_a_dataset}} =
             Imp.Optimizer.run(optimizer, program,
               trainset: [],
               validation: :not_a_dataset
             )

    assert {:ok, ^program} =
             Imp.Optimizer.run(optimizer, program, trainset: [], validation: [])

    assert_receive {:optimizer_options, empty_opts}
    assert empty_opts[:trainset] == []

    train_stream = Stream.map([1], & &1)
    validation_stream = Stream.map([2], & &1)

    assert {:ok, ^program} =
             Imp.Optimizer.run(optimizer, program,
               trainset: train_stream,
               validation: validation_stream
             )

    assert_receive {:optimizer_options, stream_opts}
    assert stream_opts[:trainset] == train_stream
    assert stream_opts[:validation] == validation_stream
  end

  test "GRPO cannot receive a devset in its compile options position" do
    optimizer = Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end)

    assert_raise ArgumentError, ~r/training optimizer; use Imp\.train\/4/, fn ->
      Imp.optimize(Imp.predict("question -> answer"), optimizer, [], [])
    end
  end

  test "training and program optimization have distinct public result contracts" do
    metric = Imp.exact_match(:answer)
    program = Imp.predict("question -> answer")
    trainer = Imp.Optimizer.BootstrapFinetune.new(metric)

    assert {:error, {:training_not_started, :trainer_required, %Imp.Predict.Predict{} = compiled}} =
             Imp.train(program, trainer, [])

    assert Imp.Optimizer.Report.fetch(compiled).optimizer == :bootstrap_finetune

    assert {:error, {:optimizer_kind_mismatch, :training, :program}} =
             Imp.train(program, Imp.Optimizer.LabeledFewShot.new(), [])
  end

  test "facade rejects every non-keyword invocation option shape consistently" do
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.SIMBA.new(Imp.exact_match(:answer))

    for options <- [%{}, {:bad, :options}, [:not_keyword]] do
      assert_raise ArgumentError, ~r/Imp\.optimize\/5 expects keyword/, fn ->
        Imp.optimize(program, optimizer, [], [], options)
      end

      assert_raise ArgumentError, ~r/Imp\.train\/4 expects keyword/, fn ->
        Imp.train(program, optimizer, [], options)
      end
    end
  end

  test "constructors are explicit and cannot masquerade as dataset optimizers" do
    program = Imp.predict("question -> answer")
    ensemble = Imp.Optimizer.Ensemble.new(deterministic: true)

    assert {:ok, %Imp.Optimizer.Ensemble.Program{programs: [^program]}} =
             Imp.Optimizer.run(ensemble, [program], [])

    assert_raise ArgumentError, ~r/kind :constructor/, fn ->
      Imp.optimize(program, ensemble, [])
    end
  end

  test "invalid capability and result declarations fail closed" do
    program = Imp.predict("question -> answer")

    assert {:error, {:invalid_optimizer_capabilities, %{kind: :mystery}}} =
             Imp.Optimizer.capabilities(%InvalidCapabilities{})

    assert {:error, {:invalid_optimizer_program, %{not: :a_program_struct}}} =
             Imp.Optimizer.run(%InvalidResult{}, program, trainset: [])
  end

  test "facade resolves stateful capabilities exactly once" do
    key = {FlippingCapabilities, :calls}
    Process.delete(key)
    program = Imp.predict("question -> answer")

    assert ^program = Imp.optimize(program, %FlippingCapabilities{}, [])
    assert Process.get(key) == 1
  end

  test "composed execution resolves capabilities exactly once" do
    key = {FlippingCapabilities, :calls}
    Process.delete(key)
    program = Imp.predict("question -> answer")

    assert {:ok, %{kind: :program}, ^program} =
             Imp.Optimizer.run_with_datasets(
               %FlippingCapabilities{},
               program,
               %{trainset: []},
               [:program, :training]
             )

    assert Process.get(key) == 1
  end

  test "caller-supplied capability maps cannot execute a run-only struct" do
    forged = %{
      kind: :program,
      datasets: %{trainset: :required},
      result: :program
    }

    assert {:error, {:not_an_optimizer, RunOnly}} =
             Imp.Optimizer.run(
               %RunOnly{owner: self()},
               Imp.predict("question -> answer"),
               [trainset: []],
               forged
             )

    refute_receive :forged_optimizer_executed
  end

  test "workflow results must match their declared result module" do
    assert {:error,
            {:invalid_workflow_result, MalformedWorkflow.Result, %{not: :the_declared_result}}} =
             Imp.Optimizer.run(
               %MalformedWorkflow{},
               Imp.predict("question -> answer"),
               trainset: []
             )
  end

  test "BootstrapFinetune distinguishes pending, completed, and failed jobs" do
    program = Imp.predict("question -> answer", lm: Imp.req_llm("openai:gpt-base"))
    metric = Imp.exact_match(:answer)

    trainer_for = fn attrs ->
      fn _lm, _examples, _opts -> {:ok, Imp.Clients.TrainingJob.new(attrs)} end
    end

    pending =
      Imp.Optimizer.BootstrapFinetune.new(metric,
        trainer: trainer_for.(%{id: "pending", status: :running})
      )

    assert {:ok, %TrainingResult{status: :job_created, job: %{id: "pending"}}} =
             Imp.train(program, pending, [])

    completed =
      Imp.Optimizer.BootstrapFinetune.new(metric,
        trainer:
          trainer_for.(%{
            id: "completed",
            provider: :openai,
            model: "openai:gpt-base",
            status: :succeeded,
            result_model: "ft:gpt-completed"
          })
      )

    assert {:ok, %TrainingResult{status: :completed, program: rebound}} =
             Imp.train(program, completed, [])

    assert Imp.ProgramAccess.lm(rebound).model == "openai:ft:gpt-completed"

    failed =
      Imp.Optimizer.BootstrapFinetune.new(metric,
        trainer: trainer_for.(%{id: "failed", status: :failed})
      )

    assert {:error,
            %TrainingError{
              reason: {:training_failed, :failed, %{}},
              program: failed_program,
              status: :failed
            }} = Imp.train(program, failed, [])

    assert Imp.Optimizer.Report.fetch(failed_program).metadata.status == :error
  end

  test "capability callback failures are normalized at the optimizer boundary" do
    assert {:error,
            {:optimizer_capabilities_failed, RaisingCapabilities, "capability probe exploded"}} =
             Imp.Optimizer.capabilities(%RaisingCapabilities{})

    assert_raise ArgumentError, ~r/capability probe exploded/, fn ->
      Imp.optimize(Imp.predict("question -> answer"), %RaisingCapabilities{}, [])
    end
  end

  test "training result is an explicit lifecycle value" do
    result = %TrainingResult{program: Imp.predict("question -> answer"), status: :completed}
    assert result.status == :completed
    assert result.job == nil
    assert result.metadata == %{}
  end

  test "malformed training lifecycle results fail closed" do
    program = Imp.predict("question -> answer")

    invalid_status = %TrainingResult{
      program: program,
      job: :job,
      status: :unknown,
      metadata: %{}
    }

    assert {:error, {:invalid_training_status, :unknown}} =
             Imp.Optimizer.run(%CustomTraining{result: invalid_status}, program, trainset: [])

    missing_job = %TrainingResult{program: program, status: :job_created, metadata: %{}}

    assert {:error, :training_job_required} =
             Imp.Optimizer.run(%CustomTraining{result: missing_job}, program, trainset: [])

    invalid_metadata = %TrainingResult{program: program, status: :completed, metadata: []}

    assert {:error, {:invalid_training_metadata, []}} =
             Imp.Optimizer.run(%CustomTraining{result: invalid_metadata}, program, trainset: [])
  end
end
