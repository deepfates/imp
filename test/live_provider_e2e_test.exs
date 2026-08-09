defmodule LiveProviderE2ETest do
  use ExUnit.Case

  @moduletag :live

  defp live_lm(opts \\ []) do
    Imp.Test.LiveProvider.lm(Keyword.merge([max_completion_tokens: 120], opts))
  end

  test "live provider completes chain-of-thought with required reasoning field" do
    program =
      Imp.chain_of_thought("question -> answer",
        lm: live_lm(),
        adapter: Imp.Adapter.JSON,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} =
             Imp.call(program, %{
               question:
                 "Return JSON with reasoning and answer. Reason briefly, then set answer to exactly pong."
             })

    assert prediction |> Imp.Prediction.get(:reasoning, "") |> to_string() |> byte_size() > 0

    answer =
      prediction
      |> Imp.Prediction.get(:answer, "")
      |> to_string()
      |> String.downcase()

    assert String.contains?(answer, "pong")
  end

  test "live provider extracts structured event details through the front-door API" do
    program =
      Imp.predict(
        Imp.signature(
          "email -> event_name: string, date: string",
          "Extract the event name and date from the email. Return JSON only."
        ),
        lm: live_lm(max_completion_tokens: 120),
        adapter: Imp.Adapter.JSON,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} =
             Imp.call(program, %{
               email: "Team Offsite moved to Thursday, June 5. Bring questions for planning."
             })

    event_name = prediction |> Imp.get(:event_name, "") |> to_string() |> String.downcase()
    date = prediction |> Imp.get(:date, "") |> to_string() |> String.downcase()

    assert event_name =~ "offsite"
    assert date =~ "june" or date =~ "thursday" or date =~ "6/5" or date =~ "06-05"
  end

  test "live provider streams OpenAI-compatible chunks through Imp.Streaming" do
    program = Imp.predict("question -> answer", lm: live_lm(max_completion_tokens: 40))

    chunks =
      program
      |> Imp.Streaming.stream(
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
      Imp.Signature.new(
        "question -> answer",
        """
        Use the lookup tool first with query "capital-france".
        If the history already contains a lookup result of Paris, stop calling lookup and call submit with answer "Paris".
        Do not answer directly without using lookup.
        """
      )

    lookup =
      Imp.Tool.new(
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
      Imp.react(signature, [lookup],
        lm: live_lm(max_completion_tokens: 1024),
        tool_policy: [:lookup, :submit],
        max_iters: 4
      )

    assert {:ok, prediction} =
             Imp.call(agent, %{
               question: "What is the capital of France?"
             })

    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    history = Imp.Prediction.get(prediction, :history)
    assert Enum.any?(history, &(&1.tool == :lookup and &1.result == "Paris"))
    assert Enum.any?(history, &(&1.tool == :submit))
  end

  test "live provider drives an imported HTTP MCP tool through ReAct" do
    test_pid = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        decoded = Jason.decode!(request.body)
        send(test_pid, {:mcp_json_rpc, decoded, request.headers})

        case decoded["method"] do
          "initialize" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 protocolVersion: "2025-03-26",
                 capabilities: %{},
                 serverInfo: %{name: "imp-live-e2e", version: "1"}
               }
             }}

          "notifications/initialized" ->
            {200, %{jsonrpc: "2.0", result: %{}}}

          "tools/list" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 tools: [
                   %{
                     name: "lookup_capital",
                     description: "Look up the capital for one supported country key.",
                     # MCP spec, Tool definition: camelCase "inputSchema".
                     inputSchema: %{
                       type: "object",
                       properties: %{
                         country: %{type: "string", enum: ["france"]}
                       },
                       required: ["country"]
                     }
                   }
                 ]
               }
             }}

          "tools/call" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: "Paris"
             }}
        end
      end)

    [lookup] = base_url |> Imp.MCP.HTTPClient.new() |> Imp.MCP.import_tools()

    signature =
      Imp.Signature.new(
        "question -> answer",
        """
        First call lookup_capital with country "france". After its result is in
        history, call submit with answer exactly equal to that result. Never
        answer from memory and never call lookup_capital more than once.
        """
      )

    agent =
      Imp.react(signature, [lookup],
        lm: live_lm(max_completion_tokens: 1024),
        tool_policy: [:lookup_capital, :submit],
        max_iters: 4
      )

    assert {:ok, prediction} = Imp.call(agent, %{question: "What is France's capital?"})
    assert Imp.get(prediction, :answer) == "Paris"

    history = Imp.get(prediction, :history)
    assert Enum.any?(history, &(&1.tool == :lookup_capital and &1.result == "Paris"))
    assert Enum.any?(history, &(&1.tool == :submit))

    assert_received {:mcp_json_rpc, %{"method" => "initialize"}, headers}
    assert headers["mcp-protocol-version"] == "2025-03-26"
    assert_received {:mcp_json_rpc, %{"method" => "notifications/initialized"}, _headers}
    assert_received {:mcp_json_rpc, %{"method" => "tools/list"}, _headers}

    assert_received {:mcp_json_rpc,
                     %{
                       "method" => "tools/call",
                       "params" => %{
                         "name" => "lookup_capital",
                         "arguments" => %{"country" => "france"}
                       }
                     }, _headers}
  end

  test "live provider supports orchestration modules over real calls" do
    base =
      Imp.predict("question -> answer",
        lm: live_lm(max_completion_tokens: 50),
        adapter: Imp.Adapter.JSON,
        config: [json_retries: 1]
      )

    parallel_results =
      Imp.parallel(
        base,
        [
          %{question: "Return JSON with answer exactly alpha."},
          %{question: "Return JSON with answer exactly beta."}
        ],
        max_concurrency: 2
      )

    assert [{:ok, alpha}, {:ok, beta}] = parallel_results

    assert alpha |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "alpha"

    assert beta |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~ "beta"

    best =
      Imp.best_of_n(base, fn _example, prediction ->
        prediction |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
          "pong"
      end)

    assert {:ok, best_prediction} =
             Imp.call(best, %{
               question: "Return JSON with answer exactly pong."
             })

    assert best_prediction |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "pong"

    refine =
      Imp.refine(base, fn _example, prediction ->
        prediction |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
          "pong"
      end)

    assert {:ok, refined} =
             Imp.call(refine, %{
               question: "Return JSON with answer exactly pong."
             })

    assert refined |> Imp.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "pong"
  end

  test "live provider drives program-of-thought through the sandbox" do
    program =
      Imp.program_of_thought("question -> answer",
        lm: live_lm(max_completion_tokens: 80),
        adapter: Imp.Adapter.JSON,
        config: [json_retries: 1]
      )

    assert {:ok, prediction} =
             Imp.call(program, %{
               question: "Return JSON with program exactly \"1 + 2\"."
             })

    assert Imp.Prediction.get(prediction, :answer) == 3
  end

  test "live provider drives CodeAct through the BEAM-safe sandbox" do
    program =
      Imp.code_act("question -> answer: int", [],
        lm: live_lm(max_completion_tokens: 1024),
        adapter: Imp.Adapter.JSON,
        config: [json_retries: 1],
        max_iters: 2
      )

    assert {:ok, prediction} =
             Imp.call(program, %{
               question:
                 "Return JSON whose program field contains the Elixir source 20 + 22. The decoded program must not itself be a quoted string literal. Do not use a tool."
             })

    assert Imp.get(prediction, :answer) == 42
    assert [%{action: :program, output: {:ok, 42}}] = prediction.metadata.code_act_trace
  end

  test "live provider drives ReActV2 native submit" do
    program =
      Imp.react_v2(
        Imp.signature(
          "question -> answer",
          "Call submit with answer exactly Paris. Do not call any other tool."
        ),
        [],
        lm: live_lm(max_completion_tokens: 100),
        max_iters: 1
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris", inspect(prediction, pretty: true)
    assert Imp.get(prediction, :termination_reason) in [:submit, :forced_submit]
  end

  test "live provider drives symbolic RLM code with observable budget" do
    program =
      Imp.rlm(
        Imp.signature(
          "question -> answer",
          "Use the persistent Elixir environment. Return reasoning and code that assigns the answer to a variable, then calls submit with answer exactly Paris."
        ),
        lm: live_lm(max_completion_tokens: 100),
        adapter: Imp.Adapter.JSON,
        max_iterations: 2,
        max_llm_calls: 2
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris", inspect(prediction, pretty: true)
    assert prediction.metadata.rlm.sub_lm_calls <= 2
    assert prediction.metadata.rlm.iterations <= 2
    assert is_list(prediction.metadata.rlm_trace)
    assert Enum.any?(prediction.metadata.rlm_trace, &(&1.action == :submit))
  end

  test "live provider RLM code invokes a real sub-LM from the environment" do
    program =
      Imp.rlm(
        Imp.signature(
          "question -> answer",
          "Return reasoning and Elixir code. The code must call llm_query with a prompt asking for the one-word capital of France, assign its result, and submit that exact result as answer."
        ),
        lm: live_lm(max_completion_tokens: 160),
        sub_lm: live_lm(max_completion_tokens: 40),
        adapter: Imp.Adapter.JSON,
        max_iterations: 2,
        max_llm_calls: 1
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert prediction.metadata.rlm.sub_lm_calls == 1, inspect(prediction, pretty: true)
    assert String.contains?(to_string(Imp.get(prediction, :answer)), "Paris")
    assert Enum.any?(prediction.metadata.rlm_trace, &(&1.action == :submit))
  end
end
