defmodule LabeledFewShotSelectionTest do
  use ExUnit.Case, async: true

  # Pins DSPy 3.2.1's semantic contract with Imp's explicit BEAM RNG: sampled
  # by default, ordered first-k on request, deterministic by seed, and one
  # advancing no-replacement draw per predictor.

  defmodule TwoPredictorProgram do
    defstruct [:first, :second, metadata: %{}]

    def optimizer_predictors(%__MODULE__{} = program),
      do: [first: program.first, second: program.second]

    def update_optimizer_predictor(%__MODULE__{} = program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(%__MODULE__{} = program, :second, update),
      do: %{program | second: update.(program.second)}
  end

  defp trainset(n) do
    for i <- 1..n do
      Imp.example(question: "q#{i}", answer: "a#{i}") |> Imp.with_inputs(:question)
    end
  end

  defp demos(program), do: Imp.ProgramAccess.predict(program).demos

  test "DSPy-compatible defaults sample k=16 deterministically" do
    assert %Imp.Optimizer.LabeledFewShot{k: 16, sample: true, seed: 0} =
             Imp.Optimizer.LabeledFewShot.new()

    trainset = trainset(20)
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.LabeledFewShot.new()

    selected = optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, trainset) |> demos()

    assert length(selected) == 16
    assert length(Enum.uniq(selected)) == 16
    assert MapSet.subset?(MapSet.new(selected), MapSet.new(trainset))
    refute selected == Enum.take(trainset, 16)

    assert selected ==
             optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, trainset) |> demos()
  end

  test "sampled compile is identical across repeated direct compiles" do
    trainset = trainset(10)
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 3)

    demo_sets =
      for _ <- 1..5 do
        optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, trainset) |> demos()
      end

    assert length(Enum.uniq(demo_sets)) == 1
    refute hd(demo_sets) == Enum.take(trainset, 3)
  end

  test "Imp.optimize/3 facade selects the same sampled demos as direct compile" do
    trainset = trainset(10)
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 3)

    facade_sets =
      for _ <- 1..5 do
        program |> Imp.optimize!(optimizer, trainset) |> demos()
      end

    direct = optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, trainset) |> demos()

    assert Enum.uniq(facade_sets) == [direct]
  end

  test "sample false implements DSPy's ordered first-k path" do
    trainset = trainset(10)
    program = Imp.predict("question -> answer")

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 3, sample: false)
      |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)

    assert demos(compiled) == Enum.take(trainset, 3)
  end

  test "ordered k equal to and greater than trainset size attaches the whole trainset" do
    trainset = trainset(4)
    program = Imp.predict("question -> answer")

    for k <- [4, 99] do
      compiled =
        Imp.Optimizer.LabeledFewShot.new(k: k, sample: false)
        |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)

      assert demos(compiled) == trainset
    end
  end

  test "seed selects a deterministic no-replacement sample" do
    trainset = trainset(20)
    program = Imp.predict("question -> answer")

    selected = fn seed ->
      Imp.Optimizer.LabeledFewShot.new(k: 6, seed: seed)
      |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)
      |> demos()
    end

    assert selected.(7) == selected.(7)
    refute selected.(7) == selected.(8)
  end

  test "multi-predictor programs receive separate draws from one RNG stream" do
    trainset = trainset(20)

    program = %TwoPredictorProgram{
      first: Imp.predict("question -> answer"),
      second: Imp.predict("question -> answer")
    }

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 5)
      |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)

    assert length(compiled.first.demos) == 5
    assert length(compiled.second.demos) == 5
    refute compiled.first.demos == compiled.second.demos

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.candidate_count == 10
    assert report.metadata.k_per_predictor == 5
    assert report.metadata.selected_assignment_count == 10
    assert report.metadata.selected_by_predictor == %{first: 5, second: 5}
  end

  test "an empty trainset clears stale demonstrations" do
    [existing | _] = trainset(2)

    program =
      "question -> answer"
      |> Imp.predict()
      |> Imp.with_demos([existing])

    compiled =
      Imp.Optimizer.LabeledFewShot.new()
      |> Imp.Optimizer.LabeledFewShot.compile(program, [])

    assert demos(compiled) == []
    assert Imp.Optimizer.Report.fetch(compiled).metadata.selected_assignment_count == 0
  end

  test "Datasets.split/2 default shuffle is seeded: repeated splits are identical" do
    examples = trainset(10)

    splits = for _ <- 1..5, do: Imp.Datasets.split(examples)

    assert length(Enum.uniq(splits)) == 1
  end

  test "Datasets.split/2 seed selects the permutation deterministically" do
    examples = trainset(10)

    assert Imp.Datasets.split(examples, seed: 7) == Imp.Datasets.split(examples, seed: 7)
    refute Imp.Datasets.split(examples, seed: 7) == Imp.Datasets.split(examples, seed: 8)
    assert Imp.Datasets.split(examples, shuffle: false) == Enum.split(examples, 8)
  end

  test "split-then-compile pipeline attaches the same demo set on every run" do
    examples = trainset(10)
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 3)

    demo_sets =
      for _ <- 1..5 do
        {train, _rest} = Imp.Datasets.split(examples)
        optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, train) |> demos()
      end

    assert length(Enum.uniq(demo_sets)) == 1
  end
end
