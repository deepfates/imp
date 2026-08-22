defmodule Imp.Adapter.Types do
  @moduledoc """
  Lightweight multimodal and tool-call value structs matching Imp's adapter vocabulary.

  The conversion helpers are deliberately permissive for plain text values and
  deliberately strict for Imp's typed structs. A free-form value can be rendered
  as text, but a `%File{}` without `:path`, `:url`, or `:data` is a malformed
  attachment and should fail at this boundary instead of becoming provider text.
  """

  defmodule Image do
    defstruct [:url, :data, :mime_type, metadata: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule Audio, do: defstruct([:url, :data, :mime_type, metadata: %{}])
  defmodule File, do: defstruct([:path, :url, :data, :mime_type, metadata: %{}])
  defmodule Document, do: defstruct([:text, metadata: %{}])

  defmodule Code do
    @moduledoc """
    Typed source code used by signature-level code inputs and outputs.

    `new/2` accepts plain or markdown-fenced code and removes the first fenced
    block's delimiters. The language defaults to `"python"`, matching DSPy's
    `Code` type, and can be carried explicitly by a signature field.
    """

    defstruct [:code, language: nil]

    @type t :: %__MODULE__{code: String.t(), language: String.t() | nil}

    def new(value, opts \\ [])

    def new(%__MODULE__{code: code, language: language}, opts) when is_binary(code) do
      %__MODULE__{
        code: filter(code),
        language: normalize_language(Keyword.get(opts, :language, language || "python"))
      }
    end

    def new(value, opts) when is_binary(value) do
      %__MODULE__{
        code: filter(value),
        language: normalize_language(Keyword.get(opts, :language, "python"))
      }
    end

    def new(%{} = value, opts) do
      code = Map.get(value, :code, Map.get(value, "code"))
      language = Map.get(value, :language, Map.get(value, "language"))

      if is_binary(code) do
        new(code, Keyword.put_new(opts, :language, language || "python"))
      else
        raise ArgumentError, "Imp.Adapter.Types.Code requires a binary :code field"
      end
    end

    def new(value, _opts) do
      raise ArgumentError,
            "Imp.Adapter.Types.Code expects code text, a Code struct, or a map with binary :code; got: #{inspect(value)}"
    end

    @doc "Returns the plain source text carried by a code value."
    def format(%__MODULE__{code: code}) when is_binary(code), do: code

    @doc "Language-aware prompt guidance for a signature-level code field."
    def description(language \\ "python") do
      language = normalize_language(language)

      "Code represented in a string, specified in the `code` field. If this is an output field, the code " <>
        "field should follow the markdown code block format, e.g. \n```#{String.downcase(language)}\n{code}\n```" <>
        "\nProgramming language: #{language}"
    end

    @doc false
    def filter(code) when is_binary(code) do
      case Regex.run(~r/```(?:[^\n]*)\n(.*?)```/s, code) do
        [_all, fenced] -> String.trim(fenced)
        nil -> filter_simple(code)
      end
    end

    defp filter_simple(code) do
      case Regex.run(~r/```(.*?)```/s, code) do
        [_all, fenced] -> String.trim(fenced)
        nil -> code
      end
    end

    defp normalize_language(language) when is_atom(language), do: Atom.to_string(language)
    defp normalize_language(language) when is_binary(language), do: language

    defp normalize_language(language) do
      raise ArgumentError,
            "Imp.Adapter.Types.Code language must be a string or atom, got: #{inspect(language)}"
    end
  end

  defmodule Reasoning, do: defstruct([:text, metadata: %{}])
  defmodule History, do: defstruct(messages: [])
  defmodule Citation, do: defstruct([:text, :source, metadata: %{}])

  defmodule ToolCall do
    @moduledoc "Provider-native tool call value with stable id, name, and arguments."
    defstruct [:name, arguments: %{}, id: nil]

    def new(name, arguments \\ %{}, opts \\ []) do
      %__MODULE__{
        name: name,
        arguments: normalize_arguments(arguments),
        id: Keyword.get(opts, :id)
      }
    end

    # DSPy ToolCalls.ToolCall.format (dspy/adapters/types/tool.py): the OpenAI
    # wire shape `{"type": "function", "function": {"name", "arguments"}}`.
    # Imp's stable id (absent upstream) rides at the top level when present,
    # matching where OpenAI carries tool-call ids.
    def format(%__MODULE__{} = call) do
      %{
        type: "function",
        function: %{name: to_string(call.name), arguments: normalize_arguments(call.arguments)}
      }
      |> maybe_put(:id, call.id)
    end

    def from_map(%__MODULE__{} = call), do: call

    def from_map(%{function: function} = call) do
      from_function(function, Map.get(call, :id))
    end

    def from_map(%{"function" => function} = call) do
      from_function(function, Map.get(call, "id"))
    end

    def from_map(%{} = call) do
      name =
        call
        |> Map.get(:name, Map.get(call, "name"))
        |> case do
          nil -> Map.get(call, :recipient_name, Map.get(call, "recipient_name"))
          value -> value
        end
        |> normalize_name()

      arguments =
        Map.get(
          call,
          :arguments,
          Map.get(
            call,
            "arguments",
            Map.get(
              call,
              :args,
              Map.get(call, "args", Map.get(call, :parameters, Map.get(call, "parameters", %{})))
            )
          )
        )

      id = Map.get(call, :id, Map.get(call, "id"))

      if is_nil(name) do
        raise ArgumentError, "tool call requires :name or \"name\"; got: #{inspect(call)}"
      end

      %__MODULE__{name: name, arguments: normalize_arguments(arguments), id: id}
    end

    def from_map(call) do
      raise ArgumentError, "tool call must be a map; got: #{inspect(call)}"
    end

    defp from_function(function, id) when is_map(function) do
      name = Map.get(function, :name, Map.get(function, "name"))
      arguments = Map.get(function, :arguments, Map.get(function, "arguments", %{}))

      if is_nil(name) do
        raise ArgumentError,
              "OpenAI-style tool call function requires name; got: #{inspect(function)}"
      end

      %__MODULE__{name: name, arguments: normalize_arguments(arguments), id: id}
    end

    defp from_function(function, _id) do
      raise ArgumentError,
            "OpenAI-style tool call function must be a map; got: #{inspect(function)}"
    end

    defp normalize_arguments(arguments) when is_binary(arguments) do
      case Jason.decode(arguments) do
        {:ok, decoded} when is_map(decoded) -> decoded
        {:ok, decoded} -> %{"value" => decoded}
        {:error, _reason} -> arguments
      end
    end

    defp normalize_arguments(nil), do: %{}
    defp normalize_arguments(arguments) when is_map(arguments), do: arguments
    defp normalize_arguments(arguments), do: arguments

    defp normalize_name("functions." <> name), do: name
    defp normalize_name(name), do: name

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end

  defmodule ToolResult do
    @moduledoc "Provider-native result for a previous tool call."
    defstruct [:name, :result, id: nil]

    def new(name, result, opts \\ []),
      do: %__MODULE__{name: name, result: result, id: Keyword.get(opts, :id)}

    def format(%__MODULE__{} = result) do
      %{name: to_string(result.name), result: result.result}
      |> maybe_put(:id, result.id)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end

  defmodule Type, do: defstruct([:value, metadata: %{}])

  defmodule ToolCalls do
    @moduledoc "Collection of provider-native tool calls."
    defstruct tool_calls: []

    def new(tool_calls \\ []),
      do: %__MODULE__{tool_calls: Enum.map(tool_calls, &Imp.Adapter.Types.ToolCall.from_map/1)}

    def from_dict_list(tool_calls) when is_list(tool_calls), do: new(tool_calls)

    def from_dict_list(tool_calls) do
      raise ArgumentError,
            "ToolCalls.from_dict_list/1 expects a list, got: #{inspect(tool_calls)}"
    end

    def format(%__MODULE__{tool_calls: tool_calls}) do
      %{tool_calls: Enum.map(tool_calls, &Imp.Adapter.Types.ToolCall.format/1)}
    end
  end

  defmodule ToolCallResults do
    @moduledoc "Collection of provider-native tool results."
    defstruct tool_call_results: []

    def new(results \\ []),
      do: %__MODULE__{tool_call_results: Enum.map(results, &normalize_result/1)}

    def format(%__MODULE__{tool_call_results: results}) do
      %{tool_call_results: Enum.map(results, &Imp.Adapter.Types.ToolResult.format/1)}
    end

    defp normalize_result(%Imp.Adapter.Types.ToolResult{} = result), do: result

    defp normalize_result(%{} = result) do
      Imp.Adapter.Types.ToolResult.new(
        Map.get(result, :name, Map.get(result, "name")),
        Map.get(result, :result, Map.get(result, "result")),
        id: Map.get(result, :id, Map.get(result, "id"))
      )
    end
  end

  @doc """
  Converts one Imp content value into an OpenAI-compatible content block.

  Typed Imp structs are validated strictly. Plain strings and unknown values
  are still rendered as text, which keeps simple prompts ergonomic while making
  malformed attachments visible.

      iex> alias Imp.Adapter.Types
      iex> Types.to_openai(%Types.Image{url: "https://example.com/cat.png"})
      %{type: "image_url", image_url: %{url: "https://example.com/cat.png"}}

      iex> Imp.Adapter.Types.to_openai("hello")
      %{type: "text", text: "hello"}

      iex> Imp.Adapter.Types.to_openai(%Imp.Adapter.Types.File{})
      ** (ArgumentError) Imp.Adapter.Types.File expects binary :url, binary :path, or binary :data; got: %Imp.Adapter.Types.File{path: nil, url: nil, data: nil, mime_type: nil, metadata: %{}}

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

  def to_openai(%Imp.History{} = history),
    do:
      invalid_type!(
        Imp.History,
        "provider chat messages use Imp.Adapter.Types.History; Imp.History stores signature-shaped field turns",
        history
      )

  def to_openai(%History{messages: messages}) when is_list(messages),
    do: Enum.map(messages, &message_to_openai/1)

  def to_openai(%History{} = history), do: invalid_type!(History, "list :messages", history)

  def to_openai(%Citation{text: text, source: source}) when is_binary(text) and is_binary(source),
    do: %{type: "text", text: "#{text}\nSource: #{source}"}

  def to_openai(%Citation{} = citation),
    do: invalid_type!(Citation, "binary :text and binary :source", citation)

  def to_openai(%ToolCall{} = call), do: ToolCall.format(call)
  def to_openai(%ToolCalls{} = calls), do: ToolCalls.format(calls)
  def to_openai(%ToolResult{} = result), do: ToolResult.format(result)
  def to_openai(%ToolCallResults{} = results), do: ToolCallResults.format(results)

  def to_openai(%Type{value: value}), do: to_openai(value)
  def to_openai(text) when is_binary(text), do: %{type: "text", text: text}
  def to_openai(value), do: %{type: "text", text: inspect(value)}

  @doc """
  Converts a single value or list of values into OpenAI-compatible content blocks.

      iex> alias Imp.Adapter.Types
      iex> Types.content_to_openai(["hello", %Types.Document{text: "world"}])
      [%{type: "text", text: "hello"}, %{type: "text", text: "world"}]

      iex> Imp.Adapter.Types.content_to_openai("hello")
      [%{type: "text", text: "hello"}]

  """
  def content_to_openai(values) when is_list(values), do: Enum.map(values, &to_openai/1)
  def content_to_openai(value), do: [to_openai(value)]

  @doc """
  Decodes a known OpenAI-compatible content block into an Imp content struct.

  Known block types are strict: if a value claims to be an `image_url`,
  `input_audio`, `file`, or `text` block, it must have the expected payload.
  Unknown future provider block types pass through unchanged.

      iex> alias Imp.Adapter.Types
      iex> Types.from_openai(%{"type" => "text", "text" => "notes"})
      %Imp.Adapter.Types.Document{text: "notes", metadata: %{}}

      iex> future = %{"type" => "provider_future_block", "payload" => %{}}
      iex> Imp.Adapter.Types.from_openai(future)
      %{"type" => "provider_future_block", "payload" => %{}}

      iex> Imp.Adapter.Types.from_openai(%{"type" => "file", "file" => %{}})
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

      iex> alias Imp.Adapter.Types
      iex> Types.content_from_openai([%{"type" => "text", "text" => "hello"}])
      [%Imp.Adapter.Types.Document{text: "hello", metadata: %{}}]

  """
  def content_from_openai(values) when is_list(values), do: Enum.map(values, &from_openai/1)
  def content_from_openai(value), do: from_openai(value)

  defp message_to_openai(%{role: role, content: content}) do
    %{role: to_string(role), content: content_to_openai(content)}
  end

  defp message_to_openai(message) do
    raise ArgumentError,
          "Imp.Adapter.Types.History messages must be maps with :role and :content; got: #{inspect(message)}"
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
    |> normalize_audio_format()
  end

  # DSPy `_normalize_audio_format` (dspy/adapters/types/audio.py): strip ONE
  # leading "x-" (Python `str.removeprefix`), so non-standard subtypes like
  # audio/x-wav send the provider format "wav". Interior "x-" runs survive
  # ("my-x-format" stays as-is; "x-my-format" -> "my-format").
  defp normalize_audio_format("x-" <> rest), do: rest
  defp normalize_audio_format(format), do: format

  defp mime_type(_kind, nil), do: nil
  defp mime_type(kind, format), do: "#{kind}/#{format}"

  defp read_file_attachment!(path) do
    case Elixir.File.read(path) do
      {:ok, data} ->
        data

      {:error, reason} ->
        raise ArgumentError,
              "could not read Imp file attachment #{inspect(path)}: #{:file.format_error(reason)}"
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
