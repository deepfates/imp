defmodule ReActV2FinishSubmitTest do
  use ExUnit.Case, async: true

  # `finish: :submit` ends a one-text-output turn through `submit`, as DSPy's
  # ReActV2 ends every turn: text without a tool call is a thought, not the
  # answer (`react_v2_thought_continues_test.exs` covers what follows it). The
  # forced `submit` request, for every signature with
  # `submit`, must not end on the model's own message, which Mistral and
  # Gemini refuse.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "seen" end)

  @thought %{next_thought: "Now let me look at the box.", tool_calls: []}
  @look %{next_thought: "Looking.", tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}

  # Replies in order; each request is sent to the test with its options.
  defp scripted(owner, replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        send(owner, {:request, messages, opts})

        Agent.get_and_update(agent, fn
          [reply | rest] -> {reply.(opts), rest}
          [] -> {%{tool_calls: []}, []}
        end)
      end
    )
  end

  defp requests(acc \\ []) do
    receive do
      {:request, messages, opts} -> requests([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reply(value), do: fn _opts -> value end

  defp submit(arguments),
    do: reply(%{tool_calls: [%{id: "s", name: "submit", arguments: arguments}]})

  test "with finish: :submit, text without a tool call is a thought, and the next step submits" do
    program =
      Imp.react("intent -> answer", [look()],
        lm: scripted(self(), [reply(@thought), submit(%{answer: "A cat."})]),
        finish: :submit
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "What is in the box?"})
    assert Imp.get(prediction, :answer) == "A cat."
    assert prediction.metadata.termination_reason == :submit
    refute Map.has_key?(prediction.metadata, :termination_cause)

    [{_step, step_opts}, {continued, continued_opts}] = requests()
    assert Enum.map(step_opts[:tools], & &1.function.name) == ["look", "submit"]

    # The next request is an ordinary step: every tool, nothing forced, and
    # the thought as its last message.
    assert Enum.map(continued_opts[:tools], & &1.function.name) == ["look", "submit"]
    assert continued_opts[:tool_choice] == "auto"

    assert List.last(continued) == %{
             role: :user,
             content: "[[ ## next_thought ## ]]\nNow let me look at the box."
           }

    # The thought stays in the history as the model's step.
    [thought_step, _submit_step] = prediction.metadata.history.messages
    assert thought_step.next_thought == "Now let me look at the box."

    runner = fn _arguments -> "seen" end
    registry = Imp.Saving.Registry.new(look_runner: runner)

    dumped =
      Imp.react("intent -> answer", [Imp.tool(:look, "Look at a thing", runner)], finish: :submit)
      |> Imp.dump(registry: registry)

    assert dumped["finish"] == "submit"
    loaded = Imp.load!(dumped, registry: registry)
    assert loaded.finish == :submit
    assert Map.has_key?(loaded.tools, :submit)
    assert Imp.load!(Map.delete(dumped, "finish"), registry: registry).finish == :auto

    assert_raise ArgumentError, ~r/last_request_tools with finish: :submit/, fn ->
      dumped |> Map.put("last_request_tools", ["look"]) |> Imp.load!(registry: registry)
    end
  end

  # The bodies OpenRouter returns when the provider will not take the named
  # (or any forced) `tool_choice`: Meta's words are under `metadata.raw`, and
  # the top-level message, which ReqLLM keeps as the error's text, says only
  # "Provider returned error".
  @meta_refusal ~S|{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"{\"error\":{\"code\":null,\"message\":\"only `\\\"auto\\\"` is supported for `tool_choice`. `\\\"none\\\"`, `\\\"required\\\"`, and named function choices are not currently supported\",\"param\":\"tool_choice\"}}","provider_name":"Meta"}}}|
  @no_endpoints ~S|{"error":{"message":"No endpoints found that support the provided 'tool_choice' value. To learn more about provider routing, visit: https://openrouter.ai/docs/guides/routing/provider-selection","code":404}}|
  @thinking_refusal ~S|{"error":{"message":"Thinking may not be enabled when tool_choice forces tool use.","code":400}}|

  defp openrouter(base_url),
    do:
      Imp.req_llm(%{provider: :openrouter, id: "fixture/model", base_url: base_url},
        api_key: "fixture",
        max_retries: 0,
        cache: false
      )

  # The error the ReqLLM client returns for that body, as it returns it for a
  # streamed request or not.
  defp refusal(status, body, :generate) do
    lm = openrouter(Imp.Test.LocalHTTP.start(fn _request -> {status, body} end))
    {:error, error} = Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "hi"}], [])
    error
  end

  defp refusal(status, body, :stream) do
    lm = openrouter(Imp.Test.LocalHTTP.start(fn _request -> {status, body} end))

    [%{chunk: {:error, error}}] =
      lm |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "hi"}]) |> Enum.to_list()

    error
  end

  @extracted "[[ ## reasoning ## ]]\nSeen.\n\n[[ ## answer ## ]]\nA cat.\n\n" <>
               "[[ ## confidence ## ]]\n1.0\n\n[[ ## completed ## ]]"

  # A step that wrote a thought and called nothing, then the forced requests:
  # what the provider at `base_url` says to each, by its `tool_choice`.
  defp openrouter_turn(forced_status, forced_body) do
    owner = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        tools = for tool <- body["tools"] || [], do: tool["function"]["name"]
        send(owner, {:wire, tools, body["tool_choice"], List.last(body["messages"])["role"]})

        cond do
          tools == [] -> {200, completion(@extracted)}
          body["tool_choice"] in [nil, "auto"] -> {200, completion("Now let me look at the box.")}
          true -> {forced_status, forced_body}
        end
      end)

    Imp.react("intent -> answer, confidence: float", [look()], lm: openrouter(base_url))
    |> Imp.call(%{intent: "What is in the box?"})
  end

  defp completion(content),
    do: %{
      "id" => "r",
      "model" => "fixture/model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ]
    }

  defp wire(acc \\ []) do
    receive do
      {:wire, tools, tool_choice, last_role} -> wire([{tools, tool_choice, last_role} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  for {name, status, body} <-
        [
          meta_via_openrouter: [400, @meta_refusal],
          no_openrouter_endpoint: [404, @no_endpoints]
        ]
        |> Enum.map(fn {name, [status, body]} -> {name, status, body} end) do
    @status status
    @body body

    test "#{name}: a refused tool_choice gets the required retry, then the extractor" do
      assert {:ok, prediction} = openrouter_turn(@status, @body)
      assert prediction.metadata.termination_reason == :extracted
      assert Imp.get(prediction, :answer) == "A cat."

      # The extractor's request has no tools; none of them ends on the
      # model's turn.
      assert [
               {["look", "submit"], _step_choice, "user"},
               {["look", "submit"], %{"function" => %{"name" => "submit"}}, "user"},
               {["submit"], "required", "user"},
               {[], nil, "user"}
             ] = wire()
    end
  end

  test "an error that names tool_choice for another reason is not a refusal of it" do
    assert {:error, %Imp.Predict.ReActV2.StepError{}} = openrouter_turn(400, @thinking_refusal)
    assert [{_, _, _}, {_, %{"function" => %{"name" => "submit"}}, _}] = wire()
  end

  # Every way a forced request is sent after a thought-only step: the named
  # `tool_choice`, the "required" retry when the provider refuses the name,
  # and the extractor when it refuses both; with and without a note; with
  # the thought as the first step and after a tool step. The refusal is the
  # one the ReqLLM client returns for Meta through OpenRouter, streamed or not.
  defp forced_reply(:submit, _refusal), do: submit(%{answer: "A cat.", confidence: 1.0})

  defp forced_reply(:extract, _refusal),
    do: reply(%{reasoning: "Seen.", answer: "A cat.", confidence: 1.0})

  defp forced_reply(:refused, refusal), do: reply({:error, refusal})

  for {provider, forced_replies, transport} <- [
        {:honours_named, [:submit], :generate},
        {:honours_required, [:refused, :submit], :generate},
        {:auto_only, [:refused, :refused, :extract], :generate},
        {:auto_only_streamed, [:refused, :refused, :extract], :stream}
      ],
      {start, steps} <- [first_step: 0, after_a_tool: 1],
      note <- [nil, "Answer now."] do
    @forced_replies forced_replies
    @transport transport
    @steps steps
    @note note

    test "#{provider}, #{start}, note #{inspect(note)}: no forced request ends on the model's turn" do
      refusal = refusal(400, @meta_refusal, @transport)

      replies =
        List.duplicate(reply(@look), @steps) ++
          [reply(@thought)] ++ Enum.map(@forced_replies, &forced_reply(&1, refusal))

      program =
        Imp.react("intent -> answer, confidence: float", [look()],
          lm: scripted(self(), replies),
          last_request_note: @note
        )

      assert {:ok, prediction} = Imp.call(program, %{intent: "What is in the box?"})
      assert Imp.get(prediction, :answer) == "A cat."
      assert prediction.metadata.termination_reason in [:forced_submit, :extracted]

      forced = Enum.drop(requests(), @steps + 1)
      assert length(forced) == length(@forced_replies)

      for {messages, _opts} <- forced do
        assert List.last(messages).role != :assistant
        # The model still reads the thought it wrote.
        assert Enum.any?(messages, &(to_string(&1.content) =~ "Now let me look at the box."))
      end
    end
  end
end
