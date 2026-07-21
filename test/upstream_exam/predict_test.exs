defmodule UpstreamExam.PredictTest do
  @moduledoc """
  DSPy 3.2.1's own predict tests (tests/predict/), ported to Imp.

  Tranche 2 of the upstream exam: every test here cites the upstream file and
  test function it translates. The complete per-test disposition map (including
  the tests that were NOT portable and why) is docs/internal/UPSTREAM_EXAM.md.

  Rules of this file:
    * assertions check the SAME behavior as upstream, not a look-alike;
    * where Imp deliberately substitutes a design (Elixir sandbox for the Deno
      Python interpreter, `{:error, reason}` tuples for exceptions, `:history`
      entries for the trajectory dict), the port asserts the substituted
      surface and the exam table records the seam;
    * a failing port is a FINDING: it gets tagged @tag :upstream_fail and
      skipped with the failure output preserved in a comment until the
      divergence is fixed in lib (never by weakening the assertion).
  """

  use ExUnit.Case, async: true

  @moduletag :upstream_exam

  # ---------------------------------------------------------------------------
  # Helpers: DummyLM / DummyModule equivalents
  # ---------------------------------------------------------------------------

  # Upstream DummyModule (tests/predict/test_best_of_n.py, test_refine.py):
  # a dspy.Module wrapping one Predict with a caller-supplied forward function.
  defmodule DummyModule do
    @behaviour Imp.Module
    defstruct [:predictor, :forward_fn]

    def new(signature, forward_fn, opts \\ []) do
      %__MODULE__{
        predictor: Imp.Predict.Predict.new(signature, opts),
        forward_fn: forward_fn
      }
    end

    @impl true
    def call(%__MODULE__{} = module, inputs), do: module.forward_fn.(module, inputs)
  end

  # Upstream FailingModule (tests/predict/test_parallel.py::test_batch_with_failed_examples):
  # forward raises for one input value.
  defmodule FailingModule do
    @behaviour Imp.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, %{value: 42}), do: raise("test error")

    def call(%__MODULE__{}, %{value: value}),
      do: {:ok, Imp.prediction(result: "success-#{value}")}
  end

  # Upstream SimpleModule (tests/predict/test_parallel.py::test_batch_timeout_and_straggler_limit_params)
  defmodule SimpleDoubler do
    @behaviour Imp.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, %{value: value}), do: {:ok, Imp.prediction(result: value * 2)}
  end

  # Upstream DummyLM mode 1 (list of dicts, one per call): an arity-2 fn LM
  # backed by an Agent that pops the next scripted response (and keeps
  # returning the last one when exhausted, so count-sensitive tests fail on
  # counts rather than on artificial LM crashes).
  defp dummy_lm(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _messages, _opts ->
      response =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      {:ok, response}
    end
  end

  defp capture_lm(response_fun) do
    test_pid = self()

    fn messages, opts ->
      send(test_pid, {:lm_call, messages, opts})
      response_fun.(messages)
    end
  end

  # Upstream DummyVectorizer (dspy/utils/dummies.py): character-bigram counts
  # bucketed by a polynomial hash, mean-centered and L2-normalized. Ported with
  # fixed hash coefficients (Python's random.seed(123) stream is not
  # reproducible on the BEAM; the geometry the KNN tests rely on — shared
  # bigrams dominate the dot product — is preserved).
  @vec_max_length 100
  @vec_coeffs [982_451_653, 32_452_843]
  @vec_p 1_000_000_007

  defp bigram_hash(gram) do
    gram
    |> String.to_charlist()
    |> Enum.zip(@vec_coeffs)
    |> Enum.reduce(1, fn {c, coeff}, h -> rem(h * coeff + c, @vec_p) end)
    |> rem(@vec_max_length)
  end

  defp dummy_vectorize(text) do
    grams =
      if String.length(text) < 2 do
        []
      else
        for i <- 0..(String.length(text) - 2), do: String.slice(text, i, 2)
      end

    counts =
      Enum.reduce(grams, %{}, fn gram, acc ->
        Map.update(acc, bigram_hash(gram), 1, &(&1 + 1))
      end)

    vec = for i <- 0..(@vec_max_length - 1), do: Map.get(counts, i, 0) * 1.0
    mean = Enum.sum(vec) / @vec_max_length
    centered = Enum.map(vec, &(&1 - mean))
    norm = :math.sqrt(Enum.reduce(centered, 0.0, fn x, acc -> acc + x * x end)) + 1.0e-10
    Enum.map(centered, &(&1 / norm))
  end

  defp dummy_vectorizer, do: fn texts, _opts -> {:ok, Enum.map(texts, &dummy_vectorize/1)} end

  defp mock_example(question, answer) do
    Imp.example(question: question, answer: answer) |> Imp.with_inputs([:question])
  end

  defp knn_fixture do
    trainset = [
      mock_example("What is the capital of France?", "Paris"),
      mock_example("What is the largest ocean?", "Pacific"),
      mock_example("What is 2+2?", "4")
    ]

    Imp.Predict.KNN.new(2, trainset, vectorizer: dummy_vectorizer())
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_aggregation.py
  # ---------------------------------------------------------------------------

  describe "test_aggregation.py" do
    # Upstream: test_majority_with_prediction — DSPy's majority returns a
    # Prediction whose first completion holds the winning answer; Imp's
    # majority/2 returns the winning value directly (documented design
    # substitution — no Completions container in Imp).
    test "majority with predictions" do
      predictions = [
        Imp.prediction(answer: "2"),
        Imp.prediction(answer: "2"),
        Imp.prediction(answer: "3")
      ]

      assert Imp.majority(predictions, field: :answer) == "2"
    end

    # Upstream: test_majority_with_list
    test "majority with list" do
      completions = [%{answer: "2"}, %{answer: "2"}, %{answer: "3"}]
      assert Imp.majority(completions, field: :answer) == "2"
    end

    # Upstream: test_majority_with_normalize (normalize_text strips/lowercases;
    # " 2" groups with "2")
    test "majority with normalize" do
      normalize_text = fn value -> value |> to_string() |> String.trim() |> String.downcase() end
      completions = [%{answer: "2"}, %{answer: " 2"}, %{answer: "3"}]
      assert Imp.majority(completions, field: :answer, normalize: normalize_text) == "2"
    end

    # Upstream: test_majority_with_field
    test "majority with field" do
      completions = [
        %{answer: "2", other: "1"},
        %{answer: "2", other: "1"},
        %{answer: "3", other: "2"}
      ]

      assert Imp.majority(completions, field: :other) == "1"
    end

    # Upstream: test_majority_with_no_majority — first completion wins a tie
    test "majority with no majority" do
      completions = [%{answer: "2"}, %{answer: "3"}, %{answer: "4"}]
      assert Imp.majority(completions, field: :answer) == "2"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_best_of_n.py
  # ---------------------------------------------------------------------------

  describe "test_best_of_n.py" do
    # Upstream: test_refine_forward_success_first_attempt (BestOfN variant).
    # The reward is never 1.0 (answers are longer than one character), so the
    # module must run exactly N=3 times and the best (first, tie-first) answer
    # "Brussels" wins.
    test "best_of_n runs all N attempts and keeps the best" do
      lm =
        dummy_lm([
          %{answer: "Brussels"},
          %{answer: "City of Brussels"},
          %{answer: "Brussels"}
        ])

      {:ok, module_calls} = Agent.start_link(fn -> 0 end)
      {:ok, reward_calls} = Agent.start_link(fn -> 0 end)

      count_calls = fn module, inputs ->
        Agent.update(module_calls, &(&1 + 1))
        Imp.Predict.Predict.call(module.predictor, inputs)
      end

      reward_fn = fn _inputs, prediction ->
        Agent.update(reward_calls, &(&1 + 1))
        if String.length(Imp.get(prediction, :answer)) == 1, do: 1.0, else: 0.0
      end

      program = DummyModule.new("question -> answer", count_calls, lm: lm)
      best_of_n = Imp.best_of_n(program, reward_fn, n: 3, threshold: 1.0)

      assert {:ok, result} = Imp.call(best_of_n, %{question: "What is the capital of Belgium?"})
      assert Imp.get(result, :answer) == "Brussels"
      assert Agent.get(reward_calls, & &1) > 0
      assert Agent.get(module_calls, & &1) == 3
    end

    # Upstream: test_refine_module_default_fail_count (BestOfN variant) — a
    # module that always raises surfaces a loud error (DSPy: ValueError raised;
    # Imp: {:error, {:no_successful_predictions, _}}).
    test "best_of_n with always-failing module is a loud error" do
      always_raise = fn _module, _inputs -> raise "Deliberately failing" end
      program = DummyModule.new("question -> answer", always_raise)
      best_of_n = Imp.best_of_n(program, fn _, _ -> 1.0 end, n: 3, threshold: 0.0)

      assert {:error, _reason} =
               Imp.call(best_of_n, %{question: "What is the capital of Belgium?"})
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_chain_of_thought.py
  # ---------------------------------------------------------------------------

  describe "test_chain_of_thought.py" do
    # Upstream: test_initialization_with_string_signature — output fields are
    # [reasoning, answer] and the call answers "2".
    test "initialization with string signature" do
      lm = dummy_lm([%{reasoning: "find the number after 1", answer: "2"}])
      cot = Imp.chain_of_thought("question -> answer", lm: lm)

      assert Imp.Signature.output_names(cot.predict.signature) == [:reasoning, :answer]

      assert {:ok, prediction} = Imp.call(cot, %{question: "What is 1+1?"})
      assert Imp.get(prediction, :answer) == "2"
    end

    # Upstream: test_chain_of_thought_with_native_reasoning — the mocked
    # completion carries manual [[ ## reasoning ## ]] / [[ ## answer ## ]]
    # sections (upstream's trailing "[[ ## completion ## ]]" typo included);
    # answer parses to "Paris" and reasoning is the plain string.
    test "chain of thought with marker completion" do
      lm = fn _messages, _opts ->
        {:ok,
         "[[ ## reasoning ## ]]\nStep-by-step thinking about the capital of France\n" <>
           "[[ ## answer ## ]]\nParis\n[[ ## completion ## ]]"}
      end

      cot = Imp.chain_of_thought("question -> answer", lm: lm)

      assert {:ok, prediction} = Imp.call(cot, %{question: "What is the capital of France?"})
      assert Imp.get(prediction, :answer) == "Paris"
      assert is_binary(Imp.get(prediction, :reasoning))

      assert Imp.get(prediction, :reasoning) ==
               "Step-by-step thinking about the capital of France"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_knn.py
  # ---------------------------------------------------------------------------

  describe "test_knn.py" do
    # Upstream: test_knn_initialization
    test "knn initialization" do
      knn = knn_fixture()
      assert knn.k == 2
      assert length(knn.trainset_vectors) == 3
    end

    # Upstream: test_knn_query — "What is 3+3?" is closest to "What is 2+2?"
    test "knn query" do
      knn = knn_fixture()
      nearest = Imp.Predict.KNN.call(knn, %{question: "What is 3+3?"})

      assert length(nearest) == 2
      assert Imp.Example.get(hd(nearest), :answer) == "4"
    end

    # Upstream: test_knn_query_specificity — "capital of Germany" retrieves
    # the France example.
    test "knn query specificity" do
      knn = knn_fixture()
      nearest = Imp.Predict.KNN.call(knn, %{question: "What is the capital of Germany?"})

      assert length(nearest) == 2
      assert "Paris" in Enum.map(nearest, &Imp.Example.get(&1, :answer))
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_multi_chain_comparison.py
  # ---------------------------------------------------------------------------

  describe "test_multi_chain_comparison.py" do
    # Upstream: test_basic_example
    test "multi chain comparison basic example" do
      signature =
        Imp.Signature.new(%{
          inputs: [:question],
          outputs: [%{name: :answer, desc: "often between 1 and 5 words"}],
          instructions: "Answer questions with short factoid answers."
        })

      completions = [
        %{
          rationale: "I recall that during clear days, the sky often appears this color.",
          answer: "blue"
        },
        %{
          rationale:
            "Based on common knowledge, I believe the sky is typically seen as this color.",
          answer: "green"
        },
        %{
          rationale:
            "From images and depictions in media, the sky is frequently represented with this hue.",
          answer: "blue"
        }
      ]

      lm = dummy_lm([%{rationale: "my rationale", answer: "blue"}])
      compare_answers = Imp.multi_chain_comparison(signature, lm: lm)

      assert {:ok, final_pred} =
               Imp.call(compare_answers, %{
                 question: "What is the color of the sky?",
                 completions: completions
               })

      assert Imp.get(final_pred, :rationale) == "my rationale"
      assert Imp.get(final_pred, :answer) == "blue"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_parallel.py
  # ---------------------------------------------------------------------------

  describe "test_parallel.py" do
    # Upstream: test_parallel_module — five parallel calls each consume one
    # scripted response; all five outputs come back (order-independent).
    # (Adapted: Imp.Predict.Parallel.map takes one program + an input batch;
    # DSPy's heterogeneous (predictor, input) pair list has no Imp surface —
    # recorded in the exam table.)
    test "parallel module" do
      lm = dummy_lm(for i <- 1..5, do: %{output: "test output #{i}"})
      program = Imp.predict("input -> output", lm: lm)

      results = Imp.parallel(program, List.duplicate(%{input: "test input"}, 5))

      outputs =
        for {:ok, prediction} <- results, into: MapSet.new(), do: Imp.get(prediction, :output)

      assert outputs == MapSet.new(for i <- 1..5, do: "test output #{i}")
    end

    # Upstream: test_batch_module — a second batch through a reasoning
    # signature; each result's reasoning number matches its output number.
    test "batch module" do
      lm = dummy_lm(for i <- 1..5, do: %{output: "test output #{i}"})

      res_lm =
        dummy_lm(
          for i <- 1..5, do: %{output: "test output #{i}", reasoning: "test reasoning #{i}"}
        )

      program = Imp.predict("input -> output", lm: lm)
      program2 = Imp.predict("input -> output, reasoning", lm: res_lm)

      inputs = List.duplicate(%{input: "test input"}, 5)
      results = Imp.parallel(program, inputs)
      reason_results = Imp.parallel(program2, inputs)

      expected = MapSet.new(for i <- 1..5, do: "test output #{i}")

      outputs = for {:ok, p} <- results, into: MapSet.new(), do: Imp.get(p, :output)
      reason_outputs = for {:ok, p} <- reason_results, into: MapSet.new(), do: Imp.get(p, :output)

      assert outputs == expected
      assert reason_outputs == expected

      for {:ok, p} <- reason_results do
        num = p |> Imp.get(:output) |> String.split() |> List.last()
        assert Imp.get(p, :reasoning) == "test reasoning #{num}"
      end
    end

    # Upstream: test_batch_with_failed_examples — one failing input does not
    # take down the batch; the failure is loud in its own slot (DSPy: results
    # slot None + exceptions list; Imp: per-slot {:error, reason}).
    test "batch with failed examples" do
      results =
        Imp.parallel(%FailingModule{}, [%{value: 1}, %{value: 42}, %{value: 3}])

      assert [{:ok, first}, {:error, reason}, {:ok, third}] = results
      assert Imp.get(first, :result) == "success-1"
      assert Imp.get(third, :result) == "success-3"
      assert inspect(reason) =~ "test error"
    end

    # Upstream: test_batch_timeout_and_straggler_limit_params — the portable
    # half: a custom module batch with an explicit timeout returns the doubled
    # values in order. (straggler_limit is Python thread-pool machinery with no
    # Imp analogue — recorded in the exam table.)
    test "batch timeout params" do
      results =
        Imp.parallel(%SimpleDoubler{}, [%{value: 1}, %{value: 2}, %{value: 3}], timeout: 120_000)

      assert Enum.map(results, fn {:ok, p} -> Imp.get(p, :result) end) == [2, 4, 6]
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_predict.py
  # ---------------------------------------------------------------------------

  describe "test_predict.py" do
    # Upstream: test_initialization_with_string_signature
    test "initialization with string signature" do
      predict = Imp.predict("input1, input2 -> output")
      expected = "Given the fields `input1`, `input2`, produce the fields `output`."
      assert predict.signature.instructions == expected

      assert predict.signature.instructions ==
               Imp.signature("input1, input2 -> output").instructions
    end

    # Upstream: test_call_method
    test "call method" do
      lm = dummy_lm([%{output: "test output"}])
      predict = Imp.predict("input -> output", lm: lm)

      assert {:ok, prediction} = Imp.call(predict, %{input: "test input"})
      assert Imp.get(prediction, :output) == "test output"
    end

    # Upstream: test_forward_method
    test "forward method" do
      lm = dummy_lm([%{answer: "No more responses"}])
      program = Imp.predict("question -> answer", lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is 1+1?"})
      assert Imp.get(prediction, :answer) == "No more responses"
    end

    # Upstream: test_forward_method2
    test "forward method2" do
      lm = dummy_lm([%{answer1: "my first answer", answer2: "my second answer"}])
      program = Imp.predict("question -> answer1, answer2", lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is 1+1?"})
      assert Imp.get(prediction, :answer1) == "my first answer"
      assert Imp.get(prediction, :answer2) == "my second answer"
    end

    # Upstream: test_output_only
    test "output only" do
      lm = dummy_lm([%{output: "short answer"}])
      predictor = Imp.predict(" -> output", lm: lm)

      assert {:ok, prediction} = Imp.call(predictor, %{})
      assert Imp.get(prediction, :output) == "short answer"
    end

    # Upstream: test_instructions_after_dump_and_load_state
    test "instructions after dump and load state" do
      original = Imp.predict(Imp.signature("input -> output", "original instructions"))
      state = Imp.dump(original)

      loaded = Imp.load(state)
      assert loaded.signature.instructions == "original instructions"
    end

    # Upstream: test_demos_after_dump_and_load_state — demos survive dump ->
    # JSON round trip -> load with their content intact.
    test "demos after dump and load state" do
      signature =
        Imp.Signature.new(%{
          inputs: [%{name: :content, type: :string}, %{name: :language, type: :string}],
          outputs: [%{name: :translation, type: :string}],
          instructions: "Translate content from a language to English."
        })

      demo =
        Imp.example(content: "¿Qué tal?", language: "SPANISH", translation: "Hello there")
        |> Imp.with_inputs([:content, :language])

      original = Imp.Predict.Predict.new(signature, demos: [demo])
      state = Imp.dump(original)

      assert length(state["demos"]) == 1

      round_tripped = state |> Jason.encode!() |> Jason.decode!()
      loaded = Imp.load(round_tripped)

      assert length(loaded.demos) == 1
      assert Imp.Example.get(hd(loaded.demos), :content) == "¿Qué tal?"
    end

    # Upstream: test_signature_fields_after_dump_and_load_state — a program
    # saved to a file and loaded back carries the original signature fields,
    # not the fields of a differently declared signature.
    @tag :tmp_dir
    test "signature fields after dump and load state", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "tmp.json")

      original_signature =
        Imp.Signature.new(%{
          inputs: [%{name: :sentence, desc: "I am an innocent input!"}],
          outputs: [:sentiment],
          instructions: "I am just an instruction."
        })

      original = Imp.predict(original_signature)
      Imp.save!(original, file_path)

      new_signature =
        Imp.Signature.new(%{
          inputs: [%{name: :sentence, desc: "I am a malicious input!"}],
          outputs: [
            %{name: :sentiment, desc: "I am a malicious output!", prefix: "I am a prefix!"}
          ],
          instructions: "I am not a pure instruction."
        })

      new_instance = Imp.predict(new_signature)
      refute Imp.Signature.dump(new_instance.signature) == Imp.Signature.dump(original.signature)

      loaded = Imp.load!(file_path)
      assert Imp.Signature.dump(loaded.signature) == Imp.Signature.dump(original.signature)
    end

    # Upstream: test_named_predictors — the inner predictor is discoverable by
    # name through the program-parameters surface (Imp's named_predictors).
    test "named predictors" do
      cot = Imp.chain_of_thought("question -> answer")
      predictors = Imp.ProgramParameters.predictors(cot)

      assert [%{name: _name, predictor: %Imp.Predict.Predict{}}] = predictors
    end

    # Upstream: test_call_predict_with_chat_history (chat adapter) — a History
    # input renders as extra message turns; the LM sees 4 messages.
    test "call predict with chat history (chat adapter)" do
      lm = capture_lm(fn _messages -> {:ok, "[[ ## answer ## ]]\n100%!"} end)

      program =
        Imp.predict("question, history -> answer", adapter: Imp.Adapter.Chat, lm: lm)

      history =
        Imp.history([%{question: "what's the capital of france?", answer: "paris"}])

      assert {:ok, _prediction} =
               Imp.call(program, %{question: "are you sure that's correct?", history: history})

      assert_received {:lm_call, messages, _opts}
      assert length(messages) == 4

      assert to_string(Enum.at(messages, 1).content) =~ "what's the capital of france?"
      assert to_string(Enum.at(messages, 2).content) =~ "paris"
      assert to_string(Enum.at(messages, 3).content) =~ "are you sure that's correct"
    end

    # Upstream: test_call_predict_with_chat_history (json adapter) — the LM
    # returns a single-quoted JSON object (json-repair path).
    test "call predict with chat history (json adapter)" do
      lm = capture_lm(fn _messages -> {:ok, "{'answer':'100%'}"} end)

      program =
        Imp.predict("question, history -> answer", adapter: Imp.Adapter.JSON, lm: lm)

      history =
        Imp.history([%{question: "what's the capital of france?", answer: "paris"}])

      assert {:ok, prediction} =
               Imp.call(program, %{question: "are you sure that's correct?", history: history})

      assert Imp.get(prediction, :answer) == "100%"

      assert_received {:lm_call, messages, _opts}
      assert length(messages) == 4

      assert to_string(Enum.at(messages, 1).content) =~ "what's the capital of france?"
      assert to_string(Enum.at(messages, 2).content) =~ "paris"
      assert to_string(Enum.at(messages, 3).content) =~ "are you sure that's correct"
    end

    # Upstream: test_positional_arguments — calling with a bare value instead
    # of named inputs is a loud error (DSPy: ValueError; Imp: error tuple).
    test "positional arguments" do
      program = Imp.predict("question -> answer")

      assert {:error, {:invalid_predict_inputs, _message}} =
               Imp.call(program, "What is the capital of France?")
    end

    # Upstream: test_extra_fields_warning — input keys not in the signature
    # log a warning containing "not in signature" and the offending key names;
    # the extras are ignored and the call still succeeds
    # (dspy/predict/predict.py logger.warning). Regression for de-hzcv gap #2:
    # pre-fix Imp dropped the extra keys silently, so the log assertions below
    # fail on pre-fix code.
    test "extra fields warning" do
      lm = dummy_lm([%{answer: "test output"}])
      program = Imp.predict("question -> answer", lm: lm)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _prediction} =
                   Imp.call(program, %{
                     question: "test",
                     extra_field: "should warn",
                     another: "also warn"
                   })
        end)

      assert log =~ "not in signature"
      assert log =~ "extra_field"
      assert log =~ "another"
    end

    # Upstream: test_error_message_on_invalid_lm_setup — no LM is a loud
    # error; a bogus LM value is rejected loudly (Imp validates at
    # construction rather than at call time; seam recorded in the exam table).
    test "error message on invalid lm setup" do
      assert {:error, :lm_not_configured} =
               Imp.call(Imp.predict("question -> answer"), %{
                 question: "Why did a chicken cross the kitchen?"
               })

      assert_raise ArgumentError, fn ->
        Imp.predict("question -> answer", lm: "openai/gpt-4o-mini")
      end
    end

    # Upstream: test_explicitly_valued_enum_inputs_and_outputs — an
    # enum-constrained output parses the enum value. (Partial: Imp enums are
    # string-valued constraints, not Python Enum members.)
    test "explicitly valued enum inputs and outputs" do
      lm =
        dummy_lm([
          %{
            reasoning: "The current status is 'PENDING', advancing to 'IN_PROGRESS'.",
            next_status: "in_progress"
          }
        ])

      signature =
        Imp.Signature.new(%{
          inputs: [
            %{
              name: :current_status,
              type: :string,
              constraints: %{enum: ["pending", "in_progress", "completed"]}
            }
          ],
          outputs: [
            %{
              name: :next_status,
              type: :string,
              constraints: %{enum: ["pending", "in_progress", "completed"]}
            }
          ]
        })

      program = Imp.predict(signature, lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{current_status: "pending"})
      assert Imp.get(prediction, :next_status) == "in_progress"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_program_of_thought.py
  # ---------------------------------------------------------------------------

  describe "test_program_of_thought.py" do
    # Upstream: test_pot_code_generation — the planner's generated program is
    # executed and the answer comes back. (Design substitution: Imp generates
    # a safe Elixir expression run in Imp.Sandbox, not Python in Deno, and
    # projects the value directly instead of a second extraction LM call.)
    test "pot code generation" do
      lm = dummy_lm([%{program: "1+1"}])
      pot = Imp.program_of_thought("question -> answer")
      pot = %{pot | predict: %{pot.predict | lm: lm, dynamic_lm?: false}}

      assert {:ok, prediction} = Imp.call(pot, %{question: "What is 1+1?"})
      assert Imp.get(prediction, :answer) == 2
    end

    # Upstream: test_pot_code_generation_with_one_error — the first program
    # fails at runtime, the regenerated program succeeds.
    test "pot code generation with one error" do
      lm =
        dummy_lm([
          %{program: "1 + no_such_variable"},
          %{program: "1+1"}
        ])

      pot = Imp.program_of_thought("question -> answer", lm: lm)

      assert {:ok, prediction} = Imp.call(pot, %{question: "What is 1+1?"})
      assert Imp.get(prediction, :answer) == 2
    end

    # Upstream: test_pot_code_generation_persistent_errors — a program that
    # keeps failing exhausts max_iters loudly (DSPy: RuntimeError "Max hops
    # reached"; Imp: {:error, ...} tuple).
    test "pot code generation persistent errors" do
      lm = dummy_lm([%{program: "1 + no_such_variable"}])
      pot = Imp.program_of_thought("question -> answer", lm: lm, max_iters: 3)

      assert {:error, _reason} = Imp.call(pot, %{question: "What is 1+1?"})
    end

    # Upstream: test_pot_support_multiple_fields — the generated program
    # produces both declared outputs.
    test "pot support multiple fields" do
      # Untyped outputs are str (as upstream); the program yields string values.
      lm = dummy_lm([%{program: ~S/%{maximum: "6", minimum: "2"}/}])
      pot = Imp.program_of_thought("input_list -> maximum, minimum", lm: lm)

      assert {:ok, prediction} = Imp.call(pot, %{input_list: "2, 3, 5, 6"})
      assert to_string(Imp.get(prediction, :maximum)) == "6"
      assert to_string(Imp.get(prediction, :minimum)) == "2"
    end

    # Upstream: test_pot_code_parse_error — code that never parses exhausts
    # max_iters loudly and is never executed. (The mock-on-_execute_code half
    # is Python patching; the loud max-iters error is the ported behavior.)
    test "pot code parse error" do
      lm = dummy_lm([%{program: "invalid=elixir=code"}])
      pot = Imp.program_of_thought("question -> answer", lm: lm, max_iters: 3)

      assert {:error, _reason} = Imp.call(pot, %{question: "What is 1+1?"})
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_code_act.py
  # ---------------------------------------------------------------------------

  describe "test_code_act.py" do
    # Upstream: test_codeact_tool_validation — invalid tool entries are
    # rejected loudly at construction.
    test "codeact tool validation" do
      assert_raise ArgumentError, fn ->
        Imp.code_act("question -> answer", ["not a tool"])
      end
    end

    # Upstream: test_codeact_code_generation — a tool observation feeds the
    # final answer. (Design substitution: Imp CodeAct plans discrete tool or
    # Elixir-program steps; tools are not callable from inside generated code.)
    test "codeact code generation" do
      add = Imp.tool(:add, "add two numbers", fn %{a: a, b: b} -> a + b end)

      lm =
        dummy_lm([
          %{tool: "add", arguments: %{a: 1, b: 1}},
          %{program: "observation", finished: true},
          %{answer: "2"}
        ])

      program = Imp.code_act("question -> answer", [add], lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is 1+1?"})
      assert to_string(Imp.get(prediction, :answer)) == "2"
    end

    # Upstream: test_codeact_support_multiple_fields
    test "codeact support multiple fields" do
      extract =
        Imp.tool(:extract_maximum_minimum, "max and min", fn %{input_list: input_list} ->
          numbers =
            input_list
            |> String.split(",")
            |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))

          %{maximum: Enum.max(numbers), minimum: Enum.min(numbers)}
        end)

      lm =
        dummy_lm([
          %{tool: "extract_maximum_minimum", arguments: %{input_list: "2, 3, 5, 6"}},
          %{program: "observation", finished: true},
          %{maximum: "6", minimum: "2"}
        ])

      program = Imp.code_act("input_list -> maximum, minimum", [extract], lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{input_list: "2, 3, 5, 6"})
      assert to_string(Imp.get(prediction, :maximum)) == "6"
      assert to_string(Imp.get(prediction, :minimum)) == "2"
    end

    # Upstream: test_codeact_code_parse_failure — an unparsable program is a
    # recoverable observation; the next generation succeeds.
    test "codeact code parse failure" do
      lm =
        dummy_lm([
          %{program: "parse(error"},
          %{program: "1 + 1", finished: true},
          %{answer: "2"}
        ])

      program = Imp.code_act("question -> answer", [], lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is 1+1?"})
      assert to_string(Imp.get(prediction, :answer)) == "2"
    end

    # Upstream: test_codeact_code_execution_failure — a runtime failure is a
    # recoverable observation; the next generation succeeds.
    test "codeact code execution failure" do
      lm =
        dummy_lm([
          %{program: "unknown + 1"},
          %{program: "1 + 1", finished: true},
          %{answer: "2"}
        ])

      program = Imp.code_act("question -> answer", [], lm: lm)

      assert {:ok, prediction} = Imp.call(program, %{question: "What is 1+1?"})
      assert to_string(Imp.get(prediction, :answer)) == "2"
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_react.py
  # ---------------------------------------------------------------------------

  describe "test_react.py" do
    # Upstream: test_tool_calling_without_typehint — one tool call, then
    # finish, then extraction. The trajectory (Imp: prediction :history)
    # records thought/tool/args/observation, with "Completed." for finish.
    test "tool calling without typehint" do
      foo = Imp.tool(:foo, "Add two numbers.", fn %{a: a, b: b} -> a + b end)

      lm =
        dummy_lm([
          %{
            next_thought: "I need to add two numbers.",
            next_tool_name: "foo",
            next_tool_args: %{a: 1, b: 2}
          },
          %{
            next_thought: "I have the sum, now I can finish.",
            next_tool_name: "finish",
            next_tool_args: %{}
          },
          %{reasoning: "I added the numbers successfully", c: 3}
        ])

      react = Imp.react("a, b -> c: integer", [foo], lm: lm, mode: :dspy_3_2_1)

      assert {:ok, outputs} = Imp.call(react, %{a: 1, b: 2})
      assert Imp.get(outputs, :c) == 3

      assert [first, second] = Imp.get(outputs, :history)
      assert first.thought == "I need to add two numbers."
      assert to_string(first.tool) == "foo"
      assert first.arguments == %{a: 1, b: 2}
      assert first.result == 3

      assert second.thought == "I have the sum, now I can finish."
      assert to_string(second.tool) == "finish"
      assert second.arguments == %{}
      assert second.result == "Completed."
    end

    # Upstream: test_error_retry — a tool that always raises leaves error
    # observations in the trajectory; max_iters=2 (call-level override) stops
    # the loop and extraction still answers.
    test "error retry" do
      foo = Imp.tool(:foo, "always fails", fn _args -> raise "tool error" end)

      lm =
        dummy_lm([
          %{
            next_thought: "I need to add two numbers.",
            next_tool_name: "foo",
            next_tool_args: %{a: 1, b: 2}
          },
          %{
            next_thought: "I need to add two numbers.",
            next_tool_name: "foo",
            next_tool_args: %{a: 1, b: 2}
          },
          %{reasoning: "I added the numbers successfully", c: 3}
        ])

      react = Imp.react("a, b -> c: integer", [foo], lm: lm, mode: :dspy_3_2_1)

      assert {:ok, outputs} = Imp.call(react, %{a: 1, b: 2, max_iters: 2})
      assert Imp.get(outputs, :c) == 3

      assert [first, second] = Imp.get(outputs, :history)

      for entry <- [first, second] do
        assert entry.thought == "I need to add two numbers."
        assert to_string(entry.tool) == "foo"
        assert entry.arguments == %{a: 1, b: 2}
        assert to_string(entry.result) =~ "tool error"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_refine.py
  # ---------------------------------------------------------------------------

  describe "test_refine.py" do
    # Upstream: test_refine_forward_success_first_attempt — the reward never
    # reaches the threshold, so the module runs exactly N=3 times and the best
    # answer is "Brussels".
    test "refine runs all attempts and keeps the best" do
      lm =
        dummy_lm([
          %{answer: "Brussels"},
          %{answer: "City of Brussels"},
          %{answer: "Brussels"}
        ])

      {:ok, module_calls} = Agent.start_link(fn -> 0 end)
      {:ok, reward_calls} = Agent.start_link(fn -> 0 end)

      count_calls = fn module, inputs ->
        Agent.update(module_calls, &(&1 + 1))
        Imp.Predict.Predict.call(module.predictor, inputs)
      end

      reward_fn = fn _inputs, prediction ->
        Agent.update(reward_calls, &(&1 + 1))
        if String.length(Imp.get(prediction, :answer)) == 1, do: 1.0, else: 0.0
      end

      program = DummyModule.new("question -> answer", count_calls, lm: lm)
      refine = Imp.refine(program, reward_fn, max_attempts: 3, threshold: 1.0)

      assert {:ok, result} = Imp.call(refine, %{question: "What is the capital of Belgium?"})
      assert Imp.get(result, :answer) == "Brussels"
      assert Agent.get(reward_calls, & &1) > 0
      assert Agent.get(module_calls, & &1) == 3
    end

    # Upstream: test_refine_module_default_fail_count — an always-raising
    # module is a loud error.
    test "refine with always-failing module is a loud error" do
      always_raise = fn _module, _inputs -> raise "Deliberately failing" end
      program = DummyModule.new("question -> answer", always_raise)
      refine = Imp.refine(program, fn _, _ -> 1.0 end, max_attempts: 3, threshold: 0.0)

      assert {:error, _reason} = Imp.call(refine, %{question: "What is the capital of Belgium?"})
    end

    # Upstream: test_refine_module_custom_fail_count — with fail_count=1 the
    # second failure aborts the run: the module is called exactly 2 times.
    test "refine with custom fail count" do
      lm = dummy_lm([%{answer: "Brussels"}])

      {:ok, module_calls} = Agent.start_link(fn -> 0 end)

      raise_on_first_two = fn module, inputs ->
        calls = Agent.get_and_update(module_calls, &{&1 + 1, &1 + 1})

        if calls <= 2 do
          raise "Deliberately failing"
        else
          Imp.Predict.Predict.call(module.predictor, inputs)
        end
      end

      program = DummyModule.new("question -> answer", raise_on_first_two, lm: lm)

      refine =
        Imp.refine(program, fn _, _ -> 1.0 end,
          max_attempts: 3,
          threshold: 0.0,
          fail_count: 1
        )

      assert {:error, _reason} = Imp.call(refine, %{question: "What is the capital of Belgium?"})
      assert Agent.get(module_calls, & &1) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # tests/predict/test_rlm.py
  # ---------------------------------------------------------------------------

  describe "test_rlm.py" do
    # Upstream: TestRLMInitialization::test_basic_initialization
    test "rlm basic initialization" do
      rlm = Imp.rlm("context, query -> answer", max_iterations: 5)

      assert rlm.max_iterations == 5
      assert rlm.tools == %{}
      assert :context in Imp.Signature.input_names(rlm.signature)
      assert :query in Imp.Signature.input_names(rlm.signature)
      assert :answer in Imp.Signature.output_names(rlm.signature)
    end

    # Upstream: TestRLMInitialization::test_custom_signature
    test "rlm custom signature" do
      rlm = Imp.rlm("document, question -> summary, key_facts", max_iterations: 5)

      assert :document in Imp.Signature.input_names(rlm.signature)
      assert :question in Imp.Signature.input_names(rlm.signature)
      assert :summary in Imp.Signature.output_names(rlm.signature)
      assert :key_facts in Imp.Signature.output_names(rlm.signature)
    end

    # Upstream: TestRLMInitialization::test_custom_tools
    test "rlm custom tools" do
      custom_tool = Imp.tool(:custom_tool, "upcase", fn %{x: x} -> String.upcase(x) end)
      rlm = Imp.rlm("context -> answer", max_iterations: 5, tools: [custom_tool])

      assert Map.has_key?(rlm.tools, :custom_tool)
      assert map_size(rlm.tools) == 1
    end

    # Upstream: TestRLMInitialization::test_tool_validation_not_callable —
    # non-tool entries are rejected loudly at construction.
    test "rlm tool validation not callable" do
      assert_raise ArgumentError, fn ->
        Imp.rlm("context -> answer", tools: ["not a function"])
      end

      assert_raise ArgumentError, fn ->
        Imp.rlm("context -> answer", tools: [123])
      end
    end

    # Upstream: TestRLMInitialization::test_optional_parameters — defaults.
    test "rlm optional parameters" do
      rlm = Imp.rlm("context -> answer")
      assert rlm.max_llm_calls == 50
      assert rlm.sub_lm == nil
    end

    # Upstream: TestRLMInitialization::test_forward_validates_required_inputs
    test "rlm forward validates required inputs" do
      lm = fn _messages, _opts -> {:ok, %{reasoning: "noop", code: "1"}} end
      rlm = Imp.rlm("context, query -> answer", max_iterations: 3, lm: lm)

      assert {:error, {:missing_input_fields, missing}} =
               Imp.call(rlm, %{context: "some context"})

      assert :query in missing
    end

    # Upstream: TestRLMWithDummyLM::test_simple_computation_e2e — the
    # controller computes and submits; the typed output comes back as an int.
    # (Design substitution: Imp's controller writes safe Elixir with
    # `submit/1`, not sandboxed Python with SUBMIT.)
    test "rlm simple computation e2e" do
      lm =
        dummy_lm([
          %{reasoning: "I need to compute 2 + 3", code: "submit(%{answer: 2 + 3})"}
        ])

      rlm = Imp.rlm("query -> answer: integer", max_iterations: 3, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "What is 2 + 3?"})
      assert Imp.get(prediction, :answer) == 5
    end

    # Upstream: TestRLMWithDummyLM::test_multi_turn_computation_e2e —
    # interpreter state persists across turns before the final submit.
    test "rlm multi turn computation e2e" do
      lm =
        dummy_lm([
          %{reasoning: "First explore the data", code: "x = 10"},
          %{reasoning: "Now compute and return", code: "submit(%{answer: x * 2})"}
        ])

      rlm = Imp.rlm("query -> answer: integer", max_iterations: 5, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "Double ten"})
      assert Imp.get(prediction, :answer) == 20
    end

    # Upstream: TestRLMWithDummyLM::test_with_input_variables_e2e — inputs are
    # live variables inside the interpreter. (Adapted: Imp's constrained
    # interpreter allowlist has no Enum.sum/reduce, so the sum is spelled with
    # allowlisted Enum.at — the behavior under test, computing over an injected
    # input variable, is unchanged. Gap recorded in the exam table.)
    test "rlm with input variables e2e" do
      lm =
        dummy_lm([
          %{
            reasoning: "Sum the numbers in the list",
            code:
              "submit(%{total: Enum.at(numbers, 0) + Enum.at(numbers, 1) + " <>
                "Enum.at(numbers, 2) + Enum.at(numbers, 3) + Enum.at(numbers, 4)})"
          }
        ])

      rlm = Imp.rlm("numbers: array[integer] -> total: integer", max_iterations: 3, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{numbers: [1, 2, 3, 4, 5]})
      assert Imp.get(prediction, :total) == 15
    end

    # Upstream: TestRLMWithDummyLM::test_with_tool_e2e — a registered
    # host-side tool is callable from generated code.
    test "rlm with tool e2e" do
      lookup =
        Imp.tool(:lookup, "fruit colors", fn %{key: key} ->
          Map.get(%{"apple" => "red", "banana" => "yellow"}, key, "unknown")
        end)

      lm =
        dummy_lm([
          %{
            reasoning: "Look up the color of apple",
            code: ~S|color = lookup(%{key: "apple"})
submit(%{color: color})|
          }
        ])

      rlm = Imp.rlm("fruit -> color", max_iterations: 3, tools: [lookup], lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{fruit: "apple"})
      assert Imp.get(prediction, :color) == "red"
    end

    # Upstream: TestRLMToolExceptions::test_tool_exception_returns_error_in_output
    # — a raising tool is a recorded error the controller can recover from.
    test "rlm tool exception returns error in output" do
      failing_tool = Imp.tool(:failing_tool, "always fails", fn _args -> raise "Tool failed!" end)

      lm =
        dummy_lm([
          %{reasoning: "Call tool", code: "failing_tool(%{})"},
          %{reasoning: "Recover", code: ~S|submit(%{answer: "recovered"})|}
        ])

      rlm = Imp.rlm("query -> answer", max_iterations: 5, tools: [failing_tool], lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "test"})
      assert Imp.get(prediction, :answer) == "recovered"
    end

    # Upstream: TestRLMToolExceptions::test_syntax_error_from_execute_is_recoverable
    # — unparsable code is an iteration error, not a crash.
    test "rlm syntax error is recoverable" do
      lm =
        dummy_lm([
          %{reasoning: "Bad code", code: "def incomplete("},
          %{reasoning: "Recover", code: ~S|submit(%{answer: "recovered"})|}
        ])

      rlm = Imp.rlm("query -> answer", max_iterations: 5, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "test"})
      assert Imp.get(prediction, :answer) == "recovered"
    end

    # Upstream: TestRLMTypeCoercionMock::test_type_coercion — submitted values
    # come back as the declared output types.
    test "rlm type coercion" do
      cases = [
        {"count: integer", :count, "submit(%{count: 42})", 42},
        {"score: float", :score, "submit(%{score: 3.14})", 3.14},
        {"valid: boolean", :valid, "submit(%{valid: true})", true},
        {"numbers: array[integer]", :numbers, "submit(%{numbers: [1, 2, 3]})", [1, 2, 3]}
      ]

      for {spec, field, code, expected} <- cases do
        lm = dummy_lm([%{reasoning: "Return value", code: code}])
        rlm = Imp.rlm("query -> #{spec}", max_iterations: 3, lm: lm)

        assert {:ok, prediction} = Imp.call(rlm, %{query: "test"})
        assert Imp.get(prediction, field) == expected
      end
    end

    # Upstream: TestRLMTypeCoercionMock::test_type_error_retries — an invalid
    # enum submission is rejected and the controller retries with a valid one.
    test "rlm type error retries" do
      lm =
        dummy_lm([
          %{reasoning: "Try maybe", code: ~S|submit(%{answer: "maybe"})|},
          %{reasoning: "Try yes", code: ~S|submit(%{answer: "yes"})|}
        ])

      signature =
        Imp.Signature.new(%{
          inputs: [:query],
          outputs: [%{name: :answer, type: :string, constraints: %{enum: ["yes", "no"]}}]
        })

      rlm = Imp.rlm(signature, max_iterations: 5, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "is it yes?"})
      assert Imp.get(prediction, :answer) == "yes"
    end

    # Upstream: TestRLMMultipleOutputs::test_multi_output_final_kwargs — Imp's
    # submit/1 takes a map of all output fields (Python kwargs/positional
    # calling conventions collapse to the map form).
    test "rlm multi output submit" do
      lm =
        dummy_lm([
          %{reasoning: "Return both outputs", code: ~S|submit(%{name: "alice", count: 5})|}
        ])

      rlm = Imp.rlm("query -> name, count: integer", max_iterations: 3, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "test"})
      assert Imp.get(prediction, :name) == "alice"
      assert Imp.get(prediction, :count) == 5
    end

    # Upstream: TestRLMMultipleOutputs::test_multi_output_final_missing_field_errors
    # — a submit missing a declared output is an error the controller retries.
    test "rlm multi output missing field errors" do
      lm =
        dummy_lm([
          %{reasoning: "Missing count field", code: ~S|submit(%{name: "alice"})|},
          %{reasoning: "Now provide both", code: ~S|submit(%{name: "alice", count: 5})|}
        ])

      rlm = Imp.rlm("query -> name, count: integer", max_iterations: 3, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "test"})
      assert Imp.get(prediction, :name) == "alice"
      assert Imp.get(prediction, :count) == 5
    end

    # Upstream: TestRLMMaxIterationsFallback::test_max_iterations_triggers_extract
    # — exhausting max_iterations falls back to the extraction program.
    test "rlm max iterations triggers extract" do
      lm =
        dummy_lm([
          %{reasoning: "Explore 1", code: ~S|print("exploring")|},
          %{reasoning: "Explore 2", code: ~S|print("exploring")|},
          %{reasoning: "Explore 3", code: ~S|print("exploring")|},
          %{answer: "extracted_answer"}
        ])

      rlm = Imp.rlm("query -> answer", max_iterations: 3, lm: lm)

      assert {:ok, prediction} = Imp.call(rlm, %{query: "test"})
      assert Imp.get(prediction, :answer) == "extracted_answer"
    end
  end
end
