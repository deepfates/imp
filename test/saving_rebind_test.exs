defmodule SavingRebindTest do
  use ExUnit.Case, async: true

  test "loaded optimizer program graph can be rebound without ambient runtime state" do
    examples = [
      DSEx.example(question: "capital france", answer: "Paris")
      |> DSEx.with_inputs(:question)
    ]

    left =
      DSEx.Optimizer.KNNFewShot.new(1, examples)
      |> DSEx.Optimizer.KNNFewShot.compile(DSEx.predict("question -> answer"))

    right = DSEx.predict("question -> answer")
    reducer = fn predictions -> hd(predictions) end
    registry = DSEx.Saving.Registry.new(first_prediction: reducer)

    optimized =
      DSEx.Optimizer.Ensemble.new(reduce_fn: reducer, deterministic: true)
      |> DSEx.Optimizer.Ensemble.compile([left, right])

    artifact =
      Path.join(
        System.tmp_dir!(),
        "dsex-rebind-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(artifact) end)

    assert :ok = DSEx.save!(optimized, artifact, registry: registry)

    loaded =
      Task.async(fn -> DSEx.load!(artifact, registry: registry) end)
      |> Task.await()

    rebound = DSEx.with_lm(loaded, static_lm("fresh-runtime"))

    assert {:ok, prediction} = DSEx.call(rebound, %{question: "capital france"})
    assert DSEx.get(prediction, :answer) == "fresh-runtime"

    assert [
             %DSEx.Optimizer.KNNFewShot.Program{
               student: %DSEx.Predict.Predict{lm: %{module: DSEx.LM.Static}}
             },
             %DSEx.Predict.Predict{lm: %{module: DSEx.LM.Static}}
           ] = rebound.programs
  end

  test "rebind traverses saved callback wrappers around optimizer programs" do
    metric = fn _example, _prediction -> true end
    registry = DSEx.Saving.Registry.new(always_pass: metric)

    program =
      DSEx.predict("question -> answer")
      |> DSEx.Predict.BestOfN.new(metric, n: 1)

    loaded =
      program
      |> DSEx.dump(registry: registry)
      |> DSEx.load(registry: registry)
      |> DSEx.with_lm(static_lm("rebound"))

    assert {:ok, prediction} = DSEx.call(loaded, %{question: "works?"})
    assert DSEx.get(prediction, :answer) == "rebound"
  end

  defp static_lm(answer) do
    %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: answer} end]}
  end
end
