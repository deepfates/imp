defmodule LiveProviderE2ETest do
  use ExUnit.Case

  @moduletag :live

  defp live_lm(opts \\ []) do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL") || "gpt-4o-mini"

    assert is_binary(api_key) and byte_size(api_key) > 0

    DSEx.Clients.OpenAI.new(model,
      opts: Keyword.merge([temperature: 0, max_completion_tokens: 120], opts)
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
             DSEx.Predict.ChainOfThought.call(program, %{
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

  test "live provider uses ReActV2 function tools and reserved submit" do
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
      DSEx.react_v2(signature, [lookup],
        lm: live_lm(max_completion_tokens: 160),
        tool_policy: [:lookup, :submit],
        max_iters: 4
      )

    assert {:ok, prediction} =
             DSEx.Predict.ReActV2.call(agent, %{
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
      DSEx.Predict.Parallel.map(
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
      DSEx.Predict.BestOfN.new(base, fn _example, prediction ->
        prediction |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
          "pong"
      end)

    assert {:ok, best_prediction} =
             DSEx.Predict.BestOfN.call(best, %{
               question: "Return JSON with answer exactly pong."
             })

    assert best_prediction |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
             "pong"

    refine =
      DSEx.Predict.Refine.new(base, fn _example, prediction ->
        prediction |> DSEx.Prediction.get(:answer, "") |> to_string() |> String.downcase() =~
          "pong"
      end)

    assert {:ok, refined} =
             DSEx.Predict.Refine.call(refine, %{
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
             DSEx.Predict.ProgramOfThought.call(program, %{
               question: "Return JSON with program exactly \"1 + 2\"."
             })

    assert DSEx.Prediction.get(prediction, :answer) == 3
  end
end
