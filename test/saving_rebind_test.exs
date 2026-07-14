defmodule SavingRebindTest do
  use ExUnit.Case, async: true

  test "loaded optimizer program graph can be rebound without ambient runtime state" do
    examples = [
      Imp.example(question: "capital france", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    left =
      Imp.Optimizer.KNNFewShot.new(1, examples)
      |> Imp.Optimizer.KNNFewShot.compile(Imp.predict("question -> answer"))

    right = Imp.predict("question -> answer")
    reducer = fn predictions -> hd(predictions) end
    registry = Imp.Saving.Registry.new(first_prediction: reducer)

    optimized =
      Imp.Optimizer.Ensemble.new(reduce_fn: reducer, deterministic: true)
      |> Imp.Optimizer.Ensemble.compile([left, right])

    artifact =
      Path.join(
        System.tmp_dir!(),
        "imp-rebind-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(artifact) end)

    assert :ok = Imp.save!(optimized, artifact, registry: registry)

    loaded =
      Task.async(fn -> Imp.load!(artifact, registry: registry) end)
      |> Task.await()

    rebound = Imp.with_lm(loaded, static_lm("fresh-runtime"))

    assert {:ok, prediction} = Imp.call(rebound, %{question: "capital france"})
    assert Imp.get(prediction, :answer) == "fresh-runtime"

    assert [
             %Imp.Optimizer.KNNFewShot.Program{
               student: %Imp.Predict.Predict{lm: %{module: Imp.LM.Static}}
             },
             %Imp.Predict.Predict{lm: %{module: Imp.LM.Static}}
           ] = rebound.programs
  end

  test "rebind traverses saved callback wrappers around optimizer programs" do
    metric = fn _example, _prediction -> true end
    registry = Imp.Saving.Registry.new(always_pass: metric)

    program =
      Imp.predict("question -> answer")
      |> Imp.Predict.BestOfN.new(metric, n: 1)

    loaded =
      program
      |> Imp.dump(registry: registry)
      |> Imp.load(registry: registry)
      |> Imp.with_lm(static_lm("rebound"))

    assert {:ok, prediction} = Imp.call(loaded, %{question: "works?"})
    assert Imp.get(prediction, :answer) == "rebound"
  end

  defp static_lm(answer) do
    %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: answer} end]}
  end
end
