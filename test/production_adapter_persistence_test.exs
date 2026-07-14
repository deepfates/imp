defmodule ProductionAdapterPersistenceTest do
  use ExUnit.Case

  test "typed signatures coerce adapter outputs" do
    signature = DSEx.signature("question: string -> score: int")
    assert [:question] == DSEx.Signature.input_names(signature)

    assert [%{name: :score, type: :integer}] =
             Enum.map(signature.outputs, &Map.take(&1, [:name, :type]))

    assert {:ok, prediction} = DSEx.Adapter.JSON.parse(signature, ~s({"score": "42"}), [])
    assert DSEx.Prediction.get(prediction, :score) == 42
  end

  test "string output fields accept scalar provider JSON values" do
    signature = DSEx.signature("question -> answer")

    assert {:ok, prediction} = DSEx.Adapter.JSON.parse(signature, %{"answer" => 42}, [])
    assert DSEx.Prediction.get(prediction, :answer) == "42"
  end

  test "JSON adapter keeps task instruction before output-format instruction" do
    signature = DSEx.signature("question -> answer", "Answer from the supplied context.")

    assert [
             %{role: :system, content: system},
             %{
               role: :system,
               content:
                 "Return only a JSON object with keys: answer. Each value must satisfy the task instruction and its field contract. answer: answer according to the task instruction Do not include extra explanation or unrelated detail outside those fields."
             },
             %{role: :user}
           ] = DSEx.Adapter.JSON.format(signature, %{question: "q"}, [])

    assert system =~ "Your input fields are:"
    assert system =~ "Your output fields are:"
    assert system =~ "Answer from the supplied context."
  end

  test "JSON adapter includes output field descriptions in the provider contract" do
    signature =
      "question -> answer: string \"final numeric answer\""
      |> DSEx.signature("Solve the problem.")
      |> DSEx.Signature.prepend_output(%{
        name: :reasoning,
        desc: "Work through the problem step by step before giving the final answer"
      })

    [_task, %{content: content}, _input] =
      DSEx.Adapter.JSON.format(signature, %{question: "q"}, [])

    assert content =~ "keys: reasoning, answer"

    assert content =~
             "reasoning: Work through the problem step by step before giving the final answer"

    assert content =~ "answer: final numeric answer"
  end

  test "adapters validate owned options while ignoring provider options they do not own" do
    signature = DSEx.signature("question -> answer")

    assert [%{role: :system}, %{role: :user}] =
             DSEx.Adapter.Chat.format(signature, %{question: "q"},
               temperature: 0,
               response_instruction: false
             )

    assert_raise ArgumentError,
                 ~r/DSEx.Adapter.Chat.format\/3.*:response_instruction.*expected.*boolean/s,
                 fn ->
                   DSEx.Adapter.Chat.format(signature, %{question: "q"},
                     response_instruction: :sometimes
                   )
                 end

    assert_raise ArgumentError, ~r/DSEx.Adapter.Chat.format\/3.*:demos.*expects a demo/s, fn ->
      DSEx.Adapter.Chat.format(signature, %{question: "q"}, demos: :not_demos)
    end

    assert_raise ArgumentError, ~r/DSEx.Adapter.Chat.format\/3.*:demos.*expects demos/s, fn ->
      DSEx.Adapter.Chat.format(signature, %{question: "q"}, demos: [:not_a_demo])
    end

    assert_raise ArgumentError, ~r/DSEx.Adapter.Chat.parse\/3 expects keyword options/, fn ->
      DSEx.Adapter.Chat.parse(signature, %{"answer" => "ok"}, %{unused: true})
    end

    assert_raise ArgumentError, ~r/DSEx.Adapter.JSON.format\/3 expects keyword options/, fn ->
      DSEx.Adapter.JSON.format(signature, %{question: "q"}, %{native_json_schema: true})
    end

    assert_raise ArgumentError,
                 ~r/DSEx.Adapter.JSON.lm_opts\/2.*:native_json_schema.*expected.*boolean/s,
                 fn ->
                   DSEx.Adapter.JSON.lm_opts(signature, native_json_schema: :yes)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx.Adapter.JSON.lm_opts\/2.*:response_format.*expected a provider response_format map/s,
                 fn ->
                   DSEx.Adapter.JSON.lm_opts(signature, response_format: "json_object")
                 end

    assert [response_format: %{type: "json_object"}] =
             DSEx.Adapter.JSON.lm_opts(signature, temperature: 0)

    assert [] =
             DSEx.Adapter.JSON.lm_opts(signature, response_format: %{type: "json_object"})
  end

  test "json adapter parses fenced provider json and rejects missing fields" do
    signature = DSEx.signature("question -> answer, confidence: float")

    assert {:ok, prediction} =
             DSEx.Adapter.JSON.parse(
               signature,
               """
               ```json
               {"answer": "Paris", "confidence": "0.95", "ignored": {"nested": true}}
               ```
               """,
               []
             )

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert DSEx.Prediction.get(prediction, :confidence) == 0.95

    assert {:error, {:missing_output_fields, [:confidence]}} =
             DSEx.Adapter.JSON.parse(signature, ~s({"answer": "Paris"}), [])
  end

  test "chat adapter parses delimited output and falls back to JSON" do
    signature = DSEx.signature("question -> answer: string, score: number")

    assert {:ok, delimited} =
             DSEx.Adapter.Chat.parse(
               signature,
               """
               [[ ## answer ## ]]
               Paris
               [[ ## score ## ]]
               1.0
               """,
               []
             )

    assert DSEx.Prediction.get(delimited, :answer) == "Paris"
    assert DSEx.Prediction.get(delimited, :score) == 1.0

    assert {:ok, json} =
             DSEx.Adapter.Chat.parse(signature, ~s({"answer":"Paris","score":1.0}), [])

    assert DSEx.Prediction.get(json, :score) == 1.0
  end

  test "chat adapter reports structured field type errors without crashing" do
    signature = DSEx.signature("question -> answer: string")

    assert {:error, %DSEx.AdapterParseError{} = error} =
             DSEx.Adapter.Chat.parse(signature, %{"answer" => %{"nested" => true}}, [])

    assert error.message =~ "answer: expected string"
    assert error.reason == %{answer: %{"nested" => true}}
  end

  test "XML adapter validates parsed fields through the shared adapter contract" do
    signature = DSEx.signature("question -> answer: string, score: int")

    assert {:ok, prediction} =
             DSEx.Adapter.XML.parse(
               signature,
               "<answer>Paris</answer><score>42</score>",
               []
             )

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert DSEx.Prediction.get(prediction, :score) == 42

    assert {:error, {:missing_output_fields, [:score]}} =
             DSEx.Adapter.XML.parse(signature, "<answer>Paris</answer>", [])
  end

  test "chat adapter prompt shape mirrors DSPy chat objective and reminder contract" do
    signature =
      DSEx.signature(
        "question, context -> answer: string \"short exact answer\"",
        "Answer using the provided context."
      )

    [%{role: :system, content: system}, %{role: :user, content: user}] =
      DSEx.Adapter.Chat.format(signature, %{question: "Q?", context: "C."}, [])

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
      DSEx.signature(
        "question -> verdict: yes_no, amount: numeric_span, answer: short_span",
        "Extract constrained answers."
      )

    [%{role: :system, content: system}, %{role: :user}] =
      DSEx.Adapter.Chat.format(signature, %{question: "Q?"}, [])

    assert system =~ "`verdict` (str): Must be exactly yes or no."

    assert system =~
             "`amount` (str): Must be only the numeric answer span, with no words or explanation."

    assert system =~
             "`answer` (str): Must be a concise exact answer span; preserve complete names, titles, locations, dates, and quantities when the task asks for them, and do not add aliases, abbreviations, conversions, or parentheticals unless explicitly requested."
  end

  test "chat adapter formats demos as DSPy-style user assistant turns" do
    signature =
      DSEx.signature(
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
      DSEx.Adapter.Chat.format(signature, %{question: "Current?", context: "Now."},
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
    signature = DSEx.signature("question -> answer")

    messages =
      DSEx.Adapter.JSON.format(signature, %{question: "Current?"},
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
      module: DSEx.LM.Static,
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
      DSEx.predict("question -> answer: string, confidence: number",
        lm: lm,
        adapter: DSEx.Adapter.Chat,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert DSEx.Prediction.get(prediction, :confidence) == 0.99

    assert_received {:lm_call, [_system, _user], opts}
    refute Keyword.has_key?(opts, :response_format)
    refute Keyword.has_key?(opts, :json_fallback)
    refute Keyword.has_key?(opts, :json_retries)

    assert_received {:lm_call, retry_messages, retry_opts}
    assert Keyword.get(retry_opts, :response_format) == %{type: "json_object"}
    refute Keyword.has_key?(retry_opts, :json_fallback)
    refute Keyword.has_key?(retry_opts, :json_retries)
    assert Enum.any?(retry_messages, &(&1.content =~ "Return only a JSON object"))
    assert prediction.metadata.trace.raw == ~s({"answer":"Paris","confidence":0.99})
  end

  test "predict can disable chat JSON fallback for strict single-call behavior" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, opts ->
          send(parent, {:lm_call, messages, opts})
          "[[ ## answer ## ]]\nParis\n[[ ## completed ## ]]"
        end
      ]
    }

    program =
      DSEx.predict("question -> answer: string, confidence: number",
        lm: lm,
        adapter: DSEx.Adapter.Chat,
        config: [json_fallback: false]
      )

    assert {:error, %{reason: {:error, {:missing_output_fields, [:confidence]}}}} =
             DSEx.call(program, %{question: "Capital of France?"})

    assert_received {:lm_call, [_system, _user], opts}
    refute Keyword.has_key?(opts, :response_format)
    refute_received {:lm_call, _retry_messages, _retry_opts}
  end

  test "chat adapter strips adjacent completed markers from delimited output" do
    signature = DSEx.signature("question -> answer")

    assert {:ok, prediction} =
             DSEx.Adapter.Chat.parse(
               signature,
               "[[ ## answer ## ]]The Conversation[[ ## completed ## ]]",
               []
             )

    assert DSEx.Prediction.get(prediction, :answer) == "The Conversation"
  end

  test "chat adapter tolerates provider field markers with a missing closing hash pair" do
    signature = DSEx.signature("question -> reasoning, answer")

    assert {:ok, prediction} =
             DSEx.Adapter.Chat.parse(
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

    assert DSEx.Prediction.get(prediction, :answer) == "48"
  end

  test "JSON adapter supplies provider response format options and retry feedback" do
    signature = DSEx.signature("question -> answer: string")

    assert [response_format: %{type: "json_object"}] = DSEx.Adapter.JSON.lm_opts(signature, [])

    assert [response_format: %{type: "json_schema", json_schema: %{schema: schema}}] =
             DSEx.Adapter.JSON.lm_opts(signature, native_json_schema: true)

    assert schema["required"] == ["answer"]
  end

  test "save/load preserves adapter and ReqLLM provider configuration" do
    lm =
      DSEx.req_llm("openai:gpt-test",
        api_key: "not-persisted",
        temperature: 0,
        num_retries: 0
      )

    program = DSEx.predict("question -> score: int", lm: lm, adapter: DSEx.Adapter.JSON)

    path =
      Path.join(System.tmp_dir!(), "DSEx-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(program, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    assert loaded.adapter == DSEx.Adapter.JSON

    assert %DSEx.Clients.ReqLLM{
             model: "openai:gpt-test",
             opts: [temperature: 0, num_retries: 0]
           } = loaded.lm

    assert loaded.config == []
  end

  test "file persistence uses a checksummed transactional artifact envelope" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-transactional-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    original = DSEx.predict("question -> answer")
    assert :ok = DSEx.Saving.save!(original, path)

    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["artifact_type"] == "dsex_program_artifact"
    assert artifact["schema_version"] == 1
    assert artifact["payload_sha256"] =~ ~r/^sha256:[a-f0-9]{64}$/

    tampered = put_in(artifact, ["payload", "signature", "instructions"], "tampered")
    File.write!(path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/payload checksum mismatch/, fn ->
      DSEx.Saving.load!(path)
    end

    assert :ok = DSEx.Saving.save!(original, path)

    assert_raise ArgumentError, ~r/unsupported DSEx program for saving/, fn ->
      DSEx.Saving.save!(%DSEx.Predict.BestOfN{}, path)
    end

    assert %DSEx.Predict.Predict{} = DSEx.Saving.load!(path)
  end

  test "file load rejects an unwrapped program state" do
    path = Path.join(System.tmp_dir!(), "dsex-legacy-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Jason.encode!(DSEx.Saving.dump(DSEx.predict("question -> answer"))))

    assert_raise ArgumentError, ~r/not a checksummed program artifact envelope/, fn ->
      DSEx.Saving.load!(path)
    end
  end

  test "portable structural program types round-trip and remain executable" do
    comparison = DSEx.Predict.MultiChainComparison.new("question -> answer", m: 2)
    loaded_comparison = comparison |> DSEx.Saving.dump() |> DSEx.Saving.load()

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{rationale: "agreed", answer: "Paris"} end]
    }

    assert {:ok, prediction} =
             DSEx.context([lm: lm], fn ->
               DSEx.call(loaded_comparison, %{
                 question: "Capital?",
                 completions: [
                   %{reasoning: "one", answer: "Paris"},
                   %{reasoning: "two", answer: "Paris"}
                 ]
               })
             end)

    assert DSEx.get(prediction, :answer) == "Paris"

    examples = [
      DSEx.example(question: "capital france", answer: "Paris") |> DSEx.with_inputs(:question),
      DSEx.example(question: "capital italy", answer: "Rome") |> DSEx.with_inputs(:question)
    ]

    loaded_knn =
      DSEx.Predict.KNN.new(1, examples)
      |> DSEx.Saving.dump()
      |> DSEx.Saving.load()

    assert [%DSEx.Example{} = nearest] = DSEx.Predict.KNN.call(loaded_knn, %{question: "france"})
    assert DSEx.Example.get(nearest, :answer) == "Paris"
  end

  test "named callback registry round-trips callback-bearing program compositions" do
    metric = fn _example, prediction -> DSEx.get(prediction, :answer) == "Paris" end
    feedback = fn _predictions -> "selected" end
    predicate = fn prediction -> DSEx.get(prediction, :answer) == "Paris" end

    registry =
      DSEx.Saving.Registry.new(
        answer_metric: metric,
        selection_feedback: feedback,
        paris_assertion: predicate
      )

    base = DSEx.predict("question -> answer")

    programs = [
      DSEx.Predict.BestOfN.new(base, metric, n: 2, feedback_fn: feedback),
      DSEx.Predict.Refine.new(base, metric, max_attempts: 2),
      DSEx.Predict.Assertions.new(
        base,
        [DSEx.Assertion.new(:paris, predicate, message: "must be Paris")],
        strict: true
      )
    ]

    loaded =
      Enum.map(programs, fn program ->
        program
        |> DSEx.dump(registry: registry)
        |> DSEx.load(registry: registry)
      end)

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    Enum.each(loaded, fn program ->
      assert {:ok, prediction} =
               DSEx.context([lm: lm], fn -> DSEx.call(program, %{question: "Capital?"}) end)

      assert DSEx.get(prediction, :answer) == "Paris"
    end)

    state = DSEx.dump(hd(programs), registry: registry)

    assert_raise ArgumentError, ~r/unknown registry callback "answer_metric"/, fn ->
      DSEx.load(state)
    end
  end

  test "named registry round-trips ReAct CodeAct and RLM tool graphs" do
    lookup = fn %{query: query} -> "found #{query}" end
    policy = fn name, _args -> name in [:lookup, "lookup"] end
    registry = DSEx.Saving.Registry.new(lookup_runner: lookup, tool_policy: policy)
    tool = DSEx.tool(:lookup, "lookup facts", lookup, schema: %{query: :string})

    react = DSEx.react("question -> answer", [tool], max_iters: 0, tool_policy: policy)
    code_act = DSEx.code_act("question -> answer", [tool], max_iters: 0, tool_policy: policy)

    rlm =
      DSEx.Predict.RLM.new("question -> answer",
        lm: DSEx.req_llm("openai:gpt-test", api_key: "not-persisted"),
        sub_lm: DSEx.req_llm("openai:gpt-sub", api_key: "also-not-persisted"),
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
        state = DSEx.dump(program, registry: registry)
        refute inspect(state) =~ "not-persisted"
        refute inspect(state) =~ "also-not-persisted"
        DSEx.load(state, registry: registry)
      end)

    assert DSEx.Tool.call(loaded_react.tools[:lookup], %{query: "beam"}) == "found beam"
    assert DSEx.ToolPolicy.authorize(loaded_react.tool_policy, :lookup, %{}) == :ok
    assert {:error, {:react_max_iters, []}} = DSEx.call(loaded_react, %{question: "q"})

    assert DSEx.Tool.call(loaded_code_act.tools[:lookup], %{query: "otp"}) == "found otp"
    assert {:error, {:code_act_max_iters, 0, []}} = DSEx.call(loaded_code_act, %{question: "q"})

    assert %DSEx.Clients.ReqLLM{model: "openai:gpt-test", opts: []} = loaded_rlm.lm
    assert %DSEx.Clients.ReqLLM{model: "openai:gpt-sub", opts: []} = loaded_rlm.sub_lm
    assert loaded_rlm.max_recursion_depth == 3
    assert loaded_rlm.max_interpreter_steps == 2_500
    assert loaded_rlm.max_interpreter_value_bytes == 2_000_000
    assert loaded_rlm.max_interpreter_effects == 25
    assert DSEx.Tool.call(loaded_rlm.tools[:lookup], %{query: "rlm"}) == "found rlm"
    assert {:error, {:rlm_max_iterations, 0, []}} = DSEx.call(loaded_rlm, %{question: "q"})
  end

  test "compiled executable wrappers round-trip through portable persistence" do
    base = DSEx.predict("question -> answer")

    examples = [
      DSEx.example(question: "capital france", answer: "Paris") |> DSEx.with_inputs(:question)
    ]

    knn_program =
      DSEx.Optimizer.KNNFewShot.new(1, examples)
      |> DSEx.Optimizer.KNNFewShot.compile(base)

    reducer = fn predictions -> hd(predictions) end
    registry = DSEx.Saving.Registry.new(ensemble_reducer: reducer)

    ensemble =
      DSEx.Optimizer.Ensemble.new(reduce_fn: reducer, deterministic: true)
      |> DSEx.Optimizer.Ensemble.compile([base])

    semantic = DSEx.Evaluate.SemanticF1.new()
    grounded = DSEx.Evaluate.CompleteAndGrounded.new()

    [loaded_knn, loaded_ensemble, loaded_semantic, loaded_grounded] =
      Enum.map([knn_program, ensemble, semantic, grounded], fn program ->
        program |> DSEx.dump(registry: registry) |> DSEx.load(registry: registry)
      end)

    lm = %{
      module: DSEx.LM.Static,
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

    DSEx.context([lm: lm], fn ->
      assert {:ok, knn_prediction} = DSEx.call(loaded_knn, %{question: "france"})
      assert DSEx.get(knn_prediction, :answer) == "Paris"

      assert {:ok, ensemble_prediction} = DSEx.call(loaded_ensemble, %{question: "capital"})
      assert DSEx.get(ensemble_prediction, :answer) == "Paris"

      assert {:ok, semantic_prediction} =
               DSEx.call(loaded_semantic, %{
                 question: "q",
                 ground_truth: "a",
                 system_response: "a"
               })

      assert DSEx.get(semantic_prediction, :f1) == 1

      assert {:ok, grounded_prediction} =
               DSEx.call(loaded_grounded, %{question: "q", context: "a", answer: "a"})

      assert DSEx.get(grounded_prediction, :groundedness) == 1
    end)
  end

  test "recursive agent graphs round-trip through the named registry" do
    parent_handler = fn _agent, inputs, runtime -> {:ok, %{answer: inputs.question}, runtime} end
    child_handler = fn inputs, runtime -> {:ok, %{child: inputs.value}, runtime} end
    lookup = fn %{query: query} -> String.upcase(query) end

    registry =
      DSEx.Saving.Registry.new(
        parent_handler: parent_handler,
        child_handler: child_handler,
        lookup_runner: lookup
      )

    child = DSEx.Agent.new(:child, child_handler)
    tool = DSEx.tool(:lookup, "uppercase", lookup)

    parent =
      DSEx.Agent.new(:parent, parent_handler,
        children: [child],
        tools: [tool],
        input_schema: %{required: [:question]},
        output_schema: %{required: [:answer]},
        tool_policy: [:lookup]
      )

    loaded = parent |> DSEx.dump(registry: registry) |> DSEx.load(registry: registry)

    assert %DSEx.Agent{children: %{child: %DSEx.Agent{}}, tools: %{lookup: %DSEx.Tool{}}} = loaded
    assert {:ok, %{answer: "hello"}, _runtime} = DSEx.Agent.run(loaded, %{question: "hello"})
    assert DSEx.Tool.call(loaded.tools.lookup, %{query: "beam"}) == "BEAM"
  end

  test "loaded pinned provider programs can be rebound through the public facade" do
    original =
      DSEx.predict("question -> answer",
        lm: DSEx.req_llm("openai:gpt-test", api_key: "must-not-survive")
      )

    state = DSEx.dump(original)
    refute inspect(state) =~ "must-not-survive"

    loaded = DSEx.load(state)

    replacement = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "rebound"} end]
    }

    rebound = DSEx.with_lm(loaded, replacement)

    assert {:ok, prediction} = DSEx.call(rebound, %{question: "works?"})
    assert DSEx.get(prediction, :answer) == "rebound"
  end

  test "save/load preserves dynamic LM rebinding for settings-based programs" do
    program = DSEx.predict("question -> answer")

    path =
      Path.join(System.tmp_dir!(), "DSEx-dynamic-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(program, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "settings-ok"} end]
    }

    assert {:ok, prediction} =
             DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
               DSEx.call(loaded, %{question: "works?"})
             end)

    assert DSEx.Prediction.get(prediction, :answer) == "settings-ok"
  end

  test "save/load preserves optimizer reports on compiled programs" do
    trainset = [
      DSEx.example(question: "Capital?", answer: "Paris")
      |> DSEx.with_inputs(:question)
    ]

    compiled =
      "question -> answer"
      |> DSEx.predict()
      |> then(fn program ->
        DSEx.Optimizer.LabeledFewShot.new(k: 1)
        |> DSEx.Optimizer.LabeledFewShot.compile(program, trainset)
      end)

    path =
      Path.join(
        System.tmp_dir!(),
        "DSEx-compiled-save-#{System.unique_integer([:positive])}.json"
      )

    assert :ok = DSEx.Saving.save!(compiled, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    assert %DSEx.Optimizer.Report{optimizer: :labeled_few_shot} =
             report = DSEx.Optimizer.Report.fetch(loaded)

    assert report.metadata.selected_count == 1
    assert [%{example: %DSEx.Example{} = example, selected?: true}] = report.candidates
    assert DSEx.Example.get(example, :answer) == "Paris"
    assert length(loaded.demos) == 1
  end

  test "save/load preserves demo input boundaries on programs" do
    demo =
      DSEx.example(question: "Capital?", answer: "Paris", note: "kept")
      |> DSEx.with_inputs(:question)

    loaded =
      "question -> answer"
      |> DSEx.predict(demos: [demo])
      |> DSEx.Saving.dump()
      |> DSEx.Saving.load()

    assert [%DSEx.Example{} = loaded_demo] = loaded.demos
    assert DSEx.Example.to_map(loaded_demo) == DSEx.Example.to_map(demo)
    assert loaded_demo.input_keys == [:question]
    assert DSEx.Example.to_map(DSEx.Example.inputs(loaded_demo)) == %{question: "Capital?"}

    assert DSEx.Example.to_map(DSEx.Example.labels(loaded_demo)) == %{
             answer: "Paris",
             note: "kept"
           }
  end

  test "save/load preserves local memory RAG programs" do
    lm = %{
      module: DSEx.LM.Static,
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
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: 1
      )

    path =
      Path.join(System.tmp_dir!(), "DSEx-rag-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(rag, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    assert %DSEx.Predict.RAG{retriever: %DSEx.Retrieve.Memory{}, program: program} = loaded
    assert program.dynamic_lm?

    assert {:ok, prediction} =
             DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
               DSEx.call(loaded, %{question: "capital France"})
             end)

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1
  end

  test "save/load preserves explicit zero RAG retrieval limits" do
    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: 0
      )

    assert rag.k == 0
    state = DSEx.Saving.dump(rag)
    assert state["k"] == 0
    assert %DSEx.Predict.RAG{k: 0} = DSEx.Saving.load(state)
  end

  test "save/load preserves multi-hop RAG settings and rejects missing current fields" do
    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: 1,
        hops: 2
      )

    state = DSEx.Saving.dump(rag)
    assert state["hops"] == 2
    assert %DSEx.Predict.RAG{hops: 2} = DSEx.Saving.load(state)

    stale_state = Map.delete(state, "hops")

    assert_raise ArgumentError, ~r/missing required keys: \["hops"\]/, fn ->
      DSEx.Saving.load(stale_state)
    end
  end

  test "save/load preserves ProgramOfThought programs" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2"} end]
    }

    program =
      DSEx.Predict.ProgramOfThought.new("x -> doubled",
        output_field: :doubled,
        metadata: %{purpose: :portable_pot}
      )

    path =
      Path.join(System.tmp_dir!(), "DSEx-pot-save-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(program, path)
    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    assert %DSEx.Predict.ProgramOfThought{
             signature: %DSEx.Signature{},
             predict: %DSEx.Predict.Predict{},
             output_field: :doubled
           } = loaded

    assert DSEx.Signature.input_names(loaded.signature) == [:x]
    assert DSEx.Signature.output_names(loaded.signature) == [:doubled]
    assert loaded.predict.metadata.purpose == :portable_pot

    assert {:ok, prediction} =
             DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
               DSEx.Predict.ProgramOfThought.call(loaded, %{x: 21})
             end)

    assert DSEx.Prediction.get(prediction, :doubled) == 42
  end

  test "save/load preserves optimized ProgramOfThought task and planner instructions" do
    program =
      "x -> doubled"
      |> DSEx.program_of_thought(output_field: :doubled)
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Double exactly.")
      |> DSEx.Saving.dump()
      |> DSEx.Saving.load()

    assert program.signature.instructions == "Double exactly."
    assert program.predict.signature.instructions == "Double exactly."

    assert program
           |> DSEx.ProgramAccess.task_signature()
           |> DSEx.Signature.to_spec() == "x -> doubled"

    assert program
           |> DSEx.ProgramAccess.lm_signature()
           |> DSEx.Signature.to_spec() == "x -> program, tool, arguments"
  end

  test "save rejects non-portable RAG retrievers explicitly" do
    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(fn _query, _opts -> {:ok, []} end)

    assert_raise ArgumentError, ~r/only DSEx.Retrieve.Memory is portable/, fn ->
      DSEx.Saving.dump(rag)
    end
  end
end
