defmodule ReasoningContinuityTest do
  use ExUnit.Case, async: true

  @continuation_token "sk-protocolabcdefghijklmnopqrstuvwx1234567890"
  @input_token "sk-inputcredentialabcdefghijklmnop1234567890"

  defmodule CaptureClient do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:native_messages, messages})

      {:ok,
       %ReqLLM.Response{
         id: "capture-response",
         model: to_string(model),
         message: ReqLLM.Context.assistant("done"),
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  test "OpenRouter reasoning blocks survive tool continuation and a JSON history reload" do
    details = [
      %{
        "type" => "reasoning.encrypted",
        "data" => @continuation_token,
        "id" => "reasoning-1",
        "format" => "fixture-v1",
        "index" => 0,
        "provider_extension" => %{"token" => @continuation_token, "order" => [2, 1]}
      },
      %{
        "type" => "reasoning.text",
        "text" => "Use the lookup result.",
        "signature" => @continuation_token,
        "format" => "fixture-v1",
        "index" => 1
      }
    ]

    assert_continuity(:openrouter, "reasoning_details", details)
  end

  test "DeepSeek native reasoning text survives tool continuation and a JSON history reload" do
    assert_continuity(
      :deepseek,
      "reasoning_content",
      "  Native plan: #{@continuation_token}\nuse lookup.\n"
    )
  end

  test "atom and string keyed assistant messages retain native reasoning without duplicating it" do
    detail = %ReqLLM.Message.ReasoningDetails{
      provider: :openrouter,
      text: "native plan",
      signature: @continuation_token,
      provider_data: %{"opaque" => [@continuation_token]}
    }

    lm =
      Imp.req_llm("openrouter:fixture/model",
        req_module: CaptureClient,
        test_pid: self(),
        cache: false
      )

    for stored <- [detail, Map.from_struct(detail)], keys <- [:atom, :string] do
      assistant = %{
        role: :assistant,
        content: [%Imp.Adapter.Types.Reasoning{text: "native plan"}, "visible answer"],
        reasoning_content: "native plan",
        reasoning_details: [stored]
      }

      assistant =
        if keys == :string,
          do: Map.new(assistant, fn {key, value} -> {Atom.to_string(key), value} end),
          else: assistant

      assert {:ok, _} = Imp.Clients.ReqLLM.generate(lm, [assistant], [])
      assert_received {:native_messages, [%ReqLLM.Message{} = message]}
      assert message.reasoning_details == [detail]

      assert [
               %ReqLLM.Message.ContentPart{type: :thinking, text: "native plan"},
               %ReqLLM.Message.ContentPart{type: :text, text: "visible answer"}
             ] = message.content
    end
  end

  test "Anthropic tool history replays signed and redacted blocks once after nested JSON decoding" do
    details = [
      %ReqLLM.Message.ReasoningDetails{
        provider: :anthropic,
        text: "native plan",
        signature: @continuation_token,
        index: 0
      },
      %ReqLLM.Message.ReasoningDetails{
        provider: :anthropic,
        encrypted?: true,
        provider_data: %{"data" => @continuation_token},
        index: 1
      }
    ]

    lm =
      Imp.req_llm("anthropic:claude-sonnet-4-6",
        req_module: CaptureClient,
        test_pid: self(),
        cache: false
      )

    for stored <- [details, details |> Jason.encode!() |> Jason.decode!()] do
      assistant = %{
        role: :assistant,
        content: [%Imp.Adapter.Types.Reasoning{text: "native plan"}, "visible answer"],
        reasoning_content: "native plan",
        reasoning_details: stored,
        tool_calls: [%{id: "signed-call", name: "lookup", arguments: %{query: "fixture"}}]
      }

      assert {:ok, _} = Imp.Clients.ReqLLM.generate(lm, [assistant], [])
      assert_received {:native_messages, [%ReqLLM.Message{} = message]}
      assert message.reasoning_details == details

      wire =
        ReqLLM.Providers.Anthropic.Context.encode_request(
          ReqLLM.Context.new([message]),
          "claude-fixture"
        )

      assert [%{role: "assistant", content: blocks}] = wire.messages

      assert blocks == [
               %{type: "thinking", thinking: "native plan", signature: @continuation_token},
               %{type: "redacted_thinking", data: @continuation_token},
               %{type: "text", text: "visible answer"},
               %{
                 type: "tool_use",
                 id: "signed-call",
                 name: "lookup",
                 input: %{"query" => "fixture"}
               }
             ]
    end
  end

  test "raw provider details survive message JSON decoding and ordinary messages stay ordinary" do
    raw = %{"type" => "reasoning.encrypted", "data" => @continuation_token}

    lm =
      Imp.req_llm("openrouter:fixture/model",
        req_module: CaptureClient,
        test_pid: self(),
        cache: false
      )

    messages =
      [
        %{role: :assistant, content: "", reasoning_details: [raw]},
        %{role: :assistant, content: "ordinary answer"},
        %{role: :user, content: "question", reasoning_content: "not assistant reasoning"}
      ]
      |> Jason.encode!()
      |> Jason.decode!()

    assert {:ok, _} = Imp.Clients.ReqLLM.generate(lm, messages, [])
    assert_received {:native_messages, [reasoning, ordinary, user]}
    assert reasoning.reasoning_details == [raw]
    assert ordinary.reasoning_details == nil
    assert [%ReqLLM.Message.ContentPart{type: :text, text: "ordinary answer"}] = ordinary.content
    assert [%ReqLLM.Message.ContentPart{type: :text, text: "question"}] = user.content
  end

  test "normalized JSON details restore known providers without atomizing opaque extension keys" do
    extension_key = "unknown-reasoning-extension-#{System.unique_integer([:positive])}"
    unknown_provider = "unknown-reasoning-provider-#{System.unique_integer([:positive])}"

    details =
      for provider <- [:anthropic, :google, :openai, :openrouter] do
        %ReqLLM.Message.ReasoningDetails{
          provider: provider,
          text: "native plan",
          signature: @continuation_token,
          provider_data: %{extension_key => @continuation_token}
        }
      end

    raw_unknown = %{"provider" => unknown_provider, "type" => "reasoning.encrypted"}

    lm =
      Imp.req_llm("openrouter:fixture/model",
        req_module: CaptureClient,
        test_pid: self(),
        cache: false
      )

    stored = (details ++ [raw_unknown]) |> Jason.encode!() |> Jason.decode!()
    messages = [%{"role" => "assistant", "content" => "", "reasoning_details" => stored}]
    assert {:ok, _} = Imp.Clients.ReqLLM.generate(lm, messages, [])
    assert_received {:native_messages, [message]}
    assert message.reasoning_details == details ++ [raw_unknown]
    assert_raise ArgumentError, fn -> String.to_existing_atom(extension_key) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_provider) end
  end

  defp assert_continuity(provider, field, value) do
    owner = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        count = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
        body = Jason.decode!(request.body)
        send(owner, {:wire_request, count, body})

        {name, arguments} =
          if count == 1,
            do: {"lookup", %{"query" => "fixture"}},
            else: {"submit", %{"answer" => "done"}}

        {200,
         %{
           "id" => "completion-#{count}",
           "object" => "chat.completion",
           "model" => body["model"],
           "choices" => [
             %{
               "index" => 0,
               "finish_reason" => "tool_calls",
               "message" => %{
                 "role" => "assistant",
                 "content" => "",
                 field => value,
                 "tool_calls" => [
                   %{
                     "id" => "original-call-#{count}",
                     "type" => "function",
                     "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
                   }
                 ]
               }
             }
           ],
           "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 3, "total_tokens" => 5}
         }}
      end)

    lm =
      Imp.req_llm(
        %{provider: provider, id: "fixture/model", model: "fixture/model", base_url: base_url},
        api_key: "local-test-key",
        cache: false,
        req_http_options: [retry: false, max_retries: 0]
      )

    lookup = Imp.tool(:lookup, "Read an immutable fixture", fn %{query: "fixture"} -> "found" end)
    program = Imp.react_v2("question -> answer", [lookup], lm: lm, max_iters: 4)

    assert {:ok, run} =
             Imp.Run.start(program, %{question: "Look up the fixture. #{@input_token}"})

    assert {:ok, first} = Task.await(run.task)
    events = Imp.Run.events(run)
    assert :ok = Imp.Run.stop(run)
    assert Imp.get(first, :termination_reason) == :submit
    assert Imp.get(first, :answer) == "done"
    assert_received {:wire_request, 1, _initial}
    assert_received {:wire_request, 2, continuation}

    history = Imp.get(first, :history)
    refute inspect(history, limit: :infinity) =~ @input_token

    restored =
      history |> Imp.History.dump() |> Jason.encode!() |> Jason.decode!() |> Imp.History.load()

    restarted = Imp.react_v2("question -> answer", [lookup], lm: lm, max_iters: 4)

    assert {:ok, resumed} = Imp.call(restarted, %{question: "Continue.", history: restored})
    assert Imp.get(resumed, :answer) == "done"
    assert Agent.get(counter, & &1) == 3
    assert_received {:wire_request, 3, after_reload}

    assert_replayed(continuation, "original-call-1", field, value)
    assert_replayed(after_reload, "original-call-1", field, value)
    assert_replayed(after_reload, "original-call-2", field, value)

    # Operational continuation data is lossless; diagnostic copies still use
    # the ordinary credential redactor, including inside provider extensions.
    refute inspect(Imp.History.redact(history), limit: :infinity) =~ @continuation_token
    assert Enum.any?(events, &(&1.kind == :model_response))
    assert Enum.any?(events, &(&1.kind == :run_finished))
    refute inspect(events, limit: :infinity) =~ @continuation_token
  end

  defp assert_replayed(request, id, field, value) do
    assistant =
      Enum.find(request["messages"], fn message ->
        message["role"] == "assistant" and
          Enum.any?(message["tool_calls"] || [], &(&1["id"] == id))
      end)

    assert assistant, "missing original assistant tool call #{id}"
    assert assistant[field] == value

    assert Enum.any?(request["messages"], fn message ->
             message["role"] == "tool" and message["tool_call_id"] == id
           end)
  end
end
