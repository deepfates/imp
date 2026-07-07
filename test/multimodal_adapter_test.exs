defmodule MultimodalAdapterTest do
  use ExUnit.Case

  alias DSEx.Adapters.Types

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
end
