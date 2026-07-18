defmodule ProductionAdapterPersistenceTest do
  use ExUnit.Case

  test "typed signatures coerce adapter outputs" do
    signature = Imp.signature("question: string -> score: int")
    assert [:question] == Imp.Signature.input_names(signature)

    assert [%{name: :score, type: :integer}] =
             Enum.map(signature.outputs, &Map.take(&1, [:name, :type]))

    assert {:ok, prediction} = Imp.Adapter.JSON.parse(signature, ~s({"score": "42"}), [])
    assert Imp.Prediction.get(prediction, :score) == 42
  end

  test "string output fields accept scalar provider JSON values" do
    signature = Imp.signature("question -> answer")

    assert {:ok, prediction} = Imp.Adapter.JSON.parse(signature, %{"answer" => 42}, [])
    assert Imp.Prediction.get(prediction, :answer) == "42"
  end

  test "JSON adapter emits DSPy JSONAdapter system + user messages (no invented message)" do
    # DSPy 3.2.1 JSONAdapter emits exactly two messages: one system message and
    # one user message. There is no second "Return only a JSON object" system
    # message (that was an Imp invention DSPy never emits).
    signature = Imp.signature("question -> answer", "Answer from the supplied context.")

    assert [
             %{role: :system, content: system},
             %{role: :user, content: user}
           ] = Imp.Adapter.JSON.format(signature, %{question: "q"}, [])

    assert system =~ "Your input fields are:"
    assert system =~ "Your output fields are:"
    assert system =~ "Inputs will have the following structure:"
    assert system =~ "Outputs will be a JSON object with the following fields."
    assert system =~ "Answer from the supplied context."
    refute system =~ "Return only a JSON object"

    assert user =~ "[[ ## question ## ]]\nq"
    assert user =~ "Respond with a JSON object in the following order of fields: `answer`."
  end

  test "JSON adapter includes output field descriptions and the JSON object template" do
    signature =
      "question -> answer: string \"final numeric answer\""
      |> Imp.signature("Solve the problem.")
      |> Imp.Signature.prepend_output(%{
        name: :reasoning,
        desc: "Work through the problem step by step before giving the final answer"
      })

    [%{role: :system, content: system}, %{role: :user}] =
      Imp.Adapter.JSON.format(signature, %{question: "q"}, [])

    # Descriptions live in the field-description block (DSPy get_field_description_string).
    assert system =~
             "`reasoning` (str): Work through the problem step by step before giving the final answer"

    assert system =~ "`answer` (str): final numeric answer"

    # Outputs are rendered as a JSON object template (both str fields carry no note).
    assert system =~ "Outputs will be a JSON object with the following fields."
    assert system =~ ~s({\n  "reasoning": "{reasoning}",\n  "answer": "{answer}"\n})
  end

  test "adapters validate owned options while ignoring provider options they do not own" do
    signature = Imp.signature("question -> answer")

    assert [%{role: :system}, %{role: :user}] =
             Imp.Adapter.Chat.format(signature, %{question: "q"},
               temperature: 0,
               response_instruction: false
             )

    assert_raise ArgumentError,
                 ~r/Imp.Adapter.Chat.format\/3.*:response_instruction.*expected.*boolean/s,
                 fn ->
                   Imp.Adapter.Chat.format(signature, %{question: "q"},
                     response_instruction: :sometimes
                   )
                 end

    assert_raise ArgumentError, ~r/Imp.Adapter.Chat.format\/3.*:demos.*expects a demo/s, fn ->
      Imp.Adapter.Chat.format(signature, %{question: "q"}, demos: :not_demos)
    end

    assert_raise ArgumentError, ~r/Imp.Adapter.Chat.format\/3.*:demos.*expects demos/s, fn ->
      Imp.Adapter.Chat.format(signature, %{question: "q"}, demos: [:not_a_demo])
    end

    assert_raise ArgumentError, ~r/Imp.Adapter.Chat.parse\/3 expects keyword options/, fn ->
      Imp.Adapter.Chat.parse(signature, %{"answer" => "ok"}, %{unused: true})
    end

    assert_raise ArgumentError, ~r/Imp.Adapter.JSON.format\/3 expects keyword options/, fn ->
      Imp.Adapter.JSON.format(signature, %{question: "q"}, %{native_json_schema: true})
    end

    assert_raise ArgumentError,
                 ~r/Imp.Adapter.JSON.lm_opts\/2.*:native_json_schema.*expected.*boolean/s,
                 fn ->
                   Imp.Adapter.JSON.lm_opts(signature, native_json_schema: :yes)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Adapter.JSON.lm_opts\/2.*:response_format.*expected a provider response_format map/s,
                 fn ->
                   Imp.Adapter.JSON.lm_opts(signature, response_format: "json_object")
                 end

    assert [response_format: %{type: "json_object"}] =
             Imp.Adapter.JSON.lm_opts(signature, temperature: 0)

    assert [] =
             Imp.Adapter.JSON.lm_opts(signature, response_format: %{type: "json_object"})
  end

  test "json adapter parses fenced provider json and rejects missing fields" do
    signature = Imp.signature("question -> answer, confidence: float")

    assert {:ok, prediction} =
             Imp.Adapter.JSON.parse(
               signature,
               """
               ```json
               {"answer": "Paris", "confidence": "0.95", "ignored": {"nested": true}}
               ```
               """,
               []
             )

    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert Imp.Prediction.get(prediction, :confidence) == 0.95

    assert {:error, {:missing_output_fields, [:confidence]}} =
             Imp.Adapter.JSON.parse(signature, ~s({"answer": "Paris"}), [])
  end

  test "chat adapter parses delimited output and falls back to JSON" do
    signature = Imp.signature("question -> answer: string, score: number")

    assert {:ok, delimited} =
             Imp.Adapter.Chat.parse(
               signature,
               """
               [[ ## answer ## ]]
               Paris
               [[ ## score ## ]]
               1.0
               """,
               []
             )

    assert Imp.Prediction.get(delimited, :answer) == "Paris"
    assert Imp.Prediction.get(delimited, :score) == 1.0

    assert {:ok, json} =
             Imp.Adapter.Chat.parse(signature, ~s({"answer":"Paris","score":1.0}), [])

    assert Imp.Prediction.get(json, :score) == 1.0
  end

  test "chat adapter reports structured field type errors without crashing" do
    signature = Imp.signature("question -> answer: string")

    assert {:error, %Imp.AdapterParseError{} = error} =
             Imp.Adapter.Chat.parse(signature, %{"answer" => %{"nested" => true}}, [])

    assert error.message =~ "answer: expected string"
    assert error.reason == %{answer: %{"nested" => true}}
  end

  test "XML adapter validates parsed fields through the shared adapter contract" do
    signature = Imp.signature("question -> answer: string, score: int")

    assert {:ok, prediction} =
             Imp.Adapter.XML.parse(
               signature,
               "<answer>Paris</answer><score>42</score>",
               []
             )

    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert Imp.Prediction.get(prediction, :score) == 42

    assert {:error, {:missing_output_fields, [:score]}} =
             Imp.Adapter.XML.parse(signature, "<answer>Paris</answer>", [])
  end

  test "chat adapter prompt shape mirrors DSPy chat objective and reminder contract" do
    signature =
      Imp.signature(
        "question, context -> answer: string \"short exact answer\"",
        "Answer using the provided context."
      )

    [%{role: :system, content: system}, %{role: :user, content: user}] =
      Imp.Adapter.Chat.format(signature, %{question: "Q?", context: "C."}, [])

    assert system =~
             "[[ ## completed ## ]]\nIn adhering to this structure, your objective is: \n        Answer using the provided context."

    assert user ==
             """
             [[ ## question ## ]]
             Q?

             [[ ## context ## ]]
             C.

             Respond with the corresponding output fields, starting with the field `[[ ## answer ## ]]`, and then ending with the marker for `[[ ## completed ## ]]`.
             """
             |> String.trim()
  end

  test "chat adapter renders answer-shape constraints in field contracts" do
    signature =
      Imp.signature(
        "question -> verdict: yes_no, amount: numeric_span, answer: short_span",
        "Extract constrained answers."
      )

    [%{role: :system, content: system}, %{role: :user}] =
      Imp.Adapter.Chat.format(signature, %{question: "Q?"}, [])

    assert system =~ "`verdict` (str): Must be exactly yes or no."

    assert system =~
             "`amount` (str): Must be only the numeric answer span, with no words or explanation."

    assert system =~
             "`answer` (str): Must be a concise exact answer span; preserve complete names, titles, locations, dates, and quantities when the task asks for them, and do not add aliases, abbreviations, conversions, or parentheticals unless explicitly requested."
  end

  test "chat adapter formats demos as DSPy-style user assistant turns" do
    signature =
      Imp.signature(
        "question, context -> answer: string, confidence: number",
        "Answer using the provided context."
      )

    complete_demo = %{
      question: "Capital?",
      context: "France: Paris.",
      answer: "Paris",
      confidence: 1.0
    }

    incomplete_demo = [question: "Largest city?", answer: "Tokyo"]

    messages =
      Imp.Adapter.Chat.format(signature, %{question: "Current?", context: "Now."},
        demos: [complete_demo, incomplete_demo]
      )

    assert [
             %{role: :system},
             %{role: :user, content: incomplete_user},
             %{role: :assistant, content: incomplete_assistant},
             %{role: :user, content: complete_user},
             %{role: :assistant, content: complete_assistant},
             %{role: :user, content: current_user}
           ] = messages

    assert incomplete_user =~
             "This is an example of the task, though some input or output fields are not supplied."

    assert incomplete_user =~ "[[ ## question ## ]]\nLargest city?"
    refute incomplete_user =~ "[[ ## context ## ]]"
    assert incomplete_assistant =~ "[[ ## answer ## ]]\nTokyo"

    assert incomplete_assistant =~
             "[[ ## confidence ## ]]\nNot supplied for this particular example."

    assert complete_user =~ "[[ ## question ## ]]\nCapital?"
    assert complete_user =~ "[[ ## context ## ]]\nFrance: Paris."
    assert complete_assistant =~ "[[ ## answer ## ]]\nParis"
    assert complete_assistant =~ "[[ ## confidence ## ]]\n1.0"

    assert current_user =~ "[[ ## question ## ]]\nCurrent?"
    assert current_user =~ "Respond with the corresponding output fields"
  end

  test "json adapter normalizes direct demo options before delegating to chat format" do
    signature = Imp.signature("question -> answer")

    messages =
      Imp.Adapter.JSON.format(signature, %{question: "Current?"},
        demos: [%{question: "Capital?", answer: "Paris"}]
      )

    assert Enum.any?(
             messages,
             &(&1.role == :assistant and &1.content =~ "[[ ## answer ## ]]\nParis")
           )
  end

  test "predict retries malformed chat output through JSON adapter fallback" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          send(parent, {:lm_call, messages, opts})

          if Keyword.get(opts, :response_format) == %{type: "json_object"} do
            ~s({"answer":"Paris","confidence":0.99})
          else
            "[[ ## answer ## ]]\nParis\n[[ ## completed ## ]]"
          end
        end
      ]
    }

    program =
      Imp.predict("question -> answer: string, confidence: number",
        lm: lm,
        adapter: Imp.Adapter.Chat,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert Imp.Prediction.get(prediction, :confidence) == 0.99

    assert_received {:lm_call, [_system, _user], opts}
    refute Keyword.has_key?(opts, :response_format)
    refute Keyword.has_key?(opts, :json_fallback)
    refute Keyword.has_key?(opts, :json_retries)

    assert_received {:lm_call, retry_messages, retry_opts}
    assert Keyword.get(retry_opts, :response_format) == %{type: "json_object"}
    refute Keyword.has_key?(retry_opts, :json_fallback)
    refute Keyword.has_key?(retry_opts, :json_retries)

    assert Enum.any?(
             retry_messages,
             &(&1.content =~ "Respond with a JSON object in the following order of fields:")
           )

    assert prediction.metadata.trace.raw == ~s({"answer":"Paris","confidence":0.99})
  end

  test "predict can disable chat JSON fallback for strict single-call behavior" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          send(parent, {:lm_call, messages, opts})
          "[[ ## answer ## ]]\nParis\n[[ ## completed ## ]]"
        end
      ]
    }

    program =
      Imp.predict("question -> answer: string, confidence: number",
        lm: lm,
        adapter: Imp.Adapter.Chat,
        config: [json_fallback: false]
      )

    assert {:error, %{reason: {:error, {:missing_output_fields, [:confidence]}}}} =
             Imp.call(program, %{question: "Capital of France?"})

    assert_received {:lm_call, [_system, _user], opts}
    refute Keyword.has_key?(opts, :response_format)
    refute_received {:lm_call, _retry_messages, _retry_opts}
  end

  test "chat adapter strips adjacent completed markers from delimited output" do
    signature = Imp.signature("question -> answer")

    assert {:ok, prediction} =
             Imp.Adapter.Chat.parse(
               signature,
               "[[ ## answer ## ]]The Conversation[[ ## completed ## ]]",
               []
             )

    assert Imp.Prediction.get(prediction, :answer) == "The Conversation"
  end

  test "chat adapter tolerates provider field markers with a missing closing hash pair" do
    signature = Imp.signature("question -> reasoning, answer")

    assert {:ok, prediction} =
             Imp.Adapter.Chat.parse(
               signature,
               """
               [[ ## reasoning ## ]]
               Arithmetic is straightforward.
               [[ ## answer ]]
               48
               [[ ## completed ## ]]
               """,
               []
             )

    assert Imp.Prediction.get(prediction, :answer) == "48"
  end

  test "JSON adapter supplies provider response format options and retry feedback" do
    signature = Imp.signature("question -> answer: string")

    assert [response_format: %{type: "json_object"}] = Imp.Adapter.JSON.lm_opts(signature, [])

    assert [response_format: %{type: "json_schema", json_schema: %{schema: schema}}] =
             Imp.Adapter.JSON.lm_opts(signature, native_json_schema: true)

    assert schema["required"] == ["answer"]
  end

  test "save/load preserves adapter and ReqLLM provider configuration" do
    lm =
      Imp.req_llm("openai:gpt-test",
        api_key: "not-persisted",
        temperature: 0,
        num_retries: 0
      )

    program = Imp.predict("question -> score: int", lm: lm, adapter: Imp.Adapter.JSON)

    path =
      Path.join(System.tmp_dir!(), "Imp-save-#{System.unique_integer([:positive])}.json")

    assert :ok = Imp.Saving.save!(program, path)
    loaded = Imp.Saving.load!(path)
    File.rm(path)

    assert loaded.adapter == Imp.Adapter.JSON

    assert %Imp.Clients.ReqLLM{
             model: "openai:gpt-test",
             opts: [temperature: 0, num_retries: 0]
           } = loaded.lm

    assert loaded.config == []
  end

  test "file persistence uses a checksummed transactional artifact envelope" do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-transactional-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    original = Imp.predict("question -> answer")
    assert :ok = Imp.Saving.save!(original, path)

    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["artifact_type"] == "imp_program_artifact"
    assert artifact["schema_version"] == 1
    assert artifact["payload_sha256"] =~ ~r/^sha256:[a-f0-9]{64}$/

    tampered = put_in(artifact, ["payload", "signature", "instructions"], "tampered")
    File.write!(path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/payload checksum mismatch/, fn ->
      Imp.Saving.load!(path)
    end

    assert :ok = Imp.Saving.save!(original, path)

    assert_raise ArgumentError, ~r/unsupported Imp program for saving/, fn ->
      Imp.Saving.save!(%Imp.Predict.BestOfN{}, path)
    end

    assert %Imp.Predict.Predict{} = Imp.Saving.load!(path)
  end

  test "file load rejects an unwrapped program state" do
    path = Path.join(System.tmp_dir!(), "imp-legacy-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Jason.encode!(Imp.Saving.dump(Imp.predict("question -> answer"))))

    assert_raise ArgumentError, ~r/not a checksummed program artifact envelope/, fn ->
      Imp.Saving.load!(path)
    end
  end

  test "portable structural program types round-trip and remain executable" do
    comparison = Imp.Predict.MultiChainComparison.new("question -> answer", m: 2)
    loaded_comparison = comparison |> Imp.Saving.dump() |> Imp.Saving.load()

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{rationale: "agreed", answer: "Paris"} end]
    }

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.call(loaded_comparison, %{
                 question: "Capital?",
                 completions: [
                   %{reasoning: "one", answer: "Paris"},
                   %{reasoning: "two", answer: "Paris"}
                 ]
               })
             end)

    assert Imp.get(prediction, :answer) == "Paris"

    examples = [
      Imp.example(question: "capital france", answer: "Paris") |> Imp.with_inputs(:question),
      Imp.example(question: "capital italy", answer: "Rome") |> Imp.with_inputs(:question)
    ]

    loaded_knn =
      Imp.Predict.KNN.new(1, examples)
      |> Imp.Saving.dump()
      |> Imp.Saving.load()

    assert [%Imp.Example{} = nearest] = Imp.Predict.KNN.call(loaded_knn, %{question: "france"})
    assert Imp.Example.get(nearest, :answer) == "Paris"
  end

  test "named callback registry round-trips callback-bearing program compositions" do
    metric = fn _example, prediction -> Imp.get(prediction, :answer) == "Paris" end
    feedback = fn _predictions -> "selected" end
    predicate = fn prediction -> Imp.get(prediction, :answer) == "Paris" end

    registry =
      Imp.Saving.Registry.new(
        answer_metric: metric,
        selection_feedback: feedback,
        paris_assertion: predicate
      )

    base = Imp.predict("question -> answer")

    programs = [
      Imp.Predict.BestOfN.new(base, metric, n: 2, feedback_fn: feedback),
      Imp.Predict.Refine.new(base, metric, max_attempts: 2),
      Imp.Predict.Assertions.new(
        base,
        [Imp.Assertion.new(:paris, predicate, message: "must be Paris")],
        strict: true
      )
    ]

    loaded =
      Enum.map(programs, fn program ->
        program
        |> Imp.dump(registry: registry)
        |> Imp.load(registry: registry)
      end)

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    Enum.each(loaded, fn program ->
      assert {:ok, prediction} =
               Imp.context([lm: lm], fn -> Imp.call(program, %{question: "Capital?"}) end)

      assert Imp.get(prediction, :answer) == "Paris"
    end)

    state = Imp.dump(hd(programs), registry: registry)

    assert_raise ArgumentError, ~r/unknown registry callback "answer_metric"/, fn ->
      Imp.load(state)
    end
  end

  test "named registry round-trips ReAct CodeAct and RLM tool graphs" do
    lookup = fn %{query: query} -> "found #{query}" end
    policy = fn name, _args -> name in [:lookup, "lookup"] end
    registry = Imp.Saving.Registry.new(lookup_runner: lookup, tool_policy: policy)
    tool = Imp.tool(:lookup, "lookup facts", lookup, schema: %{query: :string})

    react = Imp.react("question -> answer", [tool], max_iters: 0, tool_policy: policy)
    code_act = Imp.code_act("question -> answer", [tool], max_iters: 0, tool_policy: policy)

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: Imp.req_llm("openai:gpt-test", api_key: "not-persisted"),
        sub_lm: Imp.req_llm("openai:gpt-sub", api_key: "also-not-persisted"),
        tools: [tool],
        tool_policy: policy,
        max_iterations: 0,
        max_recursion_depth: 3,
        max_interpreter_steps: 2_500,
        max_interpreter_value_bytes: 2_000_000,
        max_interpreter_effects: 25
      )

    [loaded_react, loaded_code_act, loaded_rlm] =
      Enum.map([react, code_act, rlm], fn program ->
        state = Imp.dump(program, registry: registry)
        refute inspect(state) =~ "not-persisted"
        refute inspect(state) =~ "also-not-persisted"
        Imp.load(state, registry: registry)
      end)

    assert Imp.Tool.call(loaded_react.tools[:lookup], %{query: "beam"}) == "found beam"
    assert Imp.ToolPolicy.authorize(loaded_react.tool_policy, :lookup, %{}) == :ok
    assert {:error, {:react_max_iters, []}} = Imp.call(loaded_react, %{question: "q"})

    assert Imp.Tool.call(loaded_code_act.tools[:lookup], %{query: "otp"}) == "found otp"
    assert {:error, {:code_act_max_iters, 0, []}} = Imp.call(loaded_code_act, %{question: "q"})

    assert %Imp.Clients.ReqLLM{model: "openai:gpt-test", opts: []} = loaded_rlm.lm
    assert %Imp.Clients.ReqLLM{model: "openai:gpt-sub", opts: []} = loaded_rlm.sub_lm
    assert loaded_rlm.max_recursion_depth == 3
    assert loaded_rlm.max_interpreter_steps == 2_500
    assert loaded_rlm.max_interpreter_value_bytes == 2_000_000
    assert loaded_rlm.max_interpreter_effects == 25
    assert Imp.Tool.call(loaded_rlm.tools[:lookup], %{query: "rlm"}) == "found rlm"
    assert {:error, {:rlm_max_iterations, 0, []}} = Imp.call(loaded_rlm, %{question: "q"})
  end

  test "compiled executable wrappers round-trip through portable persistence" do
    base = Imp.predict("question -> answer")

    examples = [
      Imp.example(question: "capital france", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    knn_program =
      Imp.Optimizer.KNNFewShot.new(1, examples)
      |> Imp.Optimizer.KNNFewShot.compile(base)

    reducer = fn predictions -> hd(predictions) end
    registry = Imp.Saving.Registry.new(ensemble_reducer: reducer)

    ensemble =
      Imp.Optimizer.Ensemble.new(reduce_fn: reducer, deterministic: true)
      |> Imp.Optimizer.Ensemble.compile([base])

    semantic = Imp.Evaluate.SemanticF1.new()
    grounded = Imp.Evaluate.CompleteAndGrounded.new()

    [loaded_knn, loaded_ensemble, loaded_semantic, loaded_grounded] =
      Enum.map([knn_program, ensemble, semantic, grounded], fn program ->
        program |> Imp.dump(registry: registry) |> Imp.load(registry: registry)
      end)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "precision" ->
              %{reasoning: "exact", precision: 1, recall: 1, f1: 1}

            prompt =~ "completeness" ->
              %{
                reasoning: "complete",
                ground_truth_key_ideas: "a",
                system_response_key_ideas: "a",
                discussion: "same",
                completeness: 1
              }

            prompt =~ "groundedness" ->
              %{
                reasoning: "grounded",
                system_response_claims: "a",
                discussion: "supported",
                groundedness: 1
              }

            true ->
              %{answer: "Paris"}
          end
        end
      ]
    }

    Imp.context([lm: lm], fn ->
      assert {:ok, knn_prediction} = Imp.call(loaded_knn, %{question: "france"})
      assert Imp.get(knn_prediction, :answer) == "Paris"

      assert {:ok, ensemble_prediction} = Imp.call(loaded_ensemble, %{question: "capital"})
      assert Imp.get(ensemble_prediction, :answer) == "Paris"

      assert {:ok, semantic_prediction} =
               Imp.call(loaded_semantic, %{
                 question: "q",
                 ground_truth: "a",
                 system_response: "a"
               })

      assert Imp.get(semantic_prediction, :f1) == 1

      assert {:ok, grounded_prediction} =
               Imp.call(loaded_grounded, %{question: "q", context: "a", answer: "a"})

      assert Imp.get(grounded_prediction, :groundedness) == 1
    end)
  end

  test "recursive agent graphs round-trip through the named registry" do
    parent_handler = fn _agent, inputs, runtime -> {:ok, %{answer: inputs.question}, runtime} end
    child_handler = fn inputs, runtime -> {:ok, %{child: inputs.value}, runtime} end
    lookup = fn %{query: query} -> String.upcase(query) end

    registry =
      Imp.Saving.Registry.new(
        parent_handler: parent_handler,
        child_handler: child_handler,
        lookup_runner: lookup
      )

    child = Imp.Agent.new(:child, child_handler)
    tool = Imp.tool(:lookup, "uppercase", lookup)

    parent =
      Imp.Agent.new(:parent, parent_handler,
        children: [child],
        tools: [tool],
        input_schema: %{required: [:question]},
        output_schema: %{required: [:answer]},
        tool_policy: [:lookup]
      )

    loaded = parent |> Imp.dump(registry: registry) |> Imp.load(registry: registry)

    assert %Imp.Agent{children: %{child: %Imp.Agent{}}, tools: %{lookup: %Imp.Tool{}}} = loaded
    assert {:ok, %{answer: "hello"}, _runtime} = Imp.Agent.run(loaded, %{question: "hello"})
    assert Imp.Tool.call(loaded.tools.lookup, %{query: "beam"}) == "BEAM"
  end

  test "loaded pinned provider programs can be rebound through the public facade" do
    original =
      Imp.predict("question -> answer",
        lm: Imp.req_llm("openai:gpt-test", api_key: "must-not-survive")
      )

    state = Imp.dump(original)
    refute inspect(state) =~ "must-not-survive"

    loaded = Imp.load(state)

    replacement = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "rebound"} end]
    }

    rebound = Imp.with_lm(loaded, replacement)

    assert {:ok, prediction} = Imp.call(rebound, %{question: "works?"})
    assert Imp.get(prediction, :answer) == "rebound"
  end

  test "save/load preserves dynamic LM rebinding for settings-based programs" do
    program = Imp.predict("question -> answer")

    path =
      Path.join(System.tmp_dir!(), "Imp-dynamic-save-#{System.unique_integer([:positive])}.json")

    assert :ok = Imp.Saving.save!(program, path)
    loaded = Imp.Saving.load!(path)
    File.rm(path)

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "settings-ok"} end]
    }

    assert {:ok, prediction} =
             Imp.context([lm: lm, adapter: Imp.Adapter.Chat], fn ->
               Imp.call(loaded, %{question: "works?"})
             end)

    assert Imp.Prediction.get(prediction, :answer) == "settings-ok"
  end

  test "save/load preserves optimizer reports on compiled programs" do
    trainset = [
      Imp.example(question: "Capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    compiled =
      "question -> answer"
      |> Imp.predict()
      |> then(fn program ->
        Imp.Optimizer.LabeledFewShot.new(k: 1)
        |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)
      end)

    path =
      Path.join(
        System.tmp_dir!(),
        "Imp-compiled-save-#{System.unique_integer([:positive])}.json"
      )

    assert :ok = Imp.Saving.save!(compiled, path)
    loaded = Imp.Saving.load!(path)
    File.rm(path)

    assert %Imp.Optimizer.Report{optimizer: :labeled_few_shot} =
             report = Imp.Optimizer.Report.fetch(loaded)

    assert report.metadata.selected_count == 1
    assert [%{example: %Imp.Example{} = example, selected?: true}] = report.candidates
    assert Imp.Example.get(example, :answer) == "Paris"
    assert length(loaded.demos) == 1
  end

  test "save/load preserves demo input boundaries on programs" do
    demo =
      Imp.example(question: "Capital?", answer: "Paris", note: "kept")
      |> Imp.with_inputs(:question)

    loaded =
      "question -> answer"
      |> Imp.predict(demos: [demo])
      |> Imp.Saving.dump()
      |> Imp.Saving.load()

    assert [%Imp.Example{} = loaded_demo] = loaded.demos
    assert Imp.Example.to_map(loaded_demo) == Imp.Example.to_map(demo)
    assert loaded_demo.input_keys == [:question]
    assert Imp.Example.to_map(Imp.Example.inputs(loaded_demo)) == %{question: "Capital?"}

    assert Imp.Example.to_map(Imp.Example.labels(loaded_demo)) == %{
             answer: "Paris",
             note: "kept"
           }
  end

  test "save/load preserves local memory RAG programs" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: 1
      )

    path =
      Path.join(System.tmp_dir!(), "Imp-rag-save-#{System.unique_integer([:positive])}.json")

    assert :ok = Imp.Saving.save!(rag, path)
    loaded = Imp.Saving.load!(path)
    File.rm(path)

    assert %Imp.Predict.RAG{retriever: %Imp.Retrieve.Memory{}, program: program} = loaded
    assert program.dynamic_lm?

    assert {:ok, prediction} =
             Imp.context([lm: lm, adapter: Imp.Adapter.Chat], fn ->
               Imp.call(loaded, %{question: "capital France"})
             end)

    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1
  end

  test "save/load preserves explicit zero RAG retrieval limits" do
    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: 0
      )

    assert rag.k == 0
    state = Imp.Saving.dump(rag)
    assert state["k"] == 0
    assert %Imp.Predict.RAG{k: 0} = Imp.Saving.load(state)
  end

  test "save/load preserves multi-hop RAG settings and rejects missing current fields" do
    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: 1,
        hops: 2
      )

    state = Imp.Saving.dump(rag)
    assert state["hops"] == 2
    assert %Imp.Predict.RAG{hops: 2} = Imp.Saving.load(state)

    stale_state = Map.delete(state, "hops")

    assert_raise ArgumentError, ~r/missing required keys: \["hops"\]/, fn ->
      Imp.Saving.load(stale_state)
    end
  end

  test "save/load preserves ProgramOfThought programs" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2"} end]
    }

    program =
      Imp.Predict.ProgramOfThought.new("x -> doubled",
        output_field: :doubled,
        metadata: %{purpose: :portable_pot}
      )

    path =
      Path.join(System.tmp_dir!(), "Imp-pot-save-#{System.unique_integer([:positive])}.json")

    assert :ok = Imp.Saving.save!(program, path)
    loaded = Imp.Saving.load!(path)
    File.rm(path)

    assert %Imp.Predict.ProgramOfThought{
             signature: %Imp.Signature{},
             predict: %Imp.Predict.Predict{},
             output_field: :doubled
           } = loaded

    assert Imp.Signature.input_names(loaded.signature) == [:x]
    assert Imp.Signature.output_names(loaded.signature) == [:doubled]
    assert loaded.predict.metadata.purpose == :portable_pot

    assert {:ok, prediction} =
             Imp.context([lm: lm, adapter: Imp.Adapter.Chat], fn ->
               Imp.Predict.ProgramOfThought.call(loaded, %{x: 21})
             end)

    assert Imp.Prediction.get(prediction, :doubled) == 42
  end

  test "save/load preserves optimized ProgramOfThought task and planner instructions" do
    program =
      "x -> doubled"
      |> Imp.program_of_thought(output_field: :doubled)
      |> Imp.Optimizer.InstructionSearch.put_instruction("Double exactly.")
      |> Imp.Saving.dump()
      |> Imp.Saving.load()

    assert program.signature.instructions == "Double exactly."
    assert program.predict.signature.instructions == "Double exactly."

    assert program
           |> Imp.ProgramAccess.task_signature()
           |> Imp.Signature.to_spec() == "x -> doubled"

    assert program
           |> Imp.ProgramAccess.lm_signature()
           |> Imp.Signature.to_spec() == "x -> program, tool, arguments"
  end

  test "save rejects non-portable RAG retrievers explicitly" do
    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(fn _query, _opts -> {:ok, []} end)

    assert_raise ArgumentError, ~r/only Imp.Retrieve.Memory is portable/, fn ->
      Imp.Saving.dump(rag)
    end
  end
end
