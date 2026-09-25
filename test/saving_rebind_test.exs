defmodule SavingRebindTest do
  use ExUnit.Case, async: true

  test "loaded optimizer program graph can be rebound without ambient runtime state" do
    examples = [
      Imp.example(question: "capital france", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    left =
      Imp.Optimizer.KNNFewShot.new(1, examples, vectorizer: Imp.Embeddings.BagOfWords)
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
      Task.async(fn -> Imp.read!(artifact, registry: registry) end)
      |> Task.await()

    rebound = Imp.with_lm(loaded, static_lm("fresh-runtime"))

    assert {:ok, prediction} = Imp.call(rebound, %{question: "capital france"})
    assert Imp.get(prediction, :answer) == "fresh-runtime"

    assert [
             %Imp.Optimizer.KNNFewShot.Program{
               student: %Imp.Predict{lm: %Imp.LM.Static{}}
             },
             %Imp.Predict{lm: %Imp.LM.Static{}}
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
      |> Imp.load!(registry: registry)
      |> Imp.with_lm(static_lm("rebound"))

    assert {:ok, prediction} = Imp.call(loaded, %{question: "works?"})
    assert Imp.get(prediction, :answer) == "rebound"
  end

  test "rebind replaces both the KNN student and its per-call bootstrap teacher" do
    test_pid = self()

    stale_lm =
      static_lm(fn _messages, _opts ->
        send(test_pid, :stale_lm_called)
        %{answer: "stale"}
      end)

    replacement_lm = static_lm("replacement")

    examples = [
      Imp.example(question: "capital france", answer: "replacement")
      |> Imp.with_inputs(:question)
    ]

    metric = fn example, prediction ->
      Imp.Example.get(example, :answer) == Imp.Prediction.get(prediction, :answer)
    end

    program =
      Imp.Optimizer.KNNFewShot.new(1, examples,
        vectorizer: Imp.Embeddings.BagOfWords,
        few_shot_bootstrap_args: [metric: metric, max_labeled_demos: 0]
      )
      |> Imp.Optimizer.KNNFewShot.compile(
        Imp.predict("question -> answer", lm: stale_lm),
        teacher: Imp.predict("question -> answer", lm: stale_lm)
      )
      |> Imp.with_lm(replacement_lm)

    assert Imp.ProgramAccess.lm(program) == replacement_lm
    assert Imp.ProgramAccess.lm(program.teacher) == replacement_lm
    assert {:ok, prediction} = Imp.call(program, %{question: "capital france"})
    assert Imp.get(prediction, :answer) == "replacement"
    refute_received :stale_lm_called
  end

  test "rebind reaches every active CompleteAndGrounded judge" do
    test_pid = self()

    stale_lm =
      static_lm(fn _messages, _opts ->
        send(test_pid, :stale_lm_called)
        %{completeness: 0.0, groundedness: 0.0}
      end)

    replacement_lm =
      static_lm(fn _messages, _opts ->
        %{
          reasoning: "checked",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          system_response_claims: "Paris",
          discussion: "supported",
          completeness: 1.0,
          groundedness: 1.0
        }
      end)

    evaluator =
      Imp.Evaluate.CompleteAndGrounded.new(lm: stale_lm)
      |> Imp.with_lm(replacement_lm)

    assert Imp.ProgramAccess.lm(evaluator.completeness) == replacement_lm
    assert Imp.ProgramAccess.lm(evaluator.groundedness) == replacement_lm

    assert {:ok, prediction} =
             Imp.call(evaluator, %{
               question: "Where?",
               ground_truth: "Paris",
               system_response: "Paris",
               retrieved_context: "Paris is in France"
             })

    assert Imp.get(prediction, :score) == 1.0
    refute_received :stale_lm_called
  end

  test "rebind and demo attachment traverse playbook wrappers" do
    demo = Imp.example(question: "capital france", answer: "Paris") |> Imp.with_inputs(:question)
    replacement_lm = static_lm("rebound")

    wrapper =
      Imp.predict("question -> answer", lm: static_lm("stale"))
      |> Imp.with_playbook(Imp.Playbook.new(id: "rebind"))
      |> Imp.with_demos([demo])
      |> Imp.with_lm(replacement_lm)

    assert [%{predictor: %{demos: [^demo], lm: replacement}}] =
             Imp.ProgramParameters.predictors(wrapper)

    assert replacement == replacement_lm
    assert {:ok, prediction} = Imp.call(wrapper, %{question: "capital france"})
    assert Imp.get(prediction, :answer) == "rebound"
  end

  defp static_lm(answer) do
    handler =
      if is_function(answer, 2),
        do: answer,
        else: fn _messages, _opts -> %{answer: answer} end

    Imp.LM.Static.new(handler: handler)
  end
end
