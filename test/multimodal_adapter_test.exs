defmodule MultimodalAdapterTest do
  use ExUnit.Case

  alias Imp.Adapters.Types

  @fixtures Path.join(__DIR__, "fixtures/multimodal")

  test "chat adapter preserves typed image inputs as ordered message content" do
    signature = Imp.signature("question, image -> answer")

    [%{role: :system}, %{role: :user, content: content}] =
      Imp.Adapter.Chat.format(
        signature,
        %{
          question: "What landmark is shown?",
          image: %Types.Image{
            url: "https://example.com/eiffel-tower.jpg",
            metadata: %{detail: "high"}
          }
        },
        []
      )

    assert [prompt, %Types.Image{} = image, response_instruction] = content
    assert prompt == "[[ ## question ## ]]\nWhat landmark is shown?\n\n[[ ## image ## ]]\n"
    assert image.url == "https://example.com/eiffel-tower.jpg"
    assert image.metadata == %{detail: "high"}
    assert response_instruction =~ "Respond with the corresponding output fields"
  end

  test "chat adapter preserves typed images in signature-shaped history" do
    signature = Imp.signature("question, image, history -> answer")

    history =
      Imp.history([
        %{
          question: "What was shown before?",
          image: %Types.Image{url: "https://example.com/previous.jpg"},
          answer: "A bridge"
        }
      ])

    messages =
      Imp.Adapter.Chat.format(
        signature,
        %{question: "And now?", history: history},
        []
      )

    assert [%{role: :system}, %{role: :user, content: prior}, %{role: :assistant} | _] =
             messages

    assert Enum.any?(prior, &match?(%Types.Image{url: "https://example.com/previous.jpg"}, &1))
  end

  test "provider-shaped OpenAI image request and response traverse Predict and ReqLLM" do
    expected_user = fixture!("openai_image_request.json")
    provider_response = fixture!("openai_image_response.json")
    test_pid = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        send(test_pid, {:provider_request, request})
        {200, provider_response}
      end)

    lm =
      Imp.req_llm("openai:gpt-4-turbo",
        api_key: "sk-test",
        base_url: base_url <> "/v1"
      )

    program = Imp.predict("question, image -> answer", lm: lm)

    assert {:ok, prediction} =
             Imp.call(program, %{
               question: "What landmark is shown?",
               image: %Types.Image{
                 url: "https://example.com/eiffel-tower.jpg",
                 metadata: %{detail: "high"}
               }
             })

    assert Imp.get(prediction, :answer) == "Eiffel Tower"
    assert_received {:provider_request, %{body: body, path: "/v1/chat/completions"}}

    request_body = Jason.decode!(body)
    assert List.last(request_body["messages"]) == expected_user
  end

  test "encodes image/audio/file/document/code content to OpenAI-compatible blocks" do
    blocks =
      Types.content_to_openai([
        %Types.Image{url: "https://example.com/image.png"},
        %Types.Image{data: "abc123", mime_type: "image/jpeg"},
        %Types.Audio{data: "data:audio/wav;base64,UklGRg==", mime_type: "audio/wav"},
        %Types.File{data: "Zm9v", mime_type: "text/plain"},
        %Types.Document{text: "hello", metadata: %{id: "doc1"}},
        %Types.Code{code: "IO.puts(:ok)", language: "elixir"},
        %Types.Reasoning{text: "because"}
      ])

    assert Enum.at(blocks, 0) == %{
             type: "image_url",
             image_url: %{url: "https://example.com/image.png"}
           }

    assert get_in(Enum.at(blocks, 1), [:image_url, :url]) == "data:image/jpeg;base64,abc123"

    assert Enum.at(blocks, 2) == %{
             type: "input_audio",
             input_audio: %{data: "UklGRg==", format: "wav"}
           }

    assert get_in(Enum.at(blocks, 3), [:file, :file_data]) == "data:text/plain;base64,Zm9v"
    assert Enum.at(blocks, 4).text =~ "[metadata:"
    assert Enum.at(blocks, 5).text =~ "```elixir"
    assert Enum.at(blocks, 6) == %{type: "text", text: "because"}
  end

  test "encodes local file path attachments to OpenAI-compatible file data" do
    path = Path.join(System.tmp_dir!(), "imp-types-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "hello file")

    on_exit(fn -> File.rm(path) end)

    assert %{
             type: "file",
             file: %{file_data: "data:text/plain;base64,aGVsbG8gZmlsZQ=="}
           } = Types.to_openai(%Types.File{path: path})
  end

  test "decodes OpenAI-compatible multimodal content blocks back to adapter structs" do
    decoded =
      Types.content_from_openai([
        %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,iVBORw0KGgo="}},
        %{"type" => "input_audio", "input_audio" => %{"data" => "UklGRg==", "format" => "wav"}},
        %{"type" => "file", "file" => %{"file_url" => "https://example.com/report.pdf"}},
        %{"type" => "file", "file" => %{"file_data" => "data:text/plain;base64,Zm9v"}},
        %{"type" => "text", "text" => "notes"}
      ])

    assert [
             %Types.Image{data: "iVBORw0KGgo=", mime_type: "image/png"},
             %Types.Audio{data: "UklGRg==", mime_type: "audio/wav"},
             %Types.File{url: "https://example.com/report.pdf"},
             %Types.File{data: "Zm9v", mime_type: "text/plain"},
             %Types.Document{text: "notes"}
           ] = decoded
  end

  test "reports malformed typed content at the adapter boundary" do
    assert_raise ArgumentError,
                 ~r/Imp\.Adapters\.Types\.File expects binary :url, binary :path, or binary :data/,
                 fn -> Types.to_openai(%Types.File{}) end

    assert_raise ArgumentError,
                 ~r/Imp\.Adapters\.Types\.Image expects binary :url or binary :data/,
                 fn -> Types.to_openai(%Types.Image{url: 123}) end

    assert_raise ArgumentError,
                 ~r/Imp\.Adapters\.Types\.Document expects binary :text and map :metadata/,
                 fn -> Types.to_openai(%Types.Document{text: nil}) end

    assert_raise ArgumentError,
                 ~r/History messages must be maps with :role and :content/,
                 fn -> Types.to_openai(%Types.History{messages: [:bad_message]}) end
  end

  test "reports malformed known OpenAI-compatible content blocks" do
    assert_raise ArgumentError,
                 ~r/OpenAI-compatible content block "image_url" has malformed payload/,
                 fn ->
                   Types.from_openai(%{"type" => "image_url", "image_url" => %{}})
                 end

    assert_raise ArgumentError,
                 ~r/OpenAI-compatible content block "input_audio" has malformed payload/,
                 fn ->
                   Types.from_openai(%{type: "input_audio", input_audio: %{format: "wav"}})
                 end

    assert_raise ArgumentError,
                 ~r/OpenAI-compatible content block "file" has malformed payload/,
                 fn ->
                   Types.from_openai(%{"type" => "file", "file" => %{}})
                 end

    assert_raise ArgumentError,
                 ~r/OpenAI-compatible content block "text" has malformed payload/,
                 fn ->
                   Types.from_openai(%{type: "text", text: 123})
                 end
  end

  test "keeps plain fallback values textual without hiding malformed Imp structs" do
    assert Types.to_openai(%{arbitrary: :value}) == %{type: "text", text: "%{arbitrary: :value}"}
    assert Types.content_to_openai("hello") == [%{type: "text", text: "hello"}]

    future_block = %{"type" => "provider_future_block", "payload" => %{}}
    assert Types.from_openai(future_block) == future_block
  end

  test "normalizes ToolCalls primitive maps and formats provider payloads" do
    calls =
      Types.ToolCalls.from_dict_list([
        %{"id" => "call_search", "name" => "search", "args" => %{"query" => "cats"}},
        %{
          id: "call_translate",
          type: "function",
          function: %{name: "translate", arguments: ~s({"text":"world"})}
        }
      ])

    assert %Types.ToolCalls{
             tool_calls: [
               %Types.ToolCall{
                 id: "call_search",
                 name: "search",
                 arguments: %{"query" => "cats"}
               },
               %Types.ToolCall{
                 id: "call_translate",
                 name: "translate",
                 arguments: %{"text" => "world"}
               }
             ]
           } = calls

    assert Types.ToolCalls.format(calls) == %{
             tool_calls: [
               %{id: "call_search", name: "search", args: %{"query" => "cats"}},
               %{id: "call_translate", name: "translate", args: %{"text" => "world"}}
             ]
           }

    assert Types.to_openai(calls) == Types.ToolCalls.format(calls)
  end

  test "formats tool results and reports malformed tool calls" do
    result = Types.ToolResult.new(:lookup, %{answer: "Paris"}, id: "call_lookup")
    results = Types.ToolCallResults.new([result])

    assert Types.to_openai(result) == %{
             id: "call_lookup",
             name: "lookup",
             result: %{answer: "Paris"}
           }

    assert Types.to_openai(results) == %{
             tool_call_results: [
               %{id: "call_lookup", name: "lookup", result: %{answer: "Paris"}}
             ]
           }

    assert_raise ArgumentError, ~r/tool call requires :name/, fn ->
      Types.ToolCall.from_map(%{arguments: %{query: "x"}})
    end
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
