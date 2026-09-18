defmodule Imp.Adapter.Types do
  @moduledoc """
  Lightweight multimodal and tool-call value structs matching Imp's adapter vocabulary.

  The conversion helpers are deliberately permissive for plain text values and
  deliberately strict for Imp's typed structs. A free-form value can be rendered
  as text, but a `%File{}` without file data, identity, or filename is a malformed
  attachment and should fail at this boundary instead of becoming provider text.

  Typed values are inert: constructing or formatting them never reads the host
  filesystem or fetches the network. Use the explicit `from_path/1` and
  `from_url/2` factories when the caller intends those effects.
  """

  defmodule Image do
    @moduledoc """
    An inert image value backed by a remote reference or in-memory data.

    `from_path/1` and `from_url/2` perform explicit eager I/O and return a
    data-backed value. `from_url/2` accepts only HTTP(S); callers must validate
    untrusted hosts against their own allowlist because redirects and private
    network destinations are otherwise reachable.
    """

    defstruct [:url, :data, :mime_type, metadata: %{}]
    @type t :: %__MODULE__{}

    @doc "Reads a trusted local image immediately into an inert value."
    def from_path(path) when is_binary(path) do
      {bytes, mime_type} = Imp.Adapter.Types.ResourceLoader.read_path!(path, :image)
      %__MODULE__{data: Base.encode64(bytes), mime_type: mime_type}
    end

    @doc """
    Downloads an HTTP(S) image immediately into an inert value.

    Options include `:timeout` in milliseconds (default `30_000`). `:request`
    may inject an arity-2 transport for deterministic tests.
    """
    def from_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
      {bytes, mime_type} = Imp.Adapter.Types.ResourceLoader.fetch_url!(url, :image, opts)
      %__MODULE__{data: Base.encode64(bytes), mime_type: mime_type}
    end
  end

  defmodule Audio do
    @moduledoc """
    An inert audio value backed by in-memory base64 data.

    Use `from_path/1` or `from_url/2` for explicit eager I/O. Remote loading has
    the same SSRF responsibility described by `Imp.Adapter.Types.Image.from_url/2`.
    """

    defstruct [:url, :data, :mime_type, metadata: %{}]
    @type t :: %__MODULE__{}

    @doc "Reads a trusted local audio file immediately into an inert value."
    def from_path(path) when is_binary(path) do
      {bytes, mime_type} = Imp.Adapter.Types.ResourceLoader.read_path!(path, :audio)
      %__MODULE__{data: Base.encode64(bytes), mime_type: mime_type}
    end

    @doc """
    Downloads an HTTP(S) audio resource immediately into an inert value.

    Options include `:timeout` in milliseconds (default `30_000`). `:request`
    may inject an arity-2 transport for deterministic tests.
    """
    def from_url(url, opts \\ []) when is_binary(url) and is_list(opts) do
      {bytes, mime_type} = Imp.Adapter.Types.ResourceLoader.fetch_url!(url, :audio, opts)
      %__MODULE__{data: Base.encode64(bytes), mime_type: mime_type}
    end
  end

  defmodule File do
    @moduledoc """
    An inert file attachment or pre-uploaded provider file reference.

    `from_path/2` is the only local-path entry point and reads immediately.
    Keeping the bytes in the value makes later adapter formatting, persistence,
    retries, and service restarts independent of the original filesystem path.
    """

    defstruct [:path, :url, :data, :file_id, :filename, :mime_type, metadata: %{}]
    @type t :: %__MODULE__{}

    @doc "Reads a trusted local file immediately into a data-backed attachment."
    def from_path(path, opts \\ []) when is_binary(path) and is_list(opts) do
      {bytes, detected_mime_type} = Imp.Adapter.Types.ResourceLoader.read_path!(path, :file)

      from_bytes(bytes,
        filename: Keyword.get(opts, :filename, Path.basename(path)),
        mime_type: Keyword.get(opts, :mime_type, detected_mime_type)
      )
    end

    @doc "Creates an attachment from raw bytes without performing I/O."
    def from_bytes(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
      %__MODULE__{
        data: Base.encode64(bytes),
        filename: Keyword.get(opts, :filename),
        mime_type: Keyword.get(opts, :mime_type, "application/octet-stream")
      }
    end

    @doc "Creates an inert reference to a file already uploaded to a provider."
    def from_file_id(file_id, opts \\ []) when is_binary(file_id) and is_list(opts) do
      if String.trim(file_id) == "" do
        raise ArgumentError, "file_id must be a non-empty string"
      end

      %__MODULE__{
        file_id: file_id,
        filename: Keyword.get(opts, :filename),
        mime_type: Keyword.get(opts, :mime_type)
      }
    end
  end

  defmodule ResourceLoader do
    @moduledoc false

    @default_timeout 30_000

    def read_path!(path, kind) do
      unless Elixir.File.regular?(path) do
        raise ArgumentError, "file not found or not a regular file: #{inspect(path)}"
      end

      bytes =
        case Elixir.File.read(path) do
          {:ok, bytes} -> bytes
          {:error, reason} -> raise_read_error!(path, reason)
        end

      mime_type = Imp.Adapter.Types.mime_type_from_path(path)
      validate_mime_type!(mime_type, kind, path)
      {bytes, mime_type}
    end

    def fetch_url!(url, kind, opts) do
      validate_http_url!(url)
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      unless is_integer(timeout) and timeout > 0 do
        raise ArgumentError, "resource timeout must be a positive integer in milliseconds"
      end

      request = Keyword.get(opts, :request, &default_request/2)

      response =
        request.(url,
          receive_timeout: timeout,
          connect_options: [timeout: timeout],
          redirect: true,
          max_redirects: 5
        )

      {status, body, headers} = normalize_response!(response, url)

      unless status in 200..299 do
        raise ArgumentError, "resource request failed with HTTP #{status} for #{inspect(url)}"
      end

      unless is_binary(body) do
        raise ArgumentError, "resource response body must be binary for #{inspect(url)}"
      end

      mime_type = response_content_type(headers) || Imp.Adapter.Types.mime_type_from_path(url)
      validate_mime_type!(mime_type, kind, url)
      {body, mime_type}
    end

    defp default_request(url, opts), do: Req.get(url, opts)

    defp normalize_response!({:ok, %{status: status, body: body} = response}, _url)
         when is_integer(status),
         do: {status, body, Map.get(response, :headers, %{})}

    defp normalize_response!({:error, reason}, url) do
      raise ArgumentError, "resource request failed for #{inspect(url)}: #{inspect(reason)}"
    end

    defp normalize_response!(other, url) do
      raise ArgumentError,
            "resource request returned an invalid response for #{inspect(url)}: #{inspect(other)}"
    end

    defp response_content_type(headers) when is_map(headers) do
      headers
      |> Map.get("content-type", Map.get(headers, "Content-Type"))
      |> normalize_header_value()
    end

    defp response_content_type(headers) when is_list(headers) do
      headers
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(to_string(key)) == "content-type", do: value
      end)
      |> normalize_header_value()
    end

    defp response_content_type(_headers), do: nil
    defp normalize_header_value([value | _]), do: normalize_header_value(value)

    defp normalize_header_value(value) when is_binary(value),
      do: value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    defp normalize_header_value(_value), do: nil

    defp validate_http_url!(url) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          :ok

        _ ->
          raise ArgumentError, "resource URL must use HTTP(S) and include a host: #{inspect(url)}"
      end
    end

    defp validate_mime_type!(mime_type, :image, source) do
      unless String.starts_with?(mime_type, "image/") do
        raise ArgumentError,
              "unsupported image MIME type #{inspect(mime_type)} for #{inspect(source)}"
      end
    end

    defp validate_mime_type!(mime_type, :audio, source) do
      unless String.starts_with?(mime_type, "audio/") do
        raise ArgumentError,
              "unsupported audio MIME type #{inspect(mime_type)} for #{inspect(source)}"
      end
    end

    defp validate_mime_type!(_mime_type, :file, _source), do: :ok

    defp raise_read_error!(path, reason) do
      raise ArgumentError,
            "could not read resource #{inspect(path)}: #{:file.format_error(reason)}"
    end
  end

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

  defmodule Reasoning do
    @moduledoc "Provider-native or prompt-generated reasoning with one stable value shape."
    defstruct [:text, metadata: %{}]

    def new(%__MODULE__{} = reasoning), do: reasoning
    def new(text) when is_binary(text), do: %__MODULE__{text: text}

    def new(%{} = value) do
      case Map.fetch(value, :content) do
        {:ok, text} when is_binary(text) ->
          %__MODULE__{text: text}

        _ ->
          case Map.fetch(value, "content") do
            {:ok, text} when is_binary(text) -> %__MODULE__{text: text}
            _ -> raise ArgumentError, "Reasoning requires a binary content field"
          end
      end
    end

    def new(value),
      do:
        raise(ArgumentError, "Reasoning requires a string or content map, got: #{inspect(value)}")
  end

  defmodule History, do: defstruct(messages: [])
  defmodule Citation, do: defstruct([:text, :source, metadata: %{}])

  defmodule ToolCall do
    @moduledoc """
    Provider-native tool call value with stable id, name, and arguments.

    `from_map/1` accepts the OpenAI wire shape (`%{"function" => %{"name",
    "arguments"}}`) and a flat map. In a flat map the name may be spelled
    `name`, `recipient_name` or `tool`, and the arguments `arguments`, `args`
    or `parameters`, with atom or string keys. The spellings are here rather
    than at each call site: `tool`/`arguments` is what a model emits when it
    writes a tool call as JSON prose instead of calling natively, which is what
    `Imp.Predict.ReActV2` then has to execute.
    """
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
      name = call |> first_key([:name, :recipient_name, :tool]) |> normalize_name()

      arguments = first_key(call, [:arguments, :args, :parameters]) || %{}

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

    defp first_key(call, keys) do
      Enum.find_value(keys, fn key ->
        case Map.fetch(call, key) do
          {:ok, value} -> value
          :error -> Map.get(call, to_string(key))
        end
      end)
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
      ** (ArgumentError) Imp.Adapter.Types.File expects binary :url, :data, :file_id, or :filename; got: %Imp.Adapter.Types.File{path: nil, url: nil, data: nil, file_id: nil, filename: nil, mime_type: nil, metadata: %{}}

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

  def to_openai(%File{path: path}) when is_binary(path) do
    raise ArgumentError,
          "Imp.Adapter.Types.File does not read deferred paths; use Imp.Adapter.Types.File.from_path/2"
  end

  def to_openai(%File{} = value) do
    file =
      %{}
      |> maybe_put(:file_url, value.url)
      |> maybe_put(
        :file_data,
        if(is_binary(value.data),
          do: data_uri(value.mime_type || "application/octet-stream", value.data)
        )
      )
      |> maybe_put(:file_id, value.file_id)
      |> maybe_put(:filename, value.filename)

    if map_size(file) == 0 do
      invalid_type!(File, "binary :url, :data, :file_id, or :filename", value)
    else
      %{type: "file", file: file}
    end
  end

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

  def from_openai(%{"type" => "file", "file" => file} = block) when is_map(file),
    do: file_from_openai(file, block)

  def from_openai(%{type: "file", file: file} = block) when is_map(file),
    do: file_from_openai(file, block)

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

  @doc false
  def decode_data!(data, label) when is_binary(data) do
    encoded = strip_data_uri(data)

    case Base.decode64(encoded) do
      {:ok, bytes} ->
        bytes

      :error ->
        raise ArgumentError,
              "#{label} data must be base64 or a base64 data URI; got invalid encoded data"
    end
  end

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

  defp file_from_openai(file, block) do
    data = Map.get(file, "file_data", Map.get(file, :file_data))
    url = Map.get(file, "file_url", Map.get(file, :file_url))
    file_id = Map.get(file, "file_id", Map.get(file, :file_id))
    filename = Map.get(file, "filename", Map.get(file, :filename))

    if Enum.any?([data, url, file_id, filename], &is_binary/1) do
      {data, mime_type} =
        if is_binary(data) and String.starts_with?(data, "data:"),
          do: {strip_data_uri(data), data_uri_mime_type(data)},
          else: {if(is_binary(data), do: data), nil}

      %File{
        data: data,
        url: if(is_binary(url), do: url),
        file_id: if(is_binary(file_id), do: file_id),
        filename: if(is_binary(filename), do: filename),
        mime_type: mime_type
      }
    else
      invalid_openai_block!("file", block)
    end
  end

  defp maybe_put(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map

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

  @doc false
  def mime_type_from_path(path) do
    path = if String.contains?(path, "://"), do: URI.parse(path).path || "", else: path

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

defimpl String.Chars, for: Imp.Adapter.Types.Reasoning do
  def to_string(%{text: text}) when is_binary(text), do: text

  def to_string(reasoning) do
    raise ArgumentError,
          "cannot convert Reasoning without binary :text to string: #{inspect(reasoning)}"
  end
end

# DSPy's Reasoning pydantic serializer emits its formatted string, not the
# wrapper object. Keep reports/artifacts equally compact and avoid accidentally
# turning internal metadata into a new wire contract.
defimpl Jason.Encoder, for: Imp.Adapter.Types.Reasoning do
  def encode(%{text: text}, opts) when is_binary(text), do: Jason.Encode.string(text, opts)

  def encode(reasoning, _opts) do
    raise ArgumentError,
          "cannot JSON-encode Reasoning without binary :text: #{inspect(reasoning)}"
  end
end
