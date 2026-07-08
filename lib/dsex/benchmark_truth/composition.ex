defmodule DSEx.BenchmarkTruth.Composition do
  @moduledoc false

  defmodule HintProgram do
    @moduledoc false
    @behaviour DSEx.Module

    defstruct [:bad_answer, :fixed_answer]

    @impl true
    def call(%__MODULE__{} = program, inputs) do
      answer =
        if Map.get(Map.new(inputs), :hint_),
          do: program.fixed_answer,
          else: program.bad_answer

      {:ok, DSEx.Prediction.new(answer: answer)}
    end
  end

  defmodule AnswerProgram do
    @moduledoc false
    @behaviour DSEx.Module

    defstruct [:answer, fail?: false]

    @impl true
    def call(%__MODULE__{fail?: true}, _inputs), do: raise("composition child failed")

    def call(%__MODULE__{} = program, _inputs),
      do: {:ok, DSEx.Prediction.new(answer: program.answer)}
  end

  defmodule QuestionProgram do
    @moduledoc false
    @behaviour DSEx.Module

    defstruct []

    @impl true
    def call(%__MODULE__{}, inputs) do
      question = Map.get(Map.new(inputs), :question, "")

      cond do
        question =~ "fail" -> raise("parallel branch failed")
        question =~ "France" -> {:ok, DSEx.Prediction.new(answer: "Paris")}
        question =~ "Germany" -> {:ok, DSEx.Prediction.new(answer: "Berlin")}
        true -> {:ok, DSEx.Prediction.new(answer: "unknown")}
      end
    end
  end

  def run(examples, opts \\ []) do
    examples = Enum.map(examples, &example_map/1)
    max_concurrency = Keyword.get(opts, :max_concurrency, 2)

    scenarios = [
      best_of_n(examples),
      refine(examples),
      multi_chain_comparison(examples),
      ensemble(examples),
      knn(examples),
      parallel(examples, max_concurrency)
    ]

    %{
      "task" => "composition_orchestration",
      "score" => average(Enum.map(scenarios, & &1["score"])),
      "aggregate_metrics" => %{
        "task_metric" => "composition_orchestration_report",
        "scenarios" => length(scenarios),
        "passed" => Enum.count(scenarios, &(&1["passed"] == true)),
        "failed_child_isolation" =>
          Enum.all?(
            Enum.filter(scenarios, &Map.has_key?(&1, "failed_child_isolation")),
            & &1["failed_child_isolation"]
          ),
        "max_concurrency" => max_concurrency
      },
      "scenarios" => scenarios
    }
  end

  defp best_of_n([example | _examples]) do
    program = %AnswerProgram{answer: example["answer"]}
    metric = fn _example, prediction -> answer_score(prediction, example["answer"]) end
    baseline = call_answer(%AnswerProgram{answer: "wrong"}, example)
    {:ok, _preflight} = DSEx.Module.call(program, example)
    best = DSEx.Predict.BestOfN.new(program, metric, n: 3)

    {:ok, prediction} = DSEx.Predict.BestOfN.call(best, example)

    score = answer_score(prediction, example["answer"])

    %{
      "name" => "best_of_n",
      "base_score" => answer_score(baseline, example["answer"]),
      "composed_score" => score,
      "score" => score,
      "passed" => score == 1.0,
      "selected_prediction" => prediction_summary(prediction),
      "candidate_count" => 3
    }
  end

  defp refine([example | _examples]) do
    program = %HintProgram{bad_answer: "wrong", fixed_answer: example["answer"]}
    metric = answer_metric(example["answer"])
    baseline = call_answer(program, Map.delete(example, :hint_))

    {:ok, prediction} =
      program
      |> DSEx.Predict.Refine.new(metric, max_attempts: 2, feedback_fn: fn _ -> "try exact" end)
      |> DSEx.Predict.Refine.call(example)

    score = answer_score(prediction, example["answer"])

    %{
      "name" => "refine",
      "base_score" => answer_score(baseline, example["answer"]),
      "composed_score" => score,
      "score" => score,
      "passed" => score == 1.0,
      "history_length" => prediction |> DSEx.Prediction.get(:refine_history, []) |> length(),
      "selected_prediction" => prediction_summary(prediction)
    }
  end

  defp multi_chain_comparison([example | _examples]) do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{rationale: "the grounded attempt matches the question", answer: example["answer"]}
        end
      ]
    }

    program = DSEx.Predict.MultiChainComparison.new("question -> answer", lm: lm, m: 2)

    {:ok, prediction} =
      DSEx.Predict.MultiChainComparison.call(program, %{
        question: example["question"],
        completions: [
          %{reasoning: "distractor", answer: "wrong"},
          %{reasoning: "grounded", answer: example["answer"]}
        ]
      })

    score = answer_score(prediction, example["answer"])

    %{
      "name" => "multi_chain_comparison",
      "base_score" => 0.0,
      "composed_score" => score,
      "score" => score,
      "passed" => score == 1.0,
      "completion_count" => 2,
      "selected_prediction" => prediction_summary(prediction)
    }
  end

  defp ensemble([example | _examples]) do
    reducer = fn predictions ->
      predictions
      |> Enum.map(&DSEx.Prediction.get(&1, :answer))
      |> Enum.frequencies()
      |> Enum.max_by(fn {_answer, count} -> count end)
      |> elem(0)
      |> then(&DSEx.Prediction.new(answer: &1))
    end

    program =
      DSEx.Optimizer.Ensemble.new(reduce_fn: reducer, deterministic: true)
      |> DSEx.Optimizer.Ensemble.compile([
        %AnswerProgram{answer: example["answer"]},
        %AnswerProgram{answer: example["answer"]},
        %AnswerProgram{fail?: true}
      ])

    {:ok, prediction} = DSEx.Optimizer.Ensemble.Program.call(program, example)
    score = answer_score(prediction, example["answer"])

    raw =
      DSEx.Optimizer.Ensemble.new(deterministic: true)
      |> DSEx.Optimizer.Ensemble.compile([
        %AnswerProgram{answer: example["answer"]},
        %AnswerProgram{fail?: true}
      ])

    {:ok, raw_prediction} = DSEx.Optimizer.Ensemble.Program.call(raw, example)
    outputs = DSEx.Prediction.get(raw_prediction, :outputs)

    %{
      "name" => "ensemble",
      "base_score" => 1.0,
      "composed_score" => score,
      "score" => score,
      "passed" => score == 1.0,
      "failed_child_isolation" => Enum.any?(outputs, &match?({:error, _}, &1)),
      "selected_prediction" => prediction_summary(prediction),
      "child_results" => summarize_child_results(outputs)
    }
  end

  defp knn(examples) do
    trainset = Enum.map(examples, &example_from_row/1)
    query = List.first(examples)
    program = DSEx.Predict.KNN.new(2, trainset)
    demos = DSEx.Predict.KNN.call(program, %{question: query["question"]})
    retrieved_answers = Enum.map(demos, &DSEx.Example.get(&1, :answer))
    score = if query["answer"] in retrieved_answers, do: 1.0, else: 0.0

    %{
      "name" => "knn",
      "base_score" => 0.0,
      "composed_score" => score,
      "score" => score,
      "passed" => score == 1.0,
      "selected_demos" => Enum.map(demos, &DSEx.Example.to_map/1),
      "demo_count" => length(demos)
    }
  end

  defp parallel(examples, max_concurrency) do
    inputs = Enum.map(examples, &%{question: &1["question"]}) ++ [%{question: "please fail"}]

    results =
      DSEx.Predict.Parallel.map(%QuestionProgram{}, inputs,
        max_concurrency: max_concurrency,
        timeout: 5_000
      )

    successes =
      results
      |> Enum.zip(inputs)
      |> Enum.count(fn
        {{:ok, prediction}, %{question: question}} ->
          expected_parallel_answer(question) == DSEx.Prediction.get(prediction, :answer)

        _other ->
          false
      end)

    failures = Enum.count(results, &match?({:error, _}, &1))
    expected_successes = length(examples)
    score = if successes == expected_successes and failures == 1, do: 1.0, else: 0.0

    %{
      "name" => "parallel",
      "base_score" => 0.0,
      "composed_score" => score,
      "score" => score,
      "passed" => score == 1.0,
      "max_concurrency" => max_concurrency,
      "failed_child_isolation" => failures == 1 and successes == expected_successes,
      "child_results" => summarize_child_results(results)
    }
  end

  defp answer_metric(answer) do
    fn _example, prediction -> answer_score(prediction, answer) end
  end

  defp answer_score(nil, _answer), do: 0.0

  defp answer_score(prediction, answer) do
    if DSEx.Metrics.normalize_text(DSEx.Prediction.get(prediction, :answer)) ==
         DSEx.Metrics.normalize_text(answer),
       do: 1.0,
       else: 0.0
  end

  defp call_answer(program, inputs) do
    case DSEx.Module.call(program, inputs) do
      {:ok, prediction} -> prediction
      _other -> nil
    end
  end

  defp example_from_row(row) do
    DSEx.example(question: row["question"], answer: row["answer"])
    |> DSEx.Example.with_inputs(:question)
  end

  defp expected_parallel_answer(question) do
    cond do
      question =~ "France" -> "Paris"
      question =~ "Germany" -> "Berlin"
      true -> "unknown"
    end
  end

  defp prediction_summary(%DSEx.Prediction{} = prediction),
    do: prediction |> DSEx.Prediction.to_map() |> json_safe()

  defp prediction_summary(_prediction), do: %{}

  defp summarize_child_results(results) do
    Enum.map(results, fn
      {:ok, %DSEx.Prediction{} = prediction} ->
        %{"status" => "ok", "prediction" => prediction_summary(prediction)}

      {:error, reason} ->
        %{"status" => "error", "reason" => inspect(reason)}

      other ->
        %{"status" => "invalid", "reason" => inspect(other)}
    end)
  end

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp json_safe(%DSEx.Prediction{} = prediction), do: prediction_summary(prediction)
  defp json_safe(%DSEx.Example{} = example), do: example |> DSEx.Example.to_map() |> json_safe()

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(value), do: value

  defp example_map(%DSEx.Example{} = example) do
    example
    |> DSEx.Example.to_map()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp example_map(%{} = example),
    do: Map.new(example, fn {key, value} -> {to_string(key), value} end)
end
