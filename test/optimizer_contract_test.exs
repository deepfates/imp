defmodule DSEx.OptimizerContractTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.TrainingResult

  defmodule CapturingProgramOptimizer do
    @behaviour DSEx.Optimizer
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
    @behaviour DSEx.Optimizer
    defstruct []

    @impl true
    def __optimizer__, do: %{kind: :mystery}

    @impl true
    def run(_optimizer, program, _opts), do: {:ok, program}
  end

  defmodule InvalidResult do
    @behaviour DSEx.Optimizer
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
    @behaviour DSEx.Optimizer
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
    @behaviour DSEx.Optimizer
    defstruct []

    @impl true
    def __optimizer__, do: raise("capability probe exploded")

    @impl true
    def run(_optimizer, program, _opts), do: {:ok, program}
  end

  defmodule CustomTraining do
    @behaviour DSEx.Optimizer
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

  @canonical_modules [
    DSEx.Optimizer.LabeledFewShot,
    DSEx.Optimizer.BootstrapFewShot,
    DSEx.Optimizer.RandomSearch,
    DSEx.Optimizer.COPRO,
    DSEx.Optimizer.MIPROv2,
    DSEx.Optimizer.SIMBA,
    DSEx.Optimizer.InferRules,
    DSEx.Optimizer.SignatureOptimizer,
    DSEx.Optimizer.GEPA,
    DSEx.Optimizer.Avatar,
    DSEx.Optimizer.BetterTogether,
    DSEx.Optimizer.BootstrapFinetune,
    DSEx.Optimizer.GRPO,
    DSEx.Optimizer.Ensemble,
    DSEx.Optimizer.KNNFewShot,
    DSEx.Optimizer.Playbook
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

      assert result in [:program, :training_result, :constructed_program, :workflow_result]
    end

    assert DSEx.Optimizer.Playbook.__optimizer__().datasets == %{
             trainset: :required,
             promotionset: :required,
             auditset: :required,
             validation: :unsupported
           }
  end

  test "facade forwards named datasets and invocation options without arity inference" do
    program = DSEx.predict("question -> answer")
    trainset = [DSEx.example(question: "train", answer: "a")]
    validation = [DSEx.example(question: "validation", answer: "a")]
    optimizer = %CapturingProgramOptimizer{owner: self()}

    assert ^program =
             DSEx.optimize(program, optimizer, trainset, validation, checkpoint_fn: :checkpoint)

    assert_receive {:optimizer_options, opts}
    assert opts[:trainset] == trainset
    assert opts[:validation] == validation
    assert opts[:checkpoint_fn] == :checkpoint
  end

  test "MIPROv2 cannot receive a trainset as invocation options through optimize/3" do
    metric = DSEx.exact_match(:answer)
    optimizer = DSEx.Optimizer.MIPROv2.new(metric)

    assert_raise ArgumentError, ~r/requires a validation set/, fn ->
      DSEx.optimize(DSEx.predict("question -> answer"), optimizer, [])
    end
  end

  test "dataset contracts reject nil and scalar values while admitting empty and streaming splits" do
    program = DSEx.predict("question -> answer")
    optimizer = %CapturingProgramOptimizer{owner: self()}

    assert {:error, {:missing_dataset, :validation}} =
             DSEx.Optimizer.run(optimizer, program, trainset: [])

    assert {:error, {:invalid_dataset, :trainset, nil}} =
             DSEx.Optimizer.run(optimizer, program, trainset: nil, validation: [])

    assert {:error, {:invalid_dataset, :validation, :not_a_dataset}} =
             DSEx.Optimizer.run(optimizer, program,
               trainset: [],
               validation: :not_a_dataset
             )

    assert {:ok, ^program} =
             DSEx.Optimizer.run(optimizer, program, trainset: [], validation: [])

    assert_receive {:optimizer_options, empty_opts}
    assert empty_opts[:trainset] == []

    train_stream = Stream.map([1], & &1)
    validation_stream = Stream.map([2], & &1)

    assert {:ok, ^program} =
             DSEx.Optimizer.run(optimizer, program,
               trainset: train_stream,
               validation: validation_stream
             )

    assert_receive {:optimizer_options, stream_opts}
    assert stream_opts[:trainset] == train_stream
    assert stream_opts[:validation] == validation_stream
  end

  test "GRPO cannot receive a devset in its compile options position" do
    optimizer = DSEx.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end)

    assert_raise ArgumentError, ~r/training optimizer; use DSEx\.train\/4/, fn ->
      DSEx.optimize(DSEx.predict("question -> answer"), optimizer, [], [])
    end
  end

  test "training and program optimization have distinct public result contracts" do
    metric = DSEx.exact_match(:answer)
    program = DSEx.predict("question -> answer")
    trainer = DSEx.Optimizer.BootstrapFinetune.new(metric)

    assert {:error,
            {:training_not_started, :trainer_required, %DSEx.Predict.Predict{} = compiled}} =
             DSEx.train(program, trainer, [])

    assert DSEx.Optimizer.Report.fetch(compiled).optimizer == :bootstrap_few_shot

    assert {:error, {:optimizer_kind_mismatch, :training, :program}} =
             DSEx.train(program, DSEx.Optimizer.LabeledFewShot.new(), [])
  end

  test "facade rejects every non-keyword invocation option shape consistently" do
    program = DSEx.predict("question -> answer")
    optimizer = DSEx.Optimizer.SIMBA.new(DSEx.exact_match(:answer))

    for options <- [%{}, {:bad, :options}, [:not_keyword]] do
      assert_raise ArgumentError, ~r/DSEx\.optimize\/5 expects keyword/, fn ->
        DSEx.optimize(program, optimizer, [], [], options)
      end

      assert_raise ArgumentError, ~r/DSEx\.train\/4 expects keyword/, fn ->
        DSEx.train(program, optimizer, [], options)
      end
    end
  end

  test "constructors are explicit and cannot masquerade as dataset optimizers" do
    program = DSEx.predict("question -> answer")
    ensemble = DSEx.Optimizer.Ensemble.new(deterministic: true)

    assert {:ok, %DSEx.Optimizer.Ensemble.Program{programs: [^program]}} =
             DSEx.Optimizer.run(ensemble, [program], [])

    assert_raise ArgumentError, ~r/kind :constructor/, fn ->
      DSEx.optimize(program, ensemble, [])
    end
  end

  test "invalid capability and result declarations fail closed" do
    program = DSEx.predict("question -> answer")

    assert {:error, {:invalid_optimizer_capabilities, %{kind: :mystery}}} =
             DSEx.Optimizer.capabilities(%InvalidCapabilities{})

    assert {:error, {:invalid_optimizer_program, %{not: :a_program_struct}}} =
             DSEx.Optimizer.run(%InvalidResult{}, program, trainset: [])
  end

  test "facade resolves stateful capabilities exactly once" do
    key = {FlippingCapabilities, :calls}
    Process.delete(key)
    program = DSEx.predict("question -> answer")

    assert ^program = DSEx.optimize(program, %FlippingCapabilities{}, [])
    assert Process.get(key) == 1
  end

  test "capability callback failures are normalized at the optimizer boundary" do
    assert {:error,
            {:optimizer_capabilities_failed, RaisingCapabilities, "capability probe exploded"}} =
             DSEx.Optimizer.capabilities(%RaisingCapabilities{})

    assert_raise ArgumentError, ~r/capability probe exploded/, fn ->
      DSEx.optimize(DSEx.predict("question -> answer"), %RaisingCapabilities{}, [])
    end
  end

  test "training result is an explicit lifecycle value" do
    result = %TrainingResult{program: DSEx.predict("question -> answer"), status: :completed}
    assert result.status == :completed
    assert result.job == nil
    assert result.metadata == %{}
  end

  test "malformed training lifecycle results fail closed" do
    program = DSEx.predict("question -> answer")

    invalid_status = %TrainingResult{
      program: program,
      job: :job,
      status: :unknown,
      metadata: %{}
    }

    assert {:error, {:invalid_training_status, :unknown}} =
             DSEx.Optimizer.run(%CustomTraining{result: invalid_status}, program, trainset: [])

    missing_job = %TrainingResult{program: program, status: :job_created, metadata: %{}}

    assert {:error, :training_job_required} =
             DSEx.Optimizer.run(%CustomTraining{result: missing_job}, program, trainset: [])

    invalid_metadata = %TrainingResult{program: program, status: :completed, metadata: []}

    assert {:error, {:invalid_training_metadata, []}} =
             DSEx.Optimizer.run(%CustomTraining{result: invalid_metadata}, program, trainset: [])
  end
end
