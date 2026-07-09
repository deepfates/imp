defmodule DSEx.Adapters.Types do
  @moduledoc """
  Lightweight multimodal and tool-call value structs matching DSEx's adapter vocabulary.

  The conversion helpers are deliberately permissive for plain text values and
  deliberately strict for DSEx's typed structs. A free-form value can be rendered
  as text, but a `%File{}` without `:path`, `:url`, or `:data` is a malformed
  attachment and should fail at this boundary instead of becoming provider text.
  """

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

  @doc """
  Converts one DSEx content value into an OpenAI-compatible content block.

  Typed DSEx structs are validated strictly. Plain strings and unknown values
  are still rendered as text, which keeps simple prompts ergonomic while making
  malformed attachments visible.

      iex> alias DSEx.Adapters.Types
      iex> Types.to_openai(%Types.Image{url: "https://example.com/cat.png"})
      %{type: "image_url", image_url: %{url: "https://example.com/cat.png"}}

      iex> DSEx.Adapters.Types.to_openai("hello")
      %{type: "text", text: "hello"}

      iex> DSEx.Adapters.Types.to_openai(%DSEx.Adapters.Types.File{})
      ** (ArgumentError) DSEx.Adapters.Types.File expects binary :url, binary :path, or binary :data; got: %DSEx.Adapters.Types.File{path: nil, url: nil, data: nil, mime_type: nil, metadata: %{}}

  """
  def to_openai(%Image{url: url}) when is_binary(url) do
    %{type: "image_url", image_url: %{url: url}}
  end

  def to_openai(%Image{data: data, mime_type: mime_type}) when is_binary(data) do
    %{type: "image_url", image_url: %{url: data_uri(mime_type || "image/png", data)}}
  end

  def to_openai(%Image{} = image), do: invalid_type!(Image, "binary :url or binary :data", image)

  def to_openai(%Audio{data: data, mime_type: mime_type}) when is_binary(data) do
    %{
      type: "input_audio",
      input_audio: %{data: strip_data_uri(data), format: media_format(mime_type || "audio/wav")}
    }
  end

  def to_openai(%Audio{} = audio), do: invalid_type!(Audio, "binary :data", audio)

  def to_openai(%File{url: url}) when is_binary(url) do
    %{type: "file", file: %{file_url: url}}
  end

  def to_openai(%File{path: path, mime_type: mime_type}) when is_binary(path) do
    data = path |> read_file_attachment!() |> Base.encode64()
    %{type: "file", file: %{file_data: data_uri(mime_type || mime_type_from_path(path), data)}}
  end

  def to_openai(%File{data: data, mime_type: mime_type}) when is_binary(data) do
    %{type: "file", file: %{file_data: data_uri(mime_type || "application/octet-stream", data)}}
  end

  def to_openai(%File{} = file),
    do: invalid_type!(File, "binary :url, binary :path, or binary :data", file)

  def to_openai(%Document{text: text, metadata: metadata})
      when is_binary(text) and is_map(metadata) do
    %{type: "text", text: metadata_prefix(metadata) <> to_string(text)}
  end

  def to_openai(%Document{} = document),
    do: invalid_type!(Document, "binary :text and map :metadata", document)

  def to_openai(%Code{code: code, language: language}) when is_binary(code) do
    fence = language || ""
    %{type: "text", text: "```#{fence}\n#{code}\n```"}
  end

  def to_openai(%Code{} = code), do: invalid_type!(Code, "binary :code", code)

  def to_openai(%Reasoning{text: text}) when is_binary(text), do: %{type: "text", text: text}
  def to_openai(%Reasoning{} = reasoning), do: invalid_type!(Reasoning, "binary :text", reasoning)

  def to_openai(%DSEx.History{} = history),
    do:
      invalid_type!(
        DSEx.History,
        "provider chat messages use DSEx.Adapters.Types.History; DSEx.History stores signature-shaped field turns",
        history
      )

  def to_openai(%History{messages: messages}) when is_list(messages),
    do: Enum.map(messages, &message_to_openai/1)

  def to_openai(%History{} = history), do: invalid_type!(History, "list :messages", history)

  def to_openai(%Citation{text: text, source: source}) when is_binary(text) and is_binary(source),
    do: %{type: "text", text: "#{text}\nSource: #{source}"}

  def to_openai(%Citation{} = citation),
    do: invalid_type!(Citation, "binary :text and binary :source", citation)

  def to_openai(%Type{value: value}), do: to_openai(value)
  def to_openai(text) when is_binary(text), do: %{type: "text", text: text}
  def to_openai(value), do: %{type: "text", text: inspect(value)}

  @doc """
  Converts a single value or list of values into OpenAI-compatible content blocks.

      iex> alias DSEx.Adapters.Types
      iex> Types.content_to_openai(["hello", %Types.Document{text: "world"}])
      [%{type: "text", text: "hello"}, %{type: "text", text: "world"}]

      iex> DSEx.Adapters.Types.content_to_openai("hello")
      [%{type: "text", text: "hello"}]

  """
  def content_to_openai(values) when is_list(values), do: Enum.map(values, &to_openai/1)
  def content_to_openai(value), do: [to_openai(value)]

  @doc """
  Decodes a known OpenAI-compatible content block into a DSEx content struct.

  Known block types are strict: if a value claims to be an `image_url`,
  `input_audio`, `file`, or `text` block, it must have the expected payload.
  Unknown future provider block types pass through unchanged.

      iex> alias DSEx.Adapters.Types
      iex> Types.from_openai(%{"type" => "text", "text" => "notes"})
      %DSEx.Adapters.Types.Document{text: "notes", metadata: %{}}

      iex> future = %{"type" => "provider_future_block", "payload" => %{}}
      iex> DSEx.Adapters.Types.from_openai(future)
      %{"type" => "provider_future_block", "payload" => %{}}

      iex> DSEx.Adapters.Types.from_openai(%{"type" => "file", "file" => %{}})
      ** (ArgumentError) OpenAI-compatible content block "file" has malformed payload: %{"file" => %{}, "type" => "file"}

  """
  def from_openai(%{"type" => "image_url", "image_url" => %{"url" => url}}) when is_binary(url),
    do: image_from_url(url)

  def from_openai(%{type: "image_url", image_url: %{url: url}}) when is_binary(url),
    do: image_from_url(url)

  def from_openai(%{"type" => "input_audio", "input_audio" => %{"data" => data} = audio})
      when is_binary(data),
      do: %Audio{data: audio["data"], mime_type: mime_type("audio", audio["format"])}

  def from_openai(%{type: "input_audio", input_audio: %{data: data} = audio})
      when is_binary(data),
      do: %Audio{data: audio[:data], mime_type: mime_type("audio", audio[:format])}

  def from_openai(%{"type" => "file", "file" => %{"file_url" => url}}) when is_binary(url),
    do: %File{url: url}

  def from_openai(%{type: "file", file: %{file_url: url}}) when is_binary(url),
    do: %File{url: url}

  def from_openai(%{"type" => "file", "file" => %{"file_data" => data}}) when is_binary(data),
    do: file_from_data(data)

  def from_openai(%{type: "file", file: %{file_data: data}}) when is_binary(data),
    do: file_from_data(data)

  def from_openai(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %Document{text: text}

  def from_openai(%{type: "text", text: text}) when is_binary(text), do: %Document{text: text}

  def from_openai(%{"type" => type} = value)
      when type in ["image_url", "input_audio", "file", "text"],
      do: invalid_openai_block!(type, value)

  def from_openai(%{type: type} = value)
      when type in ["image_url", "input_audio", "file", "text"],
      do: invalid_openai_block!(type, value)

  def from_openai(value), do: value

  @doc """
  Decodes a single OpenAI-compatible content block or a list of blocks.

      iex> alias DSEx.Adapters.Types
      iex> Types.content_from_openai([%{"type" => "text", "text" => "hello"}])
      [%DSEx.Adapters.Types.Document{text: "hello", metadata: %{}}]

  """
  def content_from_openai(values) when is_list(values), do: Enum.map(values, &from_openai/1)
  def content_from_openai(value), do: from_openai(value)

  defp message_to_openai(%{role: role, content: content}) do
    %{role: to_string(role), content: content_to_openai(content)}
  end

  defp message_to_openai(message) do
    raise ArgumentError,
          "DSEx.Adapters.Types.History messages must be maps with :role and :content; got: #{inspect(message)}"
  end

  defp invalid_type!(module, expectation, value) do
    raise ArgumentError,
          "#{inspect(module)} expects #{expectation}; got: #{inspect(value)}"
  end

  defp invalid_openai_block!(type, value) do
    raise ArgumentError,
          "OpenAI-compatible content block #{inspect(type)} has malformed payload: #{inspect(value)}"
  end

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

  defp read_file_attachment!(path) do
    case Elixir.File.read(path) do
      {:ok, data} ->
        data

      {:error, reason} ->
        raise ArgumentError,
              "could not read DSEx file attachment #{inspect(path)}: #{:file.format_error(reason)}"
    end
  end

  defp mime_type_from_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".csv" -> "text/csv"
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".wav" -> "audio/wav"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      _ -> "application/octet-stream"
    end
  end
end
