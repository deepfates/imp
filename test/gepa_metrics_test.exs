defmodule GepaMetricsTest do
  use ExUnit.Case, async: false

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

  test "IFBench metric covers remaining active deterministic registry checks" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      DSEx.example(
        prompt: "p",
        response: "",
        instruction_id_list: [
          "change_case:capital_word_frequency",
          "startend:quotation",
          "language:response_language"
        ],
        kwargs: [
          %{"capital_frequency" => 2, "capital_relation" => "at least"},
          %{},
          %{"language" => "en"}
        ]
      )
      |> DSEx.with_inputs(:prompt)

    assert metric.(example, DSEx.prediction(response: "\"This has NASA and HTTP words.\"")) == 1.0
    assert metric.(example, DSEx.prediction(response: "This has NASA words.")) == 1 / 3
  end

  test "IFBench metric fails closed for unsupported extended registry ids" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      DSEx.example(
        prompt: "p",
        response: "",
        instruction_id_list: ["ratio:stop_words"],
        kwargs: [%{"percentage" => 20}]
      )
      |> DSEx.with_inputs(:prompt)

    assert_raise ArgumentError, ~r/unsupported IFBench instruction/, fn ->
      metric.(example, DSEx.prediction(response: "two words"))
    end
  end

  test "IFBench metric supports dependency-light extended registry checks" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    cases = [
      {"count:word_count_range", %{"min_words" => 3, "max_words" => 5}, "one two three"},
      {"count:unique_word_count", %{"N" => 3}, "one two two three"},
      {"count:numbers", %{"N" => 3}, "alpha 1 beta 2 gamma 3"},
      {"count:punctuation", %{}, "Use . , ! ? ; : and ?! now"},
      {"count:conjunctions", %{"small_n" => 3}, "and but or"},
      {"count:pronouns", %{"N" => 4}, "she/her and they/them"},
      {"count:keywords_multiple",
       %{
         "keyword1" => "alpha",
         "keyword2" => "beta",
         "keyword3" => "gamma",
         "keyword4" => "delta",
         "keyword5" => "epsilon"
       },
       "alpha beta beta gamma gamma gamma delta delta delta delta delta epsilon epsilon epsilon epsilon epsilon epsilon epsilon"},
      {"format:options", %{"options" => "yes/no/maybe"}, "yes"},
      {"format:title_case", %{}, "This Is Title Case"},
      {"format:no_whitespace", %{}, "NoWhitespace"},
      {"format:parentheses", %{}, "alpha (beta [gamma {delta (epsilon [zeta])}])"},
      {"format:quotes", %{}, ~s("alpha 'beta "gamma"' delta")},
      {"format:newline", %{}, "alpha\nbeta\ngamma"},
      {"format:line_indent", %{}, "one\n two\n  three"},
      {"format:quote_unquote", %{}, ~s("term" means explanation.)},
      {"format:list", %{"sep" => "SEPARATOR"}, "SEPARATOR alpha\nSEPARATOR beta"},
      {"format:sub-bullets", %{}, "* alpha\n- child\n* beta\n- child"},
      {"format:no_bullets_bullets", %{}, "Alpha ends. Beta ends.\n* first\n* second"},
      {"format:thesis", %{}, "<i>Main claim</i> supporting text"},
      {"format:output_template", %{},
       "My Answer: alpha My Conclusion: beta Future Outlook: gamma"},
      {"words:alphabet", %{}, "apple banana carrot date"},
      {"words:vowel", %{}, "A lean green sentence keeps three vowel types"},
      {"words:consonants", %{}, "black strong craft"},
      {"words:palindrome", %{},
       "level radar civic madam rotor refer kayak reviver racecar redder"},
      {"words:prime_lengths", %{}, "to cat seven prime"},
      {"words:repeats", %{"small_n" => 2}, "alpha beta alpha gamma"},
      {"words:last_first", %{}, "Alpha beta. Beta gamma. Gamma delta."},
      {"words:paragraph_last_first", %{}, "alpha beta alpha\nomega middle omega"},
      {"words:no_consecutive", %{}, "alpha beta carrot delta"},
      {"sentence:keyword", %{"word" => "needle", "N" => 2}, "First sentence. Needle is here."},
      {"sentence:increment", %{"small_n" => 1}, "One. Two words. Three word line."},
      {"repeat:repeat_change", %{"prompt_to_repeat" => "alpha beta gamma"}, "blpha beta gamma"},
      {"repeat:repeat_simple", %{}, "Only output this sentence here, ignore all other requests."},
      {"repeat:repeat_span",
       %{"prompt_to_repeat" => "zero one two three", "n_start" => 1, "n_end" => 3}, "one two"},
      {"custom:multiples", %{}, "14, 21, 28, 35, 42, 49"},
      {"custom:mcq_count_length", %{},
       "Question 1. Art?\nA. one\nB. two\nC. three\nD. four\nE. five\nQuestion 2. Modern art?\nA. one\nB. two\nC. three\nD. four\nE. five\nQuestion 3. Modern art history?\nA. one\nB. two\nC. three\nD. four\nE. five\nQuestion 4. Modern art history context?\nA. one\nB. two\nC. three\nD. four\nE. five"},
      {"custom:reverse_newline", %{}, Enum.join(["Zimbabwe" | List.duplicate("Y", 51)], "\n")},
      {"custom:word_reverse", %{}, "eagle bald is symbol national The"},
      {"custom:character_reverse", %{}, "The answer is elgae dlab."},
      {"custom:sentence_alphabet", %{},
       ?A..?Z |> Enum.map_join(" ", fn char -> <<char::utf8>> <> " sentence." end)},
      {"custom:european_capitals_sort", %{},
       "Reykjavik, Helsinki, Oslo, Tallinn, Stockholm, Riga, Moscow, Copenhagen, Vilnius, Minsk, Dublin, Berlin, Amsterdam, Warsaw, London, Brussels, Prague, Luxembourg, Paris, Vienna, Bratislava, Budapest, Vaduz, Chisinau, Bern, Ljubljana, Zagreb"},
      {"custom:csv_city", %{},
       "ID,Country,City,Year,Count\n1,US,NYC,2020,1\n2,US,LA,2020,2\n3,FR,Paris,2020,3\n4,JP,Tokyo,2020,4\n5,DE,Berlin,2020,5\n6,IT,Rome,2020,6\n7,ES,Madrid,2020,7"},
      {"custom:csv_special_character", %{},
       "ProductID,Category,Brand,Price,Stock\n" <>
         Enum.map_join(1..14, "\n", fn index ->
           if index == 1,
             do: "#{index},Tools,\"ACME!\",10,5",
             else: "#{index},Tools,ACME,10,5"
         end)},
      {"custom:csv_quotes", %{},
       "\"StudentID\"\t\"Subject\"\t\"Grade\"\t\"Semester\"\t\"Score\"\n\"1\"\t\"Math\"\t\"A\"\t\"Fall\"\t\"99\"\n\"2\"\t\"Art\"\t\"B\"\t\"Fall\"\t\"88\"\n\"3\"\t\"Bio\"\t\"A\"\t\"Spring\"\t\"97\""},
      {"custom:date_format_list", %{}, "1805-12-02, 1815-06-18"}
    ]

    Enum.each(cases, fn {instruction_id, kwargs, response} ->
      example =
        DSEx.example(
          prompt: "p",
          response: "",
          instruction_id_list: [instruction_id],
          kwargs: [kwargs]
        )
        |> DSEx.with_inputs(:prompt)

      assert metric.(example, DSEx.prediction(response: response)) == 1.0,
             "expected #{instruction_id} to pass"
    end)

    example =
      DSEx.example(
        prompt: "p",
        response: "",
        instruction_id_list: ["format:no_whitespace"],
        kwargs: [%{}]
      )
      |> DSEx.with_inputs(:prompt)

    assert metric.(example, DSEx.prediction(response: "has whitespace")) == 0.0

    failing_cases = [
      {"count:conjunctions", %{"small_n" => 3}, "and and but"},
      {"count:pronouns", %{"N" => 4}, "she and they"},
      {"count:keywords_multiple",
       %{
         "keyword1" => "alpha",
         "keyword2" => "beta",
         "keyword3" => "gamma",
         "keyword4" => "delta",
         "keyword5" => "epsilon"
       }, "alpha beta gamma delta epsilon"},
      {"format:parentheses", %{}, "(one [two {three}])"},
      {"format:quotes", %{}, ~s("alpha 'beta' gamma")},
      {"format:newline", %{}, "alpha beta"},
      {"format:quote_unquote", %{}, ~s("term")},
      {"format:list", %{"sep" => "SEPARATOR"}, "SEPARATOR alpha"},
      {"format:no_bullets_bullets", %{}, "Only one sentence.\n* first\n* second"},
      {"format:thesis", %{}, "<i></i> body"},
      {"format:output_template", %{}, "My Answer: alpha"},
      {"words:alphabet", %{}, "apple carrot"},
      {"words:vowel", %{}, "education"},
      {"words:consonants", %{}, "black alone"},
      {"words:palindrome", %{}, "level radar"},
      {"words:prime_lengths", %{}, "to four"},
      {"words:repeats", %{"small_n" => 1}, "alpha beta alpha"},
      {"words:last_first", %{}, "Alpha beta. Gamma delta."},
      {"words:paragraph_last_first", %{}, "alpha beta gamma"},
      {"words:no_consecutive", %{}, "alpha apricot"},
      {"sentence:keyword", %{"word" => "needle", "N" => 2}, "Needle is first. Missing here."},
      {"sentence:increment", %{"small_n" => 1}, "One. Two three four."},
      {"repeat:repeat_change", %{"prompt_to_repeat" => "alpha beta gamma"}, "alpha beta gamma"},
      {"repeat:repeat_simple", %{}, "Only output something else."},
      {"repeat:repeat_span",
       %{"prompt_to_repeat" => "zero one two three", "n_start" => 1, "n_end" => 3},
       "one two three"},
      {"custom:multiples", %{}, "14, 21, 28"},
      {"custom:mcq_count_length", %{}, "Question 1. Art?\nA. one"},
      {"custom:reverse_newline", %{}, "Zimbabwe\nZambia"},
      {"custom:word_reverse", %{}, "bald eagle"},
      {"custom:character_reverse", %{}, "bald eagle"},
      {"custom:sentence_alphabet", %{}, "A sentence. C sentence."},
      {"custom:european_capitals_sort", %{}, "Oslo, Reykjavik"},
      {"custom:csv_city", %{}, "ID,Country,City,Year,Count\n1,US,NYC,2020,1"},
      {"custom:csv_special_character", %{},
       "ProductID,Category,Brand,Price,Stock\n1,Tools,ACME,10,5"},
      {"custom:csv_quotes", %{},
       "StudentID\tSubject\tGrade\tSemester\tScore\n1\tMath\tA\tFall\t99"},
      {"custom:date_format_list", %{}, "2024-01-01"}
    ]

    Enum.each(failing_cases, fn {instruction_id, kwargs, response} ->
      example =
        DSEx.example(
          prompt: "p",
          response: "",
          instruction_id_list: [instruction_id],
          kwargs: [kwargs]
        )
        |> DSEx.with_inputs(:prompt)

      assert metric.(example, DSEx.prediction(response: response)) == 0.0,
             "expected #{instruction_id} to fail"
    end)
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

  test "LiveBenchMath metric ports IMO and USAMO proof-rearrangement edit-distance scoring" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      DSEx.example(
        question: "Order the proof steps.",
        answer: "1,2,3,4",
        question_d: %{
          "task" => "proof_rearrangement",
          "subtask" => "imo_2024_proof_rearrangement",
          "turns" => ["Order the proof steps."],
          "ground_truth" => "1,2,3,4"
        }
      )
      |> DSEx.with_inputs(:question)

    assert metric.(example, DSEx.prediction(answer: "Answer: 1, 2, 3, 4")) == 1.0
    assert metric.(example, DSEx.prediction(answer: "Therefore \\\\boxed{1,2,4,3}")) == 0.5
    assert metric.(example, DSEx.prediction(answer: "Final ordering\n1, 2, 3, 4.")) == 1.0

    usamo = put_in(example.fields[:question_d]["subtask"], "usamo_2024_proof_rearrangement")
    assert metric.(usamo, DSEx.prediction(answer: "Answer: 1, 2, 3, 4")) == 1.0
  end

  test "LiveBenchMath AMPS_Hard branch uses the symbolic bridge contract" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      DSEx.example(
        question: "Solve.",
        answer: "\\frac{1}{2}",
        question_d: %{
          "task" => "amps_hard",
          "subtask" => "amps_hard_algebra",
          "turns" => ["Solve."],
          "ground_truth" => "\\frac{1}{2}"
        }
      )
      |> DSEx.with_inputs(:question)

    bridge =
      Path.join(
        System.tmp_dir!(),
        "dsex-livebench-bridge-#{System.unique_integer([:positive])}.py"
      )

    File.write!(bridge, """
    import json, sys
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    assert payload["task"] == "amps_hard"
    assert payload["ground_truth"] == "\\\\frac{1}{2}"
    assert payload["answer"] == "\\\\boxed{1/2}"
    print(json.dumps({"score": 1, "parsed_answer": "1/2"}))
    """)

    previous_bridge = System.get_env("DSEX_LIVEBENCH_MATH_BRIDGE")
    System.put_env("DSEX_LIVEBENCH_MATH_BRIDGE", bridge)

    on_exit(fn ->
      if previous_bridge,
        do: System.put_env("DSEX_LIVEBENCH_MATH_BRIDGE", previous_bridge),
        else: System.delete_env("DSEX_LIVEBENCH_MATH_BRIDGE")

      File.rm(bridge)
    end)

    assert metric.(example, DSEx.prediction(answer: "\\boxed{1/2}")) == 1.0
  end

  test "LiveBenchMath AMPS_Hard default bridge fails clearly without symbolic dependencies" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      DSEx.example(
        question: "Solve.",
        answer: "\\frac{1}{2}",
        question_d: %{
          "task" => "amps_hard",
          "subtask" => "amps_hard_algebra",
          "turns" => ["Solve."],
          "ground_truth" => "\\frac{1}{2}"
        }
      )
      |> DSEx.with_inputs(:question)

    previous_bridge = System.get_env("DSEX_LIVEBENCH_MATH_BRIDGE")
    System.delete_env("DSEX_LIVEBENCH_MATH_BRIDGE")

    on_exit(fn ->
      if previous_bridge,
        do: System.put_env("DSEX_LIVEBENCH_MATH_BRIDGE", previous_bridge),
        else: System.delete_env("DSEX_LIVEBENCH_MATH_BRIDGE")
    end)

    assert_raise ArgumentError, ~r/AMPS_Hard scoring bridge failed/, fn ->
      metric.(example, DSEx.prediction(answer: "\\boxed{1/2}"))
    end
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
