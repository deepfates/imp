defmodule DSPy.Adapters.Types do
  @moduledoc "Lightweight multimodal and tool-call value structs matching DSPy's adapter vocabulary."

  defmodule Image, do: defstruct([:url, :data, :mime_type, metadata: %{}])
  defmodule Audio, do: defstruct([:url, :data, :mime_type, metadata: %{}])
  defmodule File, do: defstruct([:path, :url, :data, :mime_type, metadata: %{}])
  defmodule Document, do: defstruct([:text, metadata: %{}])
  defmodule Code, do: defstruct([:code, language: nil])
  defmodule Reasoning, do: defstruct([:text, metadata: %{}])
  defmodule History, do: defstruct(messages: [])
  defmodule Citation, do: defstruct([:text, :source, metadata: %{}])
  defmodule ToolCall, do: defstruct([:name, :arguments, id: nil])
  defmodule ToolResult, do: defstruct([:name, :result, id: nil])
  defmodule Type, do: defstruct([:value, metadata: %{}])
  defmodule ToolCalls, do: defstruct(tool_calls: [])
  defmodule ToolCallResults, do: defstruct(tool_call_results: [])

  def to_openai(%Image{url: url}) when is_binary(url) do
    %{type: "image_url", image_url: %{url: url}}
  end

  def to_openai(%Image{data: data, mime_type: mime_type}) when is_binary(data) do
    %{type: "image_url", image_url: %{url: data_uri(mime_type || "image/png", data)}}
  end

  def to_openai(%Audio{data: data, mime_type: mime_type}) when is_binary(data) do
    %{
      type: "input_audio",
      input_audio: %{data: strip_data_uri(data), format: media_format(mime_type || "audio/wav")}
    }
  end

  def to_openai(%File{url: url}) when is_binary(url) do
    %{type: "file", file: %{file_url: url}}
  end

  def to_openai(%File{data: data, mime_type: mime_type}) when is_binary(data) do
    %{type: "file", file: %{file_data: data_uri(mime_type || "application/octet-stream", data)}}
  end

  def to_openai(%Document{text: text, metadata: metadata}) do
    %{type: "text", text: metadata_prefix(metadata) <> to_string(text)}
  end

  def to_openai(%Code{code: code, language: language}) do
    fence = language || ""
    %{type: "text", text: "```#{fence}\n#{code}\n```"}
  end

  def to_openai(%Reasoning{text: text}), do: %{type: "text", text: to_string(text)}
  def to_openai(%History{messages: messages}), do: Enum.map(messages, &message_to_openai/1)

  def to_openai(%Citation{text: text, source: source}),
    do: %{type: "text", text: "#{text}\nSource: #{source}"}

  def to_openai(%Type{value: value}), do: to_openai(value)
  def to_openai(text) when is_binary(text), do: %{type: "text", text: text}
  def to_openai(value), do: %{type: "text", text: inspect(value)}

  def content_to_openai(values) when is_list(values), do: Enum.map(values, &to_openai/1)
  def content_to_openai(value), do: [to_openai(value)]

  def from_openai(%{"type" => "image_url", "image_url" => %{"url" => url}}),
    do: image_from_url(url)

  def from_openai(%{type: "image_url", image_url: %{url: url}}),
    do: image_from_url(url)

  def from_openai(%{"type" => "input_audio", "input_audio" => audio}),
    do: %Audio{data: audio["data"], mime_type: mime_type("audio", audio["format"])}

  def from_openai(%{type: "input_audio", input_audio: audio}),
    do: %Audio{data: audio[:data], mime_type: mime_type("audio", audio[:format])}

  def from_openai(%{"type" => "file", "file" => %{"file_url" => url}}),
    do: %File{url: url}

  def from_openai(%{type: "file", file: %{file_url: url}}),
    do: %File{url: url}

  def from_openai(%{"type" => "file", "file" => %{"file_data" => data}}),
    do: file_from_data(data)

  def from_openai(%{type: "file", file: %{file_data: data}}),
    do: file_from_data(data)

  def from_openai(%{"type" => "text", "text" => text}), do: %Document{text: text}
  def from_openai(%{type: "text", text: text}), do: %Document{text: text}
  def from_openai(value), do: value

  def content_from_openai(values) when is_list(values), do: Enum.map(values, &from_openai/1)
  def content_from_openai(value), do: from_openai(value)

  defp message_to_openai(%{role: role, content: content}) do
    %{role: to_string(role), content: content_to_openai(content)}
  end

  defp message_to_openai(message), do: message

  defp metadata_prefix(metadata) when map_size(metadata) == 0, do: ""
  defp metadata_prefix(metadata), do: "[metadata: #{Jason.encode!(metadata)}]\n"

  defp data_uri(mime_type, data) do
    if String.starts_with?(data, "data:"), do: data, else: "data:#{mime_type};base64,#{data}"
  end

  defp image_from_url("data:" <> _rest = uri) do
    %Image{data: strip_data_uri(uri), mime_type: data_uri_mime_type(uri)}
  end

  defp image_from_url(url), do: %Image{url: url}

  defp file_from_data("data:" <> _rest = uri) do
    %File{data: strip_data_uri(uri), mime_type: data_uri_mime_type(uri)}
  end

  defp file_from_data(data), do: %File{data: data}

  defp data_uri_mime_type("data:" <> rest) do
    rest
    |> String.split(";", parts: 2)
    |> hd()
  end

  defp strip_data_uri("data:" <> rest) do
    rest
    |> String.split(",", parts: 2)
    |> List.last()
  end

  defp strip_data_uri(data), do: data

  defp media_format(mime_type) do
    mime_type
    |> String.split("/")
    |> List.last()
    |> String.split(";")
    |> hd()
  end

  defp mime_type(_kind, nil), do: nil
  defp mime_type(kind, format), do: "#{kind}/#{format}"
end
