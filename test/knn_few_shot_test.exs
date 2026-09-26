defmodule KNNFewShotTest do
  use ExUnit.Case, async: true

  # Faithful DSPy 3.2.1 KNN / KNNFewShot semantics (dee-bivg):
  #
  #   * KNN (dspy/predict/knn.py): embed the trainset INPUT fields once at
  #     construction, embed the query at call time, rank by dot product, return
  #     the top-k in descending-score order.
  #   * KNNFewShot (dspy/teleprompt/knn_fewshot.py): on EVERY forward call,
  #     retrieve the k nearest neighbors and run a full metric/teacher-driven
  #     BootstrapFewShot compilation of the student over exactly those
  #     neighbors, then execute the compiled student.
  #
  # The stub embedder pins the exact rendered corpus text (`"question: ..."`,
  # upstream's `" | ".join(f"{key}: {value}") for input keys`): any rendering
  # drift raises FunctionClauseError instead of silently embedding different
  # bytes.

  defp stub_vectorizer do
    fn texts, _opts ->
      {:ok,
       Enum.map(texts, fn
         "question: alpha beta gamma" -> [1.0, 0.0]
         "question: delta epsilon" -> [0.0, 1.0]
         "question: alpha beta zeta" -> [0.1, 0.9]
       end)}
    end
  end

  defp trainset do
    [
      Imp.example(question: "alpha beta gamma", answer: "A") |> Imp.with_inputs(:question),
      Imp.example(question: "delta epsilon", answer: "B") |> Imp.with_inputs(:question)
    ]
  end

  test "KNN ranks neighbors by embedding dot product, not token overlap" do
    knn = Imp.Predict.KNN.new(1, trainset(), vectorizer: stub_vectorizer())

    # Hand-computed: query embeds to [0.1, 0.9].
    #   score(e1) = 1.0*0.1 + 0.0*0.9 = 0.1
    #   score(e2) = 0.0*0.1 + 1.0*0.9 = 0.9  -> e2 wins.
    assert [nearest] = Imp.Predict.KNN.call(knn, %{question: "alpha beta zeta"})
    assert Imp.Example.get(nearest, :answer) == "B"

    # Token overlap ranks the same query the other way: "alpha beta" is shared
    # with e1 and nothing with e2, so the answer above comes from the embeddings.
    query_terms = MapSet.new(~w(alpha beta zeta))

    overlap = fn text ->
      text |> String.split() |> MapSet.new() |> MapSet.intersection(query_terms) |> MapSet.size()
    end

    assert overlap.("alpha beta gamma") > overlap.("delta epsilon")
  end

  test "KNN returns top-k in descending score order" do
    knn = Imp.Predict.KNN.new(2, trainset(), vectorizer: stub_vectorizer())

    assert [first, second] = Imp.Predict.KNN.call(knn, %{question: "alpha beta zeta"})
    assert Imp.Example.get(first, :answer) == "B"
    assert Imp.Example.get(second, :answer) == "A"
  end

  test "KNN breaks score ties like a stable argsort (higher index first)" do
    tied = [
      Imp.example(question: "one", answer: "first") |> Imp.with_inputs(:question),
      Imp.example(question: "two", answer: "second") |> Imp.with_inputs(:question)
    ]

    vectorizer = fn texts, _opts -> {:ok, Enum.map(texts, fn _text -> [1.0] end)} end
    knn = Imp.Predict.KNN.new(2, tied, vectorizer: vectorizer)

    # argsort ascending (stable) = [0, 1]; last k reversed = [1, 0].
    assert ["second", "first"] =
             knn
             |> Imp.Predict.KNN.call(%{question: "anything"})
             |> Enum.map(&Imp.Example.get(&1, :answer))
  end

  test "KNNFewShot bootstraps metric-gated demos from per-call neighbors" do
    # Embedding space: q1 [1,0], q2 [0.9,0.1], q3 [0,1].
    vectorizer = fn texts, _opts ->
      {:ok,
       Enum.map(texts, fn
         "question: alpha alpha" -> [1.0, 0.0]
         "question: beta beta" -> [0.9, 0.1]
         "question: gamma" -> [0.0, 1.0]
         "question: alpha beta" -> [0.8, 0.2]
         "question: gamma gamma" -> [0.0, 1.0]
       end)}
    end

    trainset = [
      Imp.example(question: "alpha alpha", answer: "4") |> Imp.with_inputs(:question),
      Imp.example(question: "beta beta", answer: "5") |> Imp.with_inputs(:question),
      Imp.example(question: "gamma", answer: "4") |> Imp.with_inputs(:question)
    ]

    {:ok, calls} = Agent.start_link(fn -> [] end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Agent.update(calls, &(&1 ++ [messages]))
          %{answer: "4"}
        end
      )

    student = Imp.predict("question -> answer", lm: lm)

    # The metric only accepts teacher traces whose produced answer matches the
    # example label. The LM always answers "4", so "beta beta" (label "5") can
    # NEVER become a demo — under the old LabeledFewShot-attach semantics it
    # always would, since it is one of the k nearest neighbors.
    metric = fn example, prediction ->
      Imp.Prediction.get(prediction, :answer) == Imp.Example.get(example, :answer)
    end

    program =
      Imp.Optimizer.KNNFewShot.new(2, trainset,
        vectorizer: vectorizer,
        few_shot_bootstrap_args: [
          metric: metric,
          max_bootstrapped_demos: 2,
          max_labeled_demos: 0
        ]
      )
      |> Imp.Optimizer.KNNFewShot.compile(student)

    # Query 1: neighbors are q1 (0.8) and q2 (0.74); only q1 passes the metric.
    assert {:ok, prediction} =
             Imp.Optimizer.KNNFewShot.Program.call(program, %{question: "alpha beta"})

    assert Imp.Prediction.get(prediction, :answer) == "4"
    assert prediction.metadata.knn_few_shot.demo_count == 2

    final_prompt = calls |> Agent.get(& &1) |> List.last() |> prompt_text()
    assert final_prompt =~ "alpha alpha"

    refute final_prompt =~ "beta beta",
           "metric-rejected neighbor leaked into the prompt as a demo"

    refute final_prompt =~ "gamma"

    # Query 2: a different query retrieves different neighbors (q3 nearest) and
    # RE-bootstraps — per-call compilation, not a frozen demo set.
    Agent.update(calls, fn _calls -> [] end)

    assert {:ok, _prediction} =
             Imp.Optimizer.KNNFewShot.Program.call(program, %{question: "gamma gamma"})

    final_prompt = calls |> Agent.get(& &1) |> List.last() |> prompt_text()
    assert final_prompt =~ "[[ ## question ## ]]\ngamma\n"
    refute final_prompt =~ "alpha alpha"

    Agent.stop(calls)
  end

  test "KNNFewShot threads the teacher into the per-call bootstrap" do
    vectorizer = fn texts, _opts -> {:ok, Enum.map(texts, fn _text -> [1.0] end)} end

    trainset = [
      Imp.example(question: "alpha", answer: "teacher-made") |> Imp.with_inputs(:question)
    ]

    student_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "student-answer"} end)

    teacher_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "teacher-made"} end)

    student = Imp.predict("question -> answer", lm: student_lm)
    teacher = Imp.predict("question -> answer", lm: teacher_lm)

    metric = fn example, prediction ->
      Imp.Prediction.get(prediction, :answer) == Imp.Example.get(example, :answer)
    end

    program =
      Imp.Optimizer.KNNFewShot.new(1, trainset,
        vectorizer: vectorizer,
        few_shot_bootstrap_args: [metric: metric, max_labeled_demos: 0]
      )
      |> Imp.Optimizer.KNNFewShot.compile(student, teacher: teacher)

    # Only the teacher produces "teacher-made"; the accepted bootstrapped demo
    # exists exactly because the teacher (not the student) generated the trace.
    assert {:ok, prediction} =
             Imp.Optimizer.KNNFewShot.Program.call(program, %{question: "alpha"})

    assert prediction.metadata.knn_few_shot.demo_count == 1
    assert Imp.Prediction.get(prediction, :answer) == "student-answer"
  end

  defp prompt_text(messages), do: Enum.map_join(messages, "\n", & &1.content)
end
