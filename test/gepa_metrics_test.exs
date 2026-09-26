defmodule GepaMetricsTest do
  use ExUnit.Case, async: false

  defmodule FailingJudgeLM do
    defstruct [:reason]
    def generate(%__MODULE__{reason: reason}, _messages, _opts), do: {:error, reason}
  end

  defmodule FixedProgram do
    @behaviour Imp.Module
    defstruct [:prediction]

    @impl true
    def call(%__MODULE__{prediction: prediction}, _inputs), do: {:ok, prediction}
  end

  test "AIME metric parses integer answers exactly" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "AIME.metric integer exact match",
        "output_key" => "answer"
      })

    example = Imp.example(problem: "p", answer: "42") |> Imp.with_inputs(:problem)

    assert metric.(example, Imp.prediction(answer: "42"))
    refute metric.(example, Imp.prediction(answer: "42.0"))
    refute metric.(example, Imp.prediction(answer: "forty two"))
  end

  test "HotPotQA metric uses normalized exact match over answer aliases" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "dspy.evaluate.answer_exact_match",
        "output_key" => "answer"
      })

    example =
      Imp.example(question: "q", answer: ["The Eiffel Tower", "Eiffel Tower"])
      |> Imp.with_inputs(:question)

    assert metric.(example, Imp.prediction(answer: "eiffel tower"))
    refute metric.(example, Imp.prediction(answer: "Paris"))
  end

  test "HoVer metric checks supporting fact titles against retrieved documents" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "hover_utils.discrete_retrieval_eval",
        "output_key" => "label"
      })

    example =
      Imp.example(
        claim: "c",
        supporting_facts: [%{"key" => "Alpha Page"}, %{"key" => "Beta Page"}],
        label: "SUPPORTED"
      )
      |> Imp.with_inputs(:claim)

    assert metric.(
             example,
             Imp.prediction(retrieved_docs: ["Alpha Page | text", "Beta Page | text"])
           )

    refute metric.(example, Imp.prediction(retrieved_docs: ["Alpha Page | text"]))
  end

  test "Papillon judge failures keep ordered scorer inputs and structured diagnostics" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(
        %{"upstream_metric" => "papillon_utils.compute_overall_score"},
        judge_lm: %FailingJudgeLM{reason: :judge_unavailable}
      )

    example =
      Imp.example(
        user_query: "private question",
        target_response: "target answer",
        pii_str: "alice@example.com"
      )
      |> Imp.with_inputs(:user_query)

    prediction =
      Imp.prediction(
        llm_request: "redacted question",
        llm_response: "external answer",
        response: "final answer"
      )

    # Use the public evaluator with a minimal program so the retained row is
    # exactly the scorer input users can inspect after a judge failure.
    callable = %FixedProgram{prediction: prediction}

    result =
      Imp.Evaluate.new([example], metric, max_errors: :infinity, failure_score: 0.0)
      |> Imp.Evaluate.run(callable)

    assert [%{index: 0, example: ^example, prediction: ^prediction, score: +0.0} = row] =
             result.rows

    assert %{imp_metric_error: {:error, :judge_unavailable}} = row.metric_metadata
    assert [%{index: 0, stage: :metric, reason: {:error, :judge_unavailable}}] = result.errors
  end

  test "AIME GEPA feedback matches Python integer parsing and source text" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.gepa_metric(
        %{
          "upstream_metric" => "AIME.metric integer exact match"
        },
        []
      )

    example =
      Imp.example(question: "q", answer: "42", solution: "proof")
      |> Imp.with_inputs(:question)

    assert %{score: 1.0, feedback: correct} =
             metric.(example, Imp.prediction(answer: " 42 "), [%{predictor: :main}])

    assert correct ==
             "Your answer is correct. The correct answer is '42'. Here's the full step-by-step solution:\nproof\n\nThink about what takeaways you can learn from this solution to improve your future answers and approach to similar problems."

    assert %{score: +0.0, feedback: invalid} =
             metric.(example, Imp.prediction(answer: "42x"), [%{predictor: :main}])

    assert invalid =~ "couldn't be parsed as a python integer"
    assert invalid =~ "ensure your final answer is a valid integer"
  end

  test "Papillon task failures keep the released score and remain diagnostic-only" do
    judge =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

          if prompt =~ "num_pii_leaked",
            do: %{reasoning: "none", num_pii_leaked: 0},
            else: %{reasoning: "equal", judgment: true}
        end
      )

    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(
        %{"upstream_metric" => "papillon_utils.compute_overall_score"},
        judge_lm: judge
      )

    example =
      Imp.example(user_query: "q", target_response: "", pii_str: "")
      |> Imp.with_inputs(:user_query)

    diagnostic = %{stage: :untrusted_model, reason: :offline}

    prediction =
      Imp.Prediction.new(
        %{llm_request: "", llm_response: "", response: ""},
        metadata: %{papillon_failure: diagnostic}
      )

    assert %Imp.Metrics.Result{
             score: 1.0,
             feedback: %{diagnostic_only: true, error: ^diagnostic},
             metadata: %{papillon_program_failure: ^diagnostic}
           } = metric.(example, prediction)
  end

  test "IFBench metric scores instruction-following constraints fractionally over upstream variants" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      Imp.example(
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
      |> Imp.with_inputs(:prompt)

    prediction =
      Imp.prediction(
        response: """
        alpha beta
        [name] [date]
        * first
        * second
        done
        """
      )

    assert metric.(example, prediction) == 1.0

    assert metric.(example, Imp.prediction(response: "alpha beta [name]\n* one\ndone")) == 0.6
  end

  test "IFBench reflective metric uses pinned upstream instruction descriptions" do
    bridge =
      Path.join(
        System.tmp_dir!(),
        "imp-ifbench-description-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(
      bridge,
      "#!/bin/sh\nprintf '%s\\n' 'Downloaded punkt_tab on rank 0' '{\"descriptions\":[\"Include alpha.\",\"Do not use commas.\"]}'\n"
    )

    on_exit(fn -> File.rm(bridge) end)

    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric_with_feedback(
        %{"upstream_metric" => "IFBench.ifbench_metric.metric"},
        upstream_descriptions: true,
        gepa_root: System.tmp_dir!(),
        python: "sh",
        ifbench_description_bridge: bridge
      )

    example =
      Imp.example(
        prompt: "Use alpha without commas.",
        instruction_id_list: ["keywords:existence", "punctuation:no_comma"],
        kwargs: [%{"keywords" => ["alpha"]}, %{}]
      )
      |> Imp.with_inputs(:prompt)

    result = metric.(example, Imp.prediction(response: "alpha"))

    assert result.score == 1.0
    assert result.feedback =~ "Include alpha."
    assert result.feedback =~ "Do not use commas."
    refute result.feedback =~ "keywords:existence"
  end

  test "IFBench metric applies upstream response variants before checking constraints" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      Imp.example(
        prompt: "p",
        response: "",
        instruction_id_list: ["detectable_format:json_format"],
        kwargs: [%{}]
      )
      |> Imp.with_inputs(:prompt)

    assert metric.(example, Imp.prediction(response: "prefix\n{\"ok\": true}\nsuffix")) == 1.0
  end

  test "IFBench metric adapts ordered scorer arguments without mutating proposer data" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric"
      })

    ordered_keywords =
      %Jason.OrderedObject{
        values: [
          {"keywords", ["alpha", "beta"]},
          {"unused", %Jason.OrderedObject{values: [{"nested", [1, 2, 3]}]}},
          {"nil_value", nil}
        ]
      }

    ordered_forbidden =
      %Jason.OrderedObject{values: [{"forbidden_words", ["gamma"]}]}

    example =
      Imp.example(
        prompt: "p",
        instruction_id_list: ["keywords:existence", "keywords:forbidden_words"],
        kwargs: [ordered_keywords, ordered_forbidden]
      )
      |> Imp.with_inputs(:prompt)

    assert metric.(example, Imp.prediction(response: "alpha beta")) == 1.0
    assert Imp.Example.get(example, :kwargs) == [ordered_keywords, ordered_forbidden]
  end

  test "IFBench metric covers remaining active deterministic registry checks" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      Imp.example(
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
      |> Imp.with_inputs(:prompt)

    assert metric.(example, Imp.prediction(response: "\"This has NASA and HTTP words.\"")) == 1.0
    assert metric.(example, Imp.prediction(response: "This has NASA words.")) == 1 / 3
  end

  test "IFBench metric fails closed for unsupported extended registry ids" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    example =
      Imp.example(
        prompt: "p",
        response: "",
        instruction_id_list: ["ratio:not_a_real_instruction"],
        kwargs: [%{"percentage" => 20}]
      )
      |> Imp.with_inputs(:prompt)

    assert_raise ArgumentError, ~r/unsupported IFBench instruction/, fn ->
      metric.(example, Imp.prediction(response: "two words"))
    end
  end

  test "IFBench metric supports dependency-light extended registry checks" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
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
      {"count:person_names", %{"N" => 3}, "Emma and Liam met Sophia."},
      {"count:words_japanese", %{"N" => 2.0}, "alpha 日本 beta 東京"},
      {"count:keywords_multiple",
       %{
         "keyword1" => "alpha",
         "keyword2" => "beta",
         "keyword3" => "gamma",
         "keyword4" => "delta",
         "keyword5" => "epsilon"
       },
       "alpha beta beta gamma gamma gamma delta delta delta delta delta epsilon epsilon epsilon epsilon epsilon epsilon epsilon"},
      {"ratio:sentence_type", %{}, "One. Two. Three?"},
      {"ratio:sentence_balance", %{}, "One. Two? Three!"},
      {"ratio:overlap", %{"reference_text" => "abcdef", "percentage" => 100}, "abcdef"},
      {"ratio:sentence_words", %{}, "Aaa. Bbb. Ccc."},
      {"ratio:stop_words", %{"percentage" => 50}, "quartz azure vector"},
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
      {"format:emoji", %{}, "First sentence 🙂. Second sentence 🚀."},
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
      {"words:start_verb", %{}, "Write the answer."},
      {"words:odd_even_syllables", %{}, "cat pizza dog"},
      {"words:last_first", %{}, "Alpha beta. Beta gamma. Gamma delta."},
      {"words:paragraph_last_first", %{}, "alpha beta alpha\nomega middle omega"},
      {"words:no_consecutive", %{}, "alpha beta carrot delta"},
      {"sentence:alliteration_increment", %{}, "Alpha. Blue berry. Cool calm cat."},
      {"sentence:keyword", %{"word" => "needle", "N" => 2}, "First sentence. Needle is here."},
      {"sentence:increment", %{"small_n" => 1}, "One. Two words. Three word line."},
      {"words:keywords_specific_position", %{"keyword" => "needle", "n" => 2, "m" => 3},
       "First sentence. One two needle."},
      {"words:words_position", %{"keyword" => "key"}, "x key middle key end"},
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
        Imp.example(
          prompt: "p",
          response: "",
          instruction_id_list: [instruction_id],
          kwargs: [kwargs]
        )
        |> Imp.with_inputs(:prompt)

      assert metric.(example, Imp.prediction(response: response)) == 1.0,
             "expected #{instruction_id} to pass"
    end)

    example =
      Imp.example(
        prompt: "p",
        response: "",
        instruction_id_list: ["format:no_whitespace"],
        kwargs: [%{}]
      )
      |> Imp.with_inputs(:prompt)

    assert metric.(example, Imp.prediction(response: "has whitespace")) == 0.0

    failing_cases = [
      {"count:conjunctions", %{"small_n" => 3}, "and and but"},
      {"count:pronouns", %{"N" => 4}, "she and they"},
      {"count:person_names", %{"N" => 3}, "Emma and Liam."},
      {"count:words_japanese", %{"N" => 2}, "alpha beta gamma delta"},
      {"count:keywords_multiple",
       %{
         "keyword1" => "alpha",
         "keyword2" => "beta",
         "keyword3" => "gamma",
         "keyword4" => "delta",
         "keyword5" => "epsilon"
       }, "alpha beta gamma delta epsilon"},
      {"ratio:sentence_type", %{}, "One. Two?"},
      {"ratio:sentence_balance", %{}, "One. Two?"},
      {"ratio:overlap", %{"reference_text" => "abcdef", "percentage" => 100}, "abcxyz"},
      {"ratio:sentence_words", %{}, "Aaa. Bbbb. Ccc."},
      {"ratio:stop_words", %{"percentage" => 20}, "the and of in"},
      {"format:parentheses", %{}, "(one [two {three}])"},
      {"format:quotes", %{}, ~s("alpha 'beta' gamma")},
      {"format:newline", %{}, "alpha beta"},
      {"format:quote_unquote", %{}, ~s("term")},
      {"format:list", %{"sep" => "SEPARATOR"}, "SEPARATOR alpha"},
      {"format:no_bullets_bullets", %{}, "Only one sentence.\n* first\n* second"},
      {"format:emoji", %{}, "First sentence. Second sentence."},
      {"format:thesis", %{}, "<i></i> body"},
      {"format:output_template", %{}, "My Answer: alpha"},
      {"words:alphabet", %{}, "apple carrot"},
      {"words:vowel", %{}, "education"},
      {"words:consonants", %{}, "black alone"},
      {"words:palindrome", %{}, "level radar"},
      {"words:prime_lengths", %{}, "to four"},
      {"words:repeats", %{"small_n" => 1}, "alpha beta alpha"},
      {"words:start_verb", %{}, "Table answer."},
      {"words:odd_even_syllables", %{}, "cat dog"},
      {"words:last_first", %{}, "Alpha beta. Gamma delta."},
      {"words:paragraph_last_first", %{}, "alpha beta gamma"},
      {"words:no_consecutive", %{}, "alpha apricot"},
      {"sentence:alliteration_increment", %{}, "Blue berry. Alpha."},
      {"sentence:keyword", %{"word" => "needle", "N" => 2}, "Needle is first. Missing here."},
      {"sentence:increment", %{"small_n" => 1}, "One. Two three four."},
      {"words:keywords_specific_position", %{"keyword" => "needle", "n" => 2, "m" => 3},
       "First sentence. One needle two."},
      {"words:words_position", %{"keyword" => "key"}, "x key middle nope end"},
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
        Imp.example(
          prompt: "p",
          response: "",
          instruction_id_list: [instruction_id],
          kwargs: [kwargs]
        )
        |> Imp.with_inputs(:prompt)

      assert metric.(example, Imp.prediction(response: response)) == 0.0,
             "expected #{instruction_id} to fail"
    end)
  end

  test "IFBench NLP-backed checks can delegate to a source-exact Python bridge" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric",
        "output_key" => "response"
      })

    bridge =
      Path.join(
        System.tmp_dir!(),
        "imp-ifbench-nlp-bridge-#{System.unique_integer([:positive])}.py"
      )

    File.write!(bridge, """
    import json, sys
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    assert payload["instruction_id"] in {
        "ratio:stop_words",
        "format:emoji",
        "words:start_verb",
        "words:odd_even_syllables",
        "language:response_language",
    }
    assert payload["value"] == "bridge-ok"
    print(json.dumps({"following": True}))
    """)

    previous_bridge = System.get_env("IMP_IFBENCH_NLP_BRIDGE")
    previous_python = System.get_env("IMP_IFBENCH_NLP_PYTHON")
    System.put_env("IMP_IFBENCH_NLP_BRIDGE", bridge)
    System.put_env("IMP_IFBENCH_NLP_PYTHON", System.find_executable("python3") || "python3")

    on_exit(fn ->
      if previous_bridge,
        do: System.put_env("IMP_IFBENCH_NLP_BRIDGE", previous_bridge),
        else: System.delete_env("IMP_IFBENCH_NLP_BRIDGE")

      if previous_python,
        do: System.put_env("IMP_IFBENCH_NLP_PYTHON", previous_python),
        else: System.delete_env("IMP_IFBENCH_NLP_PYTHON")

      File.rm(bridge)
    end)

    example =
      Imp.example(
        prompt: "p",
        response: "",
        instruction_id_list: [
          "ratio:stop_words",
          "format:emoji",
          "words:start_verb",
          "words:odd_even_syllables",
          "language:response_language"
        ],
        kwargs: [%{"percentage" => 10}, %{}, %{}, %{}, %{"language" => "fa"}]
      )
      |> Imp.with_inputs(:prompt)

    assert metric.(example, Imp.prediction(response: "bridge-ok")) == 1.0
  end

  @tag :evidence_infrastructure
  test "IFBench registry parity fixtures cover every active upstream instruction id" do
    fixture_path = "test/fixtures/ifbench_registry_parity.jsonl"
    fixtures = load_ifbench_parity_fixtures(fixture_path)
    fixture_ids = fixtures |> Enum.map(& &1["instruction_id"]) |> MapSet.new()
    registry_ids = upstream_ifbench_registry_ids()

    assert MapSet.difference(registry_ids, fixture_ids) == MapSet.new()
    assert MapSet.difference(fixture_ids, registry_ids) == MapSet.new()

    if System.get_env("IMP_IFBENCH_UPSTREAM_PARITY") == "1" do
      run_ifbench_upstream_parity!(fixture_path, fixtures)
    end
  end

  @tag :evidence_infrastructure
  test "IFBench scorer matches pinned semantics on every frozen GEPA and MIPRO row" do
    if System.get_env("IMP_IFBENCH_UPSTREAM_PARITY") == "1" do
      run_frozen_ifbench_parity!()
    end
  end

  test "LiveBenchMath metric ports AMC answer parsing cases" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      Imp.example(
        question: "Which is right? \\textbf{(A)} 1\\qquad \\textbf{(B)} 2$",
        answer: "B",
        question_d: %{
          "task" => "amc_12",
          "subtask" => "amc_12",
          "turns" => ["Which is right? \\textbf{(A)} 1\\qquad \\textbf{(B)} 2$"],
          "ground_truth" => "B"
        }
      )
      |> Imp.with_inputs(:question)

    assert metric.(example, Imp.prediction(answer: "<solution>BBBB</solution>"))
    assert metric.(example, Imp.prediction(answer: "Therefore \\\\boxed{B}"))
    assert metric.(example, Imp.prediction(answer: "The value is 2"))
    assert metric.(example, Imp.prediction(answer: "Final line\n(B)"))
    refute metric.(example, Imp.prediction(answer: "<solution>AAAA</solution>"))
  end

  test "LiveBenchMath metric ports AIME last-50-character scoring" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      Imp.example(
        question: "Solve.",
        answer: "729",
        question_d: %{
          "task" => "aime_2024",
          "subtask" => "aime_2024",
          "turns" => ["Solve."],
          "ground_truth" => "729"
        }
      )
      |> Imp.with_inputs(:question)

    assert metric.(example, Imp.prediction(answer: "<think>729</think> final answer 729"))
    refute metric.(example, Imp.prediction(answer: "729" <> String.duplicate("x", 60)))
  end

  test "LiveBenchMath metric ports IMO and USAMO proof-rearrangement edit-distance scoring" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      Imp.example(
        question: "Order the proof steps.",
        answer: "1,2,3,4",
        question_d: %{
          "task" => "proof_rearrangement",
          "subtask" => "imo_2024_proof_rearrangement",
          "turns" => ["Order the proof steps."],
          "ground_truth" => "1,2,3,4"
        }
      )
      |> Imp.with_inputs(:question)

    assert metric.(example, Imp.prediction(answer: "Answer: 1, 2, 3, 4")) == 1.0
    assert metric.(example, Imp.prediction(answer: "Therefore \\\\boxed{1,2,4,3}")) == 0.5
    assert metric.(example, Imp.prediction(answer: "Final ordering\n1, 2, 3, 4.")) == 1.0

    usamo = put_in(example.fields[:question_d]["subtask"], "usamo_2024_proof_rearrangement")
    assert metric.(usamo, Imp.prediction(answer: "Answer: 1, 2, 3, 4")) == 1.0
  end

  test "LiveBenchMath AMPS_Hard branch uses the symbolic bridge contract" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      Imp.example(
        question: "Solve.",
        answer: "\\frac{1}{2}",
        question_d: %{
          "task" => "amps_hard",
          "subtask" => "amps_hard_algebra",
          "turns" => ["Solve."],
          "ground_truth" => "\\frac{1}{2}"
        }
      )
      |> Imp.with_inputs(:question)

    bridge =
      Path.join(
        System.tmp_dir!(),
        "imp-livebench-bridge-#{System.unique_integer([:positive])}.py"
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

    previous_bridge = System.get_env("IMP_LIVEBENCH_MATH_BRIDGE")
    System.put_env("IMP_LIVEBENCH_MATH_BRIDGE", bridge)

    on_exit(fn ->
      if previous_bridge,
        do: System.put_env("IMP_LIVEBENCH_MATH_BRIDGE", previous_bridge),
        else: System.delete_env("IMP_LIVEBENCH_MATH_BRIDGE")

      File.rm(bridge)
    end)

    assert metric.(example, Imp.prediction(answer: "\\boxed{1/2}")) == 1.0
  end

  test "LiveBenchMath AMPS_Hard default bridge fails clearly without symbolic dependencies" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "livebench_math.calculate_livebench_score",
        "output_key" => "answer"
      })

    example =
      Imp.example(
        question: "Solve.",
        answer: "\\frac{1}{2}",
        question_d: %{
          "task" => "amps_hard",
          "subtask" => "amps_hard_algebra",
          "turns" => ["Solve."],
          "ground_truth" => "\\frac{1}{2}"
        }
      )
      |> Imp.with_inputs(:question)

    previous_bridge = System.get_env("IMP_LIVEBENCH_MATH_BRIDGE")
    System.delete_env("IMP_LIVEBENCH_MATH_BRIDGE")

    on_exit(fn ->
      if previous_bridge,
        do: System.put_env("IMP_LIVEBENCH_MATH_BRIDGE", previous_bridge),
        else: System.delete_env("IMP_LIVEBENCH_MATH_BRIDGE")
    end)

    assert_raise ArgumentError, ~r/AMPS_Hard scoring bridge failed/, fn ->
      metric.(example, Imp.prediction(answer: "\\boxed{1/2}"))
    end
  end

  test "LiveBenchMath GEPA routes AMPS feedback through the pinned source contract" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.gepa_metric(
        %{
          "upstream_metric" => "livebench_math.calculate_livebench_score",
          "output_key" => "answer"
        },
        []
      )

    example =
      Imp.example(
        question: "Solve.",
        answer: "x^2",
        question_d: %{
          "task" => "AMPS_Hard",
          "subtask" => "amps_hard_algebra",
          "turns" => ["Solve."],
          "ground_truth" => "x^2"
        }
      )
      |> Imp.with_inputs(:question)

    bridge =
      Path.join(System.tmp_dir!(), "imp-livebench-gepa-#{System.unique_integer([:positive])}.py")

    File.write!(bridge, """
    import json, sys
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if payload["task"] == "amps_hard":
        print(json.dumps({"score": 1, "parsed_answer": "x^2"}))
    else:
        assert payload["task"] == "livebench_math_feedback"
        assert payload["question_d"]["task"] == "AMPS_Hard"
        print(json.dumps({
            "score": 1,
            "feedback": "Your answer is correct. Specifically, you wrote 'x^2' which was found to be equivalent to the correct answer 'x^2'."
        }))
    """)

    previous_bridge = System.get_env("IMP_LIVEBENCH_MATH_BRIDGE")
    System.put_env("IMP_LIVEBENCH_MATH_BRIDGE", bridge)

    on_exit(fn ->
      if previous_bridge,
        do: System.put_env("IMP_LIVEBENCH_MATH_BRIDGE", previous_bridge),
        else: System.delete_env("IMP_LIVEBENCH_MATH_BRIDGE")

      File.rm(bridge)
    end)

    assert %{score: 1.0, feedback: feedback} =
             metric.(example, Imp.prediction(answer: "x^2"), [%{predictor: :main}])

    assert feedback ==
             "Your answer is correct. Specifically, you wrote 'x^2' which was found to be equivalent to the correct answer 'x^2'."
  end

  test "Papillon metric uses Imp judges for quality and leakage arithmetic" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    judge_lm =
      Imp.LM.Static.new(
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
      )

    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(
        %{
          "upstream_metric" => "papillon_utils.compute_overall_score",
          "output_key" => "response"
        },
        judge_lm: judge_lm
      )

    example =
      Imp.example(
        user_query: "Use my private account details to draft a note.",
        target_response: "A careful useful answer.",
        pii_str: "||secret@example.com"
      )
      |> Imp.with_inputs(:user_query)

    prediction =
      Imp.prediction(
        llm_request: "Draft a note for secret@example.com without other private details.",
        response: "A careful useful answer with privacy preserved."
      )

    assert metric.(example, prediction) == 0.75

    prompts = Agent.get(calls, &Enum.reverse/1)
    assert length(prompts) == 3
    assert Enum.any?(prompts, &(&1 =~ "Count the number information pieces"))
  end

  test "Papillon GEPA uses six judges per metric call, trace Boolean scoring, and no leakage clamp" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    judge =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Agent.update(calls, &(&1 + 1))
          prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

          if prompt =~ "num_pii_leaked",
            do: %{reasoning: "three", num_pii_leaked: 3},
            else: %{reasoning: "yes", judgment: true}
        end
      )

    metric =
      Imp.BenchmarkTruth.GepaMetrics.gepa_metric(
        %{"upstream_metric" => "papillon_utils.compute_overall_score"},
        judge_lm: judge
      )

    example =
      Imp.example(user_query: "q", target_response: "target", pii_str: "a||b")
      |> Imp.with_inputs(:user_query)

    prediction = Imp.prediction(llm_request: "request", response: "response")

    assert %{score: 0.25, feedback: feedback} = metric.(example, prediction, nil)
    assert Agent.get(calls, & &1) == 6
    assert feedback =~ "leakage score (-0.50)"

    Agent.update(calls, fn _ -> 0 end)
    assert %{score: +0.0, passed?: false} = metric.(example, prediction, [%{predictor: :main}])
    assert Agent.get(calls, & &1) == 6
  end

  test "Papillon metric requires an explicit judge LM" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "papillon_utils.compute_overall_score",
        "output_key" => "response"
      })

    assert_raise ArgumentError, ~r/requires :judge_lm/, fn ->
      metric.(Imp.example(user_query: "q"), Imp.prediction(response: "r"))
    end
  end

  test "unknown GEPA metric falls back to normalized output exact match" do
    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "unknown",
        "output_key" => "response"
      })

    example = Imp.example(prompt: "p", response: "Hello, world!") |> Imp.with_inputs(:prompt)

    assert metric.(example, Imp.prediction(response: "hello world"))
  end

  defp load_ifbench_parity_fixtures(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp upstream_ifbench_registry_ids do
    [
      "tmp/gepa-artifact/gepa_artifact/benchmarks/IFBench/utils_ifbench/instructions_registry.py",
      "tmp/gepa-artifact/gepa_artifact/benchmarks/IFBench/utils_ifbench/instructions_registry_ifeval.py"
    ]
    |> Enum.flat_map(fn path ->
      assert File.exists?(path), "missing upstream IFBench registry source: #{path}"

      source =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
        |> Enum.join("\n")

      literal_ids =
        source
        |> then(&Regex.scan(~r/"([^"]+:[^"]+)"\s*:/, &1))
        |> Enum.map(fn [_, instruction_id] -> instruction_id end)

      prefix_constants =
        source
        |> then(&Regex.scan(~r/(_[A-Z_]+)\s*=\s*"([^"]+)"/, &1))
        |> Map.new(fn [_, name, prefix] -> {name, prefix} end)

      prefixed_ids =
        source
        |> then(&Regex.scan(~r/(_[A-Z_]+)\s*\+\s*"([^"]+)"\s*:/, &1))
        |> Enum.map(fn [_, name, suffix] -> Map.fetch!(prefix_constants, name) <> suffix end)

      literal_ids ++ prefixed_ids
    end)
    |> MapSet.new()
  end

  defp run_ifbench_upstream_parity!(fixture_path, fixtures) do
    python = System.get_env("IMP_IFBENCH_UPSTREAM_PYTHON") || "python3"

    {output, status} =
      System.cmd(
        python,
        [
          "scripts/ifbench_upstream_eval.py",
          "--artifact-root",
          "tmp/gepa-artifact",
          "--fixtures",
          fixture_path
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    report = Jason.decode!(output)
    assert report["missing_fixture_ids"] == []
    assert report["extra_fixture_ids"] == []

    by_id = Map.new(fixtures, &{&1["instruction_id"], &1})

    metric =
      Imp.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "IFBench.ifbench_metric.metric"
      })

    Enum.each(report["results"], fn result ->
      refute Map.has_key?(result, "error"), inspect(result)
      assert result["upstream_following"], inspect(result)
      refute result["upstream_blank_following"], inspect(result)

      fixture = Map.fetch!(by_id, result["instruction_id"])

      example =
        Imp.example(
          prompt: fixture["prompt"],
          instruction_id_list: [fixture["instruction_id"]],
          kwargs: [fixture["kwargs"]]
        )
        |> Imp.with_inputs(:prompt)

      assert metric.(example, Imp.prediction(response: fixture["response"])) == 1.0,
             "Imp disagreed with upstream for #{fixture["instruction_id"]}"

      assert metric.(example, Imp.prediction(response: "")) == 0.0,
             "Imp accepted a blank response for #{fixture["instruction_id"]}"
    end)
  end

  defp run_frozen_ifbench_parity! do
    paths =
      Path.wildcard("research/matched_instruction_family_ifbench/data/*.jsonl") ++
        Path.wildcard("research/matched_instruction_family_ifbench/data/mipro_stage1/*.jsonl")

    entries =
      Enum.flat_map(paths, fn path ->
        path
        |> File.stream!()
        |> Enum.flat_map(fn line ->
          row = Jason.decode!(line)

          %Jason.OrderedObject{values: ordered_values} =
            Jason.decode!(line, objects: :ordered_objects)

          ordered = Map.new(ordered_values)

          row["instruction_id_list"]
          |> Enum.with_index()
          |> Enum.map(fn {instruction_id, index} ->
            fixture = %{
              "instruction_id" => instruction_id,
              "kwargs" => Enum.at(row["kwargs"], index),
              "prompt" => row["prompt"],
              "response" => row["prompt"]
            }

            {fixture, ordered, index}
          end)
        end)
      end)

    assert length(entries) == 337

    assert entries
           |> Enum.map(fn {fixture, _row, _index} -> fixture["instruction_id"] end)
           |> Enum.uniq()
           |> length() == 80

    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "imp-ifbench-frozen-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(
      fixture_path,
      Enum.map_join(entries, "", fn {fixture, _ordered, _index} ->
        Jason.encode!(fixture) <> "\n"
      end)
    )

    previous_bridge = System.get_env("IMP_IFBENCH_NLP_BRIDGE")
    previous_python = System.get_env("IMP_IFBENCH_NLP_PYTHON")
    python = System.get_env("IMP_IFBENCH_UPSTREAM_PYTHON") || "python3"
    System.put_env("IMP_IFBENCH_NLP_BRIDGE", Path.expand("scripts/ifbench_nlp_check.py"))
    System.put_env("IMP_IFBENCH_NLP_PYTHON", python)

    try do
      {output, status} =
        System.cmd(
          python,
          [
            "scripts/ifbench_upstream_eval.py",
            "--artifact-root",
            "tmp/gepa-artifact",
            "--fixtures",
            fixture_path
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      report = Jason.decode!(output)
      assert report["fixture_count"] == length(entries)
      assert Enum.all?(report["results"], &(not Map.has_key?(&1, "error")))

      metric =
        Imp.BenchmarkTruth.GepaMetrics.metric(%{
          "upstream_metric" => "IFBench.ifbench_metric.metric"
        })

      Enum.zip(entries, report["results"])
      |> Enum.each(fn {{fixture, ordered, index}, upstream} ->
        example =
          Imp.Example.new(%{
            prompt: ordered["prompt"],
            instruction_id_list: [fixture["instruction_id"]],
            kwargs: [Enum.at(ordered["kwargs"], index)]
          })

        imp_following =
          metric.(example, Imp.Prediction.new(%{response: fixture["response"]})) == 1.0

        assert imp_following == upstream["upstream_following"],
               "frozen scorer mismatch for #{fixture["instruction_id"]}"
      end)
    after
      File.rm(fixture_path)

      if previous_bridge,
        do: System.put_env("IMP_IFBENCH_NLP_BRIDGE", previous_bridge),
        else: System.delete_env("IMP_IFBENCH_NLP_BRIDGE")

      if previous_python,
        do: System.put_env("IMP_IFBENCH_NLP_PYTHON", previous_python),
        else: System.delete_env("IMP_IFBENCH_NLP_PYTHON")
    end
  end
end
