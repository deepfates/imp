defmodule LabeledFewShotSelectionTest do
  use ExUnit.Case, async: true

  # Pins the selection semantics of Imp.Optimizer.LabeledFewShot (dee-o12k):
  # deterministic first-k, identical across repeated compiles and across the
  # direct and facade paths. Also pins that Imp.Datasets.split/2 shuffles with
  # a seeded RNG, so a split-then-compile pipeline cannot silently attach
  # different demo sets between runs.

  defp trainset(n) do
    for i <- 1..n do
      Imp.example(question: "q#{i}", answer: "a#{i}") |> Imp.with_inputs(:question)
    end
  end

  defp demos(program), do: Imp.ProgramAccess.predict(program).demos

  test "compile/3 with k < n attaches the first k examples, identically across repeated compiles" do
    trainset = trainset(10)
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 3)

    demo_sets =
      for _ <- 1..5 do
        optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, trainset) |> demos()
      end

    assert Enum.uniq(demo_sets) == [Enum.take(trainset, 3)]
  end

  test "Imp.optimize/3 facade selects the same first-k demos as direct compile" do
    trainset = trainset(10)
    program = Imp.predict("question -> answer")
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 3)

    facade_sets =
      for _ <- 1..5 do
        program |> Imp.optimize(optimizer, trainset) |> demos()
      end

    direct = optimizer |> Imp.Optimizer.LabeledFewShot.compile(program, trainset) |> demos()

    assert Enum.uniq(facade_sets) == [direct]
    assert direct == Enum.take(trainset, 3)
  end

  test "k equal to and greater than the trainset size attaches the whole trainset in order" do
    trainset = trainset(4)
    program = Imp.predict("question -> answer")

    for k <- [4, 99] do
      compiled =
        Imp.Optimizer.LabeledFewShot.new(k: k)
        |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)

      assert demos(compiled) == trainset
    end
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
