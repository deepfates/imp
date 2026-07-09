defmodule GepaMetricsTest do
  use ExUnit.Case, async: true

  test "AIME metric parses integer answers exactly" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "AIME.metric integer exact match",
        "output_key" => "answer"
      })

    example = DSEx.example(problem: "p", answer: "42") |> DSEx.with_inputs(:problem)

    assert metric.(example, DSEx.prediction(answer: "42"))
    refute metric.(example, DSEx.prediction(answer: "42.0"))
    refute metric.(example, DSEx.prediction(answer: "forty two"))
  end

  test "HotPotQA metric uses normalized exact match over answer aliases" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "dspy.evaluate.answer_exact_match",
        "output_key" => "answer"
      })

    example =
      DSEx.example(question: "q", answer: ["The Eiffel Tower", "Eiffel Tower"])
      |> DSEx.with_inputs(:question)

    assert metric.(example, DSEx.prediction(answer: "eiffel tower"))
    refute metric.(example, DSEx.prediction(answer: "Paris"))
  end

  test "HoVer metric checks supporting fact titles against retrieved documents" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "hover_utils.discrete_retrieval_eval",
        "output_key" => "label"
      })

    example =
      DSEx.example(
        claim: "c",
        supporting_facts: [%{"key" => "Alpha Page"}, %{"key" => "Beta Page"}],
        label: "SUPPORTED"
      )
      |> DSEx.with_inputs(:claim)

    assert metric.(
             example,
             DSEx.prediction(retrieved_docs: ["Alpha Page | text", "Beta Page | text"])
           )

    refute metric.(example, DSEx.prediction(retrieved_docs: ["Alpha Page | text"]))
  end

  test "IFBench metric scores instruction-following constraints fractionally over upstream variants" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      DSEx.example(
        prompt: "Repeat this prompt.",
        response: "",
        instruction_id_list: [
          "keywords:existence",
          "keywords:forbidden_words",
          "detectable_content:number_placeholders",
          "detectable_format:number_bullet_lists",
          "startend:end_checker"
        ],
        kwargs: [
          %{"keywords" => ["alpha", "beta"]},
          %{"forbidden_words" => ["gamma"]},
          %{"num_placeholders" => 2},
          %{"num_bullets" => 2},
          %{"end_phrase" => "done"}
        ]
      )
      |> DSEx.with_inputs(:prompt)

    prediction =
      DSEx.prediction(
        response: """
        alpha beta
        [name] [date]
        * first
        * second
        done
        """
      )

    assert metric.(example, prediction) == 1.0

    assert metric.(example, DSEx.prediction(response: "alpha beta [name]\n* one\ndone")) == 0.6
  end

  test "IFBench metric applies upstream response variants before checking constraints" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      DSEx.example(
        prompt: "p",
        response: "",
        instruction_id_list: ["detectable_format:json_format"],
        kwargs: [%{}]
      )
      |> DSEx.with_inputs(:prompt)

    assert metric.(example, DSEx.prediction(response: "prefix\n{\"ok\": true}\nsuffix")) == 1.0
  end

  test "LiveBenchMath metric ports AMC answer parsing cases" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      DSEx.example(
        question: "Which is right? \\textbf{(A)} 1\\qquad \\textbf{(B)} 2$",
        answer: "B",
        question_d: %{
          "task" => "amc_12",
          "subtask" => "amc_12",
          "turns" => ["Which is right? \\textbf{(A)} 1\\qquad \\textbf{(B)} 2$"],
          "ground_truth" => "B"
        }
      )
      |> DSEx.with_inputs(:question)

    assert metric.(example, DSEx.prediction(answer: "<solution>BBBB</solution>"))
    assert metric.(example, DSEx.prediction(answer: "Therefore \\\\boxed{B}"))
    assert metric.(example, DSEx.prediction(answer: "The value is 2"))
    assert metric.(example, DSEx.prediction(answer: "Final line\n(B)"))
    refute metric.(example, DSEx.prediction(answer: "<solution>AAAA</solution>"))
  end

  test "LiveBenchMath metric ports AIME last-50-character scoring" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      DSEx.example(
        question: "Solve.",
        answer: "729",
        question_d: %{
          "task" => "aime_2024",
          "subtask" => "aime_2024",
          "turns" => ["Solve."],
          "ground_truth" => "729"
        }
      )
      |> DSEx.with_inputs(:question)

    assert metric.(example, DSEx.prediction(answer: "<think>729</think> final answer 729"))
    refute metric.(example, DSEx.prediction(answer: "729" <> String.duplicate("x", 60)))
  end

  test "Papillon metric uses DSEx judges for quality and leakage arithmetic" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    judge_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))
          Agent.update(calls, &[prompt | &1])

          cond do
            prompt =~ "num_pii_leaked" ->
              %{reasoning: "One private unit appears in the redacted request.", num_pii_leaked: 1}

            true ->
              quality_call_count =
                Agent.get(calls, fn seen ->
                  Enum.count(seen, &(&1 =~ "response_A" and &1 =~ "response_B"))
                end)

              %{reasoning: "Pairwise quality comparison.", judgment: quality_call_count == 1}
          end
        end
      ]
    }

    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(
        %{
          "upstream_metric" => "papillon_utils.compute_overall_score",
          "output_key" => "response"
        },
        judge_lm: judge_lm
      )

    example =
      DSEx.example(
        user_query: "Use my private account details to draft a note.",
        target_response: "A careful useful answer.",
        pii_str: "secret@example.com||555-0100"
      )
      |> DSEx.with_inputs(:user_query)

    prediction =
      DSEx.prediction(
        llm_request: "Draft a note for secret@example.com without other private details.",
        response: "A careful useful answer with privacy preserved."
      )

    assert metric.(example, prediction) == 0.75

    prompts = Agent.get(calls, &Enum.reverse/1)
    assert length(prompts) == 3
    assert Enum.any?(prompts, &(&1 =~ "Count the number information pieces"))
  end

  test "Papillon metric requires an explicit judge LM" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "papillon_utils.compute_overall_score",
        "output_key" => "response"
      })

    assert_raise ArgumentError, ~r/requires :judge_lm/, fn ->
      metric.(DSEx.example(user_query: "q"), DSEx.prediction(response: "r"))
    end
  end

  test "unknown GEPA metric falls back to normalized output exact match" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "unknown",
        "output_key" => "response"
      })

    example = DSEx.example(prompt: "p", response: "Hello, world!") |> DSEx.with_inputs(:prompt)

    assert metric.(example, DSEx.prediction(response: "hello world"))
  end
end
