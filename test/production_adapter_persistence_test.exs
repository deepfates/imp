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

    assert_raise ArgumentError, ~r/DSEx.Adapter.Chat.format\/3.*:demos.*expected.*list/s, fn ->
      DSEx.Adapter.Chat.format(signature, %{question: "q"}, demos: :not_demos)
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

    assert [response_format: %{type: "json_object"}] =
             DSEx.Adapter.JSON.lm_opts(signature, temperature: 0)
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

    complete_demo =
      DSEx.example(%{
        question: "Capital?",
        context: "France: Paris.",
        answer: "Paris",
        confidence: 1.0
      })

    incomplete_demo =
      DSEx.example(%{
        question: "Largest city?",
        answer: "Tokyo"
      })

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

  test "save/load preserves normalized RAG retrieval limits" do
    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1),
        k: -4
      )

    assert rag.k == 0
    state = DSEx.Saving.dump(rag)
    assert state["k"] == 0
    assert %DSEx.Predict.RAG{k: 0} = DSEx.Saving.load(state)
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
