defmodule ReActV2ResumeExtractTest do
  use ExUnit.Case, async: true

  # A host resumes a held history with no new inputs, `max_iters: 0` and a
  # note: one request, the last one, asking for a recap. With `finish: :submit`
  # that request forces `submit`. When the model writes the recap as text
  # instead, or the provider cannot be forced, the typed extractor answers,
  # and it has no inputs but those in the history.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "seen" end)

  @recap "We looked in the box and found a cat."
  @note "Write a recap of this conversation."
  @extracted "[[ ## reasoning ## ]]\nFrom the turn.\n\n[[ ## reply ## ]]\n#{@recap}\n\n[[ ## completed ## ]]"

  # The conversation the host holds: one finished turn.
  defp held_history do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          case Agent.get_and_update(agent, &{&1, &1 + 1}) do
            0 -> %{tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}
            1 -> %{tool_calls: [%{id: "s1", name: "submit", arguments: %{"reply" => "A cat."}}]}
          end
        end
      )

    program = Imp.react("ticket -> reply", [look()], lm: lm, finish: :submit)
    {:ok, prediction} = Imp.call(program, %{ticket: "What is in the box?"})
    prediction.metadata.history
  end

  defp resume(lm) do
    Imp.react("ticket -> reply", [look()], lm: lm, finish: :submit)
    |> Imp.call(%{history: held_history(), max_iters: 0, last_request_note: @note})
  end

  defp requests(acc \\ []) do
    receive do
      {:request, messages, opts} -> requests([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @refused {:error,
            %Imp.LMError{
              status: 400,
              message:
                "Invalid value for 'tool_choice': supported string values are none, auto, required"
            }}

  for {name, forced} <- [ignores_submit: [:text], refuses_named: [:refused, :text]] do
    @forced forced

    test "#{name}: the extractor answers from the history alone, after the text it just wrote" do
      owner = self()
      {:ok, agent} = Agent.start_link(fn -> @forced end)

      lm =
        Imp.LM.Static.new(
          handler: fn messages, opts ->
            send(owner, {:request, messages, opts})

            case Agent.get_and_update(agent, fn
                   [next | rest] -> {next, rest}
                   [] -> {:extract, []}
                 end) do
              :refused -> @refused
              :text -> %{next_thought: @recap, tool_calls: []}
              :extract -> %{reasoning: "From the turn.", reply: @recap}
            end
          end
        )

      assert {:ok, prediction} = resume(lm)
      assert prediction.metadata.termination_reason == :extracted
      assert Imp.get(prediction, :reply) == @recap

      {extraction, opts} = List.last(requests())
      assert opts[:tools] in [nil, []]

      # The text the model just wrote is the last step before the request's
      # own user message, after the note.
      [written, request] = Enum.take(extraction, -2)
      assert {written.role, written.content} == {:assistant, @recap}
      assert request.role == :user
      # The note is its own user message, not a value under the `ticket`
      # marker, and the request after it starts on its instruction.
      assert Enum.at(extraction, -3) == %{role: :user, content: @note}
      assert request.content =~ ~r/\ARespond with /
    end
  end

  @meta_refusal ~S|{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"{\"error\":{\"code\":null,\"message\":\"only `\\\"auto\\\"` is supported for `tool_choice`. `\\\"none\\\"`, `\\\"required\\\"`, and named function choices are not currently supported\",\"param\":\"tool_choice\"}}","provider_name":"Meta"}}}|

  test "through OpenRouter to Meta, which cannot be forced, the extractor answers the resume" do
    owner = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        tools = for tool <- body["tools"] || [], do: tool["function"]["name"]
        send(owner, {:wire, tools, body["tool_choice"], List.last(body["messages"])["role"]})

        if tools == [],
          do: {200, completion(@extracted)},
          else: {400, @meta_refusal}
      end)

    lm =
      Imp.req_llm(%{provider: :openrouter, id: "fixture/model", base_url: base_url},
        api_key: "fixture",
        max_retries: 0,
        cache: false
      )

    assert {:ok, prediction} = resume(lm)
    assert prediction.metadata.termination_reason == :extracted
    assert Imp.get(prediction, :reply) == @recap

    assert [
             {["look", "submit"], %{"function" => %{"name" => "submit"}}, "user"},
             {["submit"], "required", "user"},
             {[], nil, "user"}
           ] = wire()
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
end
