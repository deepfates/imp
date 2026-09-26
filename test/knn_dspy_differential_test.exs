defmodule KNNDspyDifferentialTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  # Differential proof for dee-bivg: Imp's KNN / KNNFewShot ports produce the
  # SAME neighbor selections and the SAME metric-gated bootstrapped demo sets
  # as real DSPy 3.2.1, driven by one deterministic marker-count embedder both
  # languages implement identically (scripts/dspy_knn_differential_runner.py).

  @python "tmp/dspy-parity-venv/bin/python"
  @runner "scripts/dspy_knn_differential_runner.py"

  @markers ["alpha", "beta", "gamma", "delta"]
  @trainset [
    {"alpha alpha alpha", "4"},
    {"beta beta", "5"},
    {"gamma", "4"}
  ]
  @queries ["alpha beta", "gamma beta"]

  defp embed_text(text) do
    Enum.map(@markers, fn marker ->
      (text |> String.split(marker) |> length()) - 1.0
    end)
  end

  defp vectorizer, do: fn texts, _opts -> {:ok, Enum.map(texts, &embed_text/1)} end

  defp trainset do
    Enum.map(@trainset, fn {question, answer} ->
      Imp.example(question: question, answer: answer) |> Imp.with_inputs(:question)
    end)
  end

  test "Imp KNN and KNNFewShot match real DSPy 3.2.1 selections and demo gating" do
    unless File.exists?(@python) do
      flunk("missing #{@python}; run the documented DSPy parity environment setup")
    end

    {output, 0} = System.cmd(Path.expand(@python), [@runner])
    dspy = Jason.decode!(output)
    assert dspy["dspy_version"] == "3.2.1"

    # --- KNN neighbor selection, per query, in order -----------------------
    knn = Imp.Predict.KNN.new(2, trainset(), vectorizer: vectorizer())

    imp_selections =
      Map.new(@queries, fn query ->
        {query,
         knn
         |> Imp.Predict.KNN.call(%{question: query})
         |> Enum.map(&Imp.Example.get(&1, :question))}
      end)

    assert imp_selections == dspy["knn_selections"]

    # Not just x == x: the shared expectation is hand-computed from the marker
    # embedding (dot products 3 > 2 > 0 and 2 > 1 > 0).
    assert imp_selections == %{
             "alpha beta" => ["alpha alpha alpha", "beta beta"],
             "gamma beta" => ["beta beta", "gamma"]
           }

    # --- KNNFewShot: metric-gated bootstrapped demos per call --------------
    {:ok, calls} = Agent.start_link(fn -> [] end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Agent.update(calls, &(&1 ++ [messages]))
          %{answer: "4"}
        end
      )

    metric = fn example, prediction ->
      Imp.Prediction.get(prediction, :answer) == Imp.Example.get(example, :answer)
    end

    program =
      Imp.Optimizer.KNNFewShot.new(2, trainset(),
        vectorizer: vectorizer(),
        few_shot_bootstrap_args: [
          metric: metric,
          max_bootstrapped_demos: 2,
          max_labeled_demos: 0
        ]
      )
      |> Imp.Optimizer.KNNFewShot.compile(Imp.predict("question -> answer", lm: lm))

    imp_presence =
      Map.new(@queries, fn query ->
        Agent.update(calls, fn _calls -> [] end)

        assert {:ok, _prediction} =
                 Imp.Optimizer.KNNFewShot.Program.call(program, %{question: query})

        final_messages = calls |> Agent.get(& &1) |> List.last()

        demo_user_contents =
          final_messages
          |> Enum.drop(-1)
          |> Enum.filter(&(&1.role == :user))
          |> Enum.map(& &1.content)

        {query,
         Map.new(@trainset, fn {question, _answer} ->
           {question, Enum.any?(demo_user_contents, &String.contains?(&1, question))}
         end)}
      end)

    Agent.stop(calls)

    assert imp_presence == dspy["knn_few_shot_demo_presence"]

    # Hand-computed expectation: the always-"4" LM means only label-"4"
    # neighbors survive the metric; "beta beta" (label "5") never becomes a
    # demo even though it is retrieved for BOTH queries.
    assert imp_presence == %{
             "alpha beta" => %{
               "alpha alpha alpha" => true,
               "beta beta" => false,
               "gamma" => false
             },
             "gamma beta" => %{
               "alpha alpha alpha" => false,
               "beta beta" => false,
               "gamma" => true
             }
           }
  end
end
