defmodule Imp.Core do
  @moduledoc """
  Provider-neutral LM messages and request/response values.

  `Imp.LM.generate/3` preserves its established raw-output return contract, but
  every call now crosses this typed boundary internally. Consumers that need
  request/response metadata directly can call `Imp.LM.request/2`.
  """

  defmodule Message do
    @moduledoc "Generic provider-neutral message with role, content, and metadata."

    defstruct [:role, :content, metadata: %{}]
    @type t :: %__MODULE__{role: atom() | String.t(), content: term(), metadata: map()}
  end

  defmodule System do
    @moduledoc "System message content for provider-neutral LM requests."

    defstruct [:content, metadata: %{}]
    @type t :: %__MODULE__{content: term(), metadata: map()}
  end

  defmodule User do
    @moduledoc "User message content for provider-neutral LM requests."

    defstruct [:content, metadata: %{}]
    @type t :: %__MODULE__{content: term(), metadata: map()}
  end

  defmodule Assistant do
    @moduledoc "Assistant message content plus any normalized tool calls."

    defstruct [:content, tool_calls: [], metadata: %{}]
    @type t :: %__MODULE__{content: term(), tool_calls: list(), metadata: map()}
  end

  defmodule Developer do
    @moduledoc "Developer instruction message for providers that support that role."

    defstruct [:content, metadata: %{}]
    @type t :: %__MODULE__{content: term(), metadata: map()}
  end

  defmodule ToolCall do
    @moduledoc "Provider-neutral tool-call request emitted by an assistant message."

    defstruct [:id, :name, arguments: %{}]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: atom() | String.t() | nil,
            arguments: map()
          }
  end

  defmodule ToolResult do
    @moduledoc "Provider-neutral tool result that can be sent back to an LM."

    defstruct [:id, :name, :result, is_error: false]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: atom() | String.t() | nil,
            result: term(),
            is_error: boolean()
          }
  end

  defmodule LMConfig do
    @moduledoc "Provider-neutral LM generation configuration."

    defstruct model: nil,
              temperature: nil,
              max_tokens: nil,
              response_format: nil,
              tools: [],
              extra: %{},
              options: []

    @type t :: %__MODULE__{
            model: term(),
            temperature: number() | nil,
            max_tokens: non_neg_integer() | nil,
            response_format: term(),
            tools: list(),
            extra: map(),
            options: keyword()
          }
  end

  defmodule LMRequest do
    @moduledoc "Provider-neutral LM request: messages, generation config, and metadata."

    defstruct messages: [], config: %LMConfig{}, metadata: %{}
    @type t :: %__MODULE__{messages: list(), config: LMConfig.t(), metadata: map()}
  end

  defmodule LMResponse do
    @moduledoc """
    Provider-neutral LM response: normalized outputs, usage, cost, and raw data.

    `cost` is the provider's reported total for this call in USD as a
    non-negative float, or `nil` when the provider reported nothing Imp can
    read as a number. Providers report that total in several shapes — a bare
    number, a string, a `Decimal`, or a cost breakdown map carrying a `total`
    — and Imp reads the number out of all of them here, so a host reading a
    call's money never has to learn a provider library's private shape.

    `billing` is the provider's cost breakdown map, untouched, when the
    provider reported one, and `nil` otherwise. It is the detail behind `cost`
    (line items, input and output splits); its shape belongs to the provider,
    so it is evidence to inspect rather than a contract to depend on.
    """

    defstruct outputs: [], usage: %{}, cost: nil, billing: nil, metadata: %{}, raw: nil

    @type t :: %__MODULE__{
            outputs: list(),
            usage: map(),
            cost: number() | nil,
            billing: map() | nil,
            metadata: map(),
            raw: term()
          }
  end

  @doc false
  def request(messages, opts, lm) when is_list(messages) and is_list(opts) do
    %LMRequest{
      messages: Enum.map(messages, &normalize_message/1),
      config: config(opts, lm),
      metadata: %{}
    }
  end

  @doc false
  def request_parts(%LMRequest{messages: messages, config: %LMConfig{} = config}) do
    {Enum.map(messages, &message_map/1), config.options}
  end

  @doc false
  def response(raw) do
    with {:ok, outputs, metadata} <- split_outputs(raw) do
      usage = response_usage(metadata)

      reported = reported_cost(metadata, usage)

      {:ok,
       %LMResponse{
         outputs: outputs,
         usage: usage,
         cost: cost_number(reported),
         billing: billing_breakdown(reported),
         metadata: metadata,
         raw: raw
       }}
    end
  end

  @doc false
  def legacy_response(%LMResponse{raw: raw}) when not is_nil(raw), do: raw
  def legacy_response(%LMResponse{outputs: [output]}), do: output
  def legacy_response(%LMResponse{outputs: outputs}), do: outputs

  defp config(opts, lm) do
    model = Keyword.get(opts, :model, lm_model(lm))

    %LMConfig{
      model: model,
      temperature: Keyword.get(opts, :temperature),
      max_tokens: Keyword.get(opts, :max_tokens, Keyword.get(opts, :max_completion_tokens)),
      response_format: Keyword.get(opts, :response_format),
      tools: Keyword.get(opts, :tools, []),
      extra:
        opts
        |> Keyword.drop([
          :model,
          :temperature,
          :max_tokens,
          :max_completion_tokens,
          :response_format,
          :tools
        ])
        |> Map.new(),
      options: opts
    }
  end

  defp lm_model(%{model: model}), do: model
  defp lm_model(_lm), do: nil

  defp normalize_message(%Message{} = message), do: message
  defp normalize_message(%System{} = message), do: message
  defp normalize_message(%User{} = message), do: message
  defp normalize_message(%Assistant{} = message), do: message
  defp normalize_message(%Developer{} = message), do: message

  defp normalize_message(message) when is_map(message) do
    role = Map.get(message, :role, Map.get(message, "role"))
    content = Map.get(message, :content, Map.get(message, "content"))
    tool_calls = Map.get(message, :tool_calls, Map.get(message, "tool_calls", []))
    metadata = Map.drop(message, [:role, "role", :content, "content", :tool_calls, "tool_calls"])

    case to_string(role) do
      "system" ->
        %System{content: content, metadata: metadata}

      "user" ->
        %User{content: content, metadata: metadata}

      "assistant" ->
        %Assistant{content: content, tool_calls: tool_calls, metadata: metadata}

      "developer" ->
        %Developer{content: content, metadata: metadata}

      _other ->
        %Message{
          role: role,
          content: content,
          metadata: Map.put(metadata, :tool_calls, tool_calls)
        }
    end
  end

  defp normalize_message(message) do
    raise ArgumentError,
          "LM request messages must be provider-neutral message structs or maps; got: #{inspect(message)}"
  end

  defp message_map(%System{content: content, metadata: metadata}),
    do: merge_message(metadata, %{role: :system, content: content})

  defp message_map(%User{content: content, metadata: metadata}),
    do: merge_message(metadata, %{role: :user, content: content})

  defp message_map(%Developer{content: content, metadata: metadata}),
    do: merge_message(metadata, %{role: :developer, content: content})

  defp message_map(%Assistant{content: content, tool_calls: tool_calls, metadata: metadata}),
    do: merge_message(metadata, %{role: :assistant, content: content, tool_calls: tool_calls})

  defp message_map(%Message{role: role, content: content, metadata: metadata}) do
    {tool_calls, metadata} = Map.pop(metadata, :tool_calls, [])
    merge_message(metadata, %{role: role, content: content, tool_calls: tool_calls})
  end

  defp merge_message(metadata, fields), do: Map.merge(metadata, fields)

  defp split_outputs(raw) when is_list(raw) do
    raw
    |> Enum.reduce_while({[], []}, fn output, {outputs, metadata} ->
      case Imp.LM.Result.split(output) do
        {:ok, output, output_metadata} ->
          {:cont, {[output | outputs], [output_metadata | metadata]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      {outputs, metadata} ->
        {:ok, Enum.reverse(outputs), metadata |> Enum.reverse() |> merge_response_metadata()}
    end
  end

  defp split_outputs(raw) do
    with {:ok, output, metadata} <- Imp.LM.Result.split(raw), do: {:ok, [output], metadata}
  end

  defp merge_response_metadata(metadata) do
    metadata
    |> Enum.reject(&(&1 == %{}))
    |> case do
      [] -> %{}
      [metadata] -> metadata
      metadata -> %{completions: metadata}
    end
  end

  defp response_usage(metadata) do
    metadata
    |> map_value(:req_llm, %{})
    |> map_value(:usage, %{})
    |> case do
      usage when is_map(usage) -> usage
      _other -> %{}
    end
  end

  defp reported_cost(metadata, usage) do
    map_value(usage, :cost, map_value(metadata, :cost, nil))
  end

  # A cost breakdown is the provider's own map. Anything else a provider
  # reports as a cost is a value, not a breakdown, so there is nothing to keep.
  defp billing_breakdown(%_struct{}), do: nil
  defp billing_breakdown(reported) when is_map(reported), do: reported
  defp billing_breakdown(_reported), do: nil

  # The reported total as a non-negative float, or nil when it cannot be read
  # as one. A negative total is not money Imp can account for, so it reads as
  # nothing rather than as a credit.
  defp cost_number(value) when is_number(value) and value >= 0, do: value * 1.0

  defp cost_number(value) when is_struct(value, Decimal) do
    cost_number(Decimal.to_float(value))
  rescue
    _error -> nil
  end

  defp cost_number(value) when is_struct(value), do: nil

  defp cost_number(value) when is_map(value),
    do: value |> map_value(:total, nil) |> cost_number()

  defp cost_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> cost_number(number)
      _other -> nil
    end
  end

  defp cost_number(_value), do: nil

  defp map_value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp map_value(_value, _key, default), do: default
end
