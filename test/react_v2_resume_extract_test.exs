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
      assert Enum.at(extraction, -3).content =~ @note
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

  # A provider that refused the forced choices for a model refuses them again:
  # the refusal is a property of the model's endpoint, not of the request.
  # Once both have been refused, a later forced `submit` on the same model
  # goes to the extractor without asking again. A provider that refuses only
  # the named choice is asked for "required" alone the next time.
  for {name, refuses, again} <- [
        {:refuses_both, [:named, :required], [{[], nil}]},
        {:refuses_named, [:named], [{["submit"], "required"}]}
      ] do
    @refuses refuses
    @again again

    test "#{name}: a later resume on the same model does not repeat a refused choice" do
      owner = self()
      refuses = @refuses

      base_url =
        Imp.Test.LocalHTTP.start(fn request ->
          body = Jason.decode!(request.body)
          tools = for tool <- body["tools"] || [], do: tool["function"]["name"]
          send(owner, {:wire, tools, body["tool_choice"], List.last(body["messages"])["role"]})

          refused =
            case body["tool_choice"] do
              %{"function" => _} -> :named in refuses
              "required" -> :required in refuses
              _other -> false
            end

          cond do
            refused -> {400, @meta_refusal}
            tools == [] -> {200, completion(@extracted)}
            true -> {200, submit_completion(@recap)}
          end
        end)

      lm =
        Imp.req_llm(%{provider: :openrouter, id: "fixture/model", base_url: base_url},
          api_key: "fixture",
          max_retries: 0,
          cache: false
        )

      assert {:ok, first} = resume(lm)
      assert Imp.get(first, :reply) == @recap
      _first_requests = wire()

      assert {:ok, second} = resume(lm)
      assert Imp.get(second, :reply) == @recap

      assert Enum.map(wire(), fn {tools, choice, _role} -> {tools, choice} end) == @again
    end
  end

  test "another model on the same provider is still forced by name" do
    owner = self()

    serve = fn refuse? ->
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        send(owner, {:wire, [], body["tool_choice"], nil})

        cond do
          refuse? and body["tool_choice"] not in [nil, "auto"] -> {400, @meta_refusal}
          body["tools"] in [nil, []] -> {200, completion(@extracted)}
          true -> {200, submit_completion(@recap)}
        end
      end)
    end

    lm = fn base_url, id ->
      Imp.req_llm(%{provider: :openrouter, id: id, base_url: base_url},
        api_key: "fixture",
        max_retries: 0,
        cache: false
      )
    end

    assert {:ok, _} = resume(lm.(serve.(true), "fixture/refuses"))
    _refused = wire()

    assert {:ok, prediction} = resume(lm.(serve.(false), "fixture/accepts"))
    assert prediction.metadata.termination_reason == :forced_submit

    assert [{[], %{"function" => %{"name" => "submit"}}, nil}] = wire()
  end

  defp submit_completion(reply),
    do: %{
      "id" => "r",
      "model" => "fixture/model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "s2",
                "type" => "function",
                "function" => %{
                  "name" => "submit",
                  "arguments" => Jason.encode!(%{"reply" => reply})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ]
    }

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
