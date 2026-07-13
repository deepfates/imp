defmodule LiveProviderE2ETest do
  use ExUnit.Case

  @moduletag :live

  defp live_lm(opts \\ []) do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL")

    assert is_binary(api_key) and byte_size(api_key) > 0
    assert is_binary(model) and byte_size(model) > 0

    DSEx.req_llm(
      "openai:#{model}",
      Keyword.merge([api_key: api_key, temperature: 0, max_completion_tokens: 120], opts)
    )
  end

  test "live provider completes chain-of-thought with required reasoning field" do
    program =
      DSEx.chain_of_thought("question -> answer",
        lm: live_lm(),
        adapter: DSEx.Adapter.JSON,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} =
             DSEx.call(program, %{
               question:
                 "Return JSON with reasoning and answer. Reason briefly, then set answer to exactly pong."
             })

    assert prediction |> DSEx.Prediction.get(:reasoning, "") |> to_string() |> byte_size() > 0

    answer =
      prediction
      |> DSEx.Prediction.get(:answer, "")
      |> to_string()
      |> String.downcase()

    assert String.contains?(answer, "pong")
  end

  test "live provider extracts structured event details through the front-door API" do
    program =
      DSEx.predict(
        DSEx.signature(
          "email -> event_name: string, date: string",
          "Extract the event name and date from the email. Return JSON only."
        ),
        lm: live_lm(max_completion_tokens: 120),
        adapter: DSEx.Adapter.JSON,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} =
             DSEx.call(program, %{
               email: "Team Offsite moved to Thursday, June 5. Bring questions for planning."
             })

    event_name = prediction |> DSEx.get(:event_name, "") |> to_string() |> String.downcase()
    date = prediction |> DSEx.get(:date, "") |> to_string() |> String.downcase()

    assert event_name =~ "offsite"
    assert date =~ "june" or date =~ "thursday" or date =~ "6/5" or date =~ "06-05"
  end

  test "live provider streams OpenAI-compatible chunks through DSEx.Streaming" do
    program = DSEx.predict("question -> answer", lm: live_lm(max_completion_tokens: 40))

    chunks =
      program
      |> DSEx.Streaming.stream(
        %{question: "Stream exactly the word pong, with no punctuation."},
        provider_stream: true
      )
      |> Enum.map(& &1.chunk)
      |> Enum.reject(&is_nil/1)

    text = chunks |> Enum.join() |> String.downcase()

    assert chunks != []
    assert String.contains?(text, "pong")
  end

  test "live provider uses ReAct function tools and reserved submit" do
    signature =
      DSEx.Signature.new(
        "question -> answer",
        """
        Use the lookup tool first with query "capital-france".
        If the history already contains a lookup result of Paris, stop calling lookup and call submit with answer "Paris".
        Do not answer directly without using lookup.
        """
      )

    lookup =
      DSEx.Tool.new(
        :lookup,
        "Lookup a fact by query.",
        fn
          %{query: "capital-france"} -> "Paris"
          %{"query" => "capital-france"} -> "Paris"
          other -> {:error, {:unexpected_query, other}}
        end,
        schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "enum" => ["capital-france"]
            }
          },
          "required" => ["query"]
        }
      )

    agent =
      DSEx.react(signature, [lookup],
        lm: live_lm(max_completion_tokens: 160),
        tool_policy: [:lookup, :submit],
        max_iters: 4
      )

    assert {:ok, prediction} =
             DSEx.call(agent, %{
               question: "What is the capital of France?"
             })

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    history = DSEx.Prediction.get(prediction, :history)
    assert Enum.any?(history, &(&1.tool == :lookup and &1.result == "Paris"))
    assert Enum.any?(history, &(&1.tool == :submit))
  end

  test "live provider supports orchestration modules over real calls" do
    base =
      DSEx.predict("question -> answer",
        lm: live_lm(max_completion_tokens: 50),
        adapter: DSEx.Adapter.JSON,
        config: [json_retries: 1]
      )

    parallel_results =
      DSEx.parallel(
        base,
        [
          %{question: "Return JSON with answer exactly alpha."},
          %{question: "Return JSON with answer exactly beta."}
        ],
        max_concurrency: 2
      )

    assert [{:ok, alpha}, {:ok, beta}] = parallel_results

    assert alpha |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "alpha"

    assert beta |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~ "beta"

    best =
      DSEx.best_of_n(base, fn _example, prediction ->
        prediction |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
          "pong"
      end)

    assert {:ok, best_prediction} =
             DSEx.call(best, %{
               question: "Return JSON with answer exactly pong."
             })

    assert best_prediction |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "pong"

    refine =
      DSEx.refine(base, fn _example, prediction ->
        prediction |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
          "pong"
      end)

    assert {:ok, refined} =
             DSEx.call(refine, %{
               question: "Return JSON with answer exactly pong."
             })

    assert refined |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "pong"
  end

  test "live provider drives program-of-thought through the sandbox" do
    program =
      DSEx.program_of_thought("question -> answer",
        lm: live_lm(max_completion_tokens: 80),
        adapter: DSEx.Adapter.JSON,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} =
             DSEx.call(program, %{
               question: "Return JSON with program exactly \"1 + 2\"."
             })

    assert DSEx.Prediction.get(prediction, :answer) == 3
  end

  test "live provider drives CodeAct through the BEAM-safe sandbox" do
    program =
      DSEx.code_act("question -> answer", [],
        lm: live_lm(max_completion_tokens: 100),
        adapter: DSEx.Adapter.JSON,
        config: [json_retries: 1],
        max_iters: 2
      )

    assert {:ok, prediction} =
             DSEx.call(program, %{
               question: "Return JSON with program exactly \"20 + 22\" and no tool."
             })

    assert DSEx.get(prediction, :answer) == 42
  end

  test "live provider drives ReActV2 native submit" do
    program =
      DSEx.react_v2(
        DSEx.signature(
          "question -> answer",
          "Call submit with answer exactly Paris. Do not call any other tool."
        ),
        [],
        lm: live_lm(max_completion_tokens: 100),
        max_iters: 1
      )

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris", inspect(prediction, pretty: true)
    assert DSEx.get(prediction, :termination_reason) in [:submit, :forced_submit]
  end

  test "live provider drives symbolic RLM code with observable budget" do
    program =
      DSEx.rlm(
        DSEx.signature(
          "question -> answer",
          "Use the persistent Elixir environment. Return reasoning and code that assigns the answer to a variable, then calls submit with answer exactly Paris."
        ),
        lm: live_lm(max_completion_tokens: 100),
        adapter: DSEx.Adapter.JSON,
        max_iterations: 2,
        max_llm_calls: 2
      )

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris", inspect(prediction, pretty: true)
    assert prediction.metadata.rlm.sub_lm_calls <= 2
    assert prediction.metadata.rlm.iterations <= 2
    assert is_list(prediction.metadata.rlm_trace)
    assert Enum.any?(prediction.metadata.rlm_trace, &(&1.action == :submit))
  end

  test "live provider RLM code invokes a real sub-LM from the environment" do
    program =
      DSEx.rlm(
        DSEx.signature(
          "question -> answer",
          "Return reasoning and Elixir code. The code must call llm_query with a prompt asking for the one-word capital of France, assign its result, and submit that exact result as answer."
        ),
        lm: live_lm(max_completion_tokens: 160),
        sub_lm: live_lm(max_completion_tokens: 40),
        adapter: DSEx.Adapter.JSON,
        max_iterations: 2,
        max_llm_calls: 1
      )

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert prediction.metadata.rlm.sub_lm_calls == 1, inspect(prediction, pretty: true)
    assert String.contains?(to_string(DSEx.get(prediction, :answer)), "Paris")
    assert Enum.any?(prediction.metadata.rlm_trace, &(&1.action == :submit))
  end
end
