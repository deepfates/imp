defmodule Dachshund.Core do
  @moduledoc "Core LM message/request/response structs mirroring Dachshund's public core vocabulary."

  defmodule Message do
    defstruct [:role, :content, metadata: %{}]
  end

  defmodule System do
    defstruct [:content, metadata: %{}]
  end

  defmodule User do
    defstruct [:content, metadata: %{}]
  end

  defmodule Assistant do
    defstruct [:content, tool_calls: [], metadata: %{}]
  end

  defmodule Developer do
    defstruct [:content, metadata: %{}]
  end

  defmodule ToolCall do
    defstruct [:id, :name, arguments: %{}]
  end

  defmodule ToolResult do
    defstruct [:id, :name, :result, is_error: false]
  end

  defmodule LMConfig do
    defstruct model: nil,
              temperature: nil,
              max_tokens: nil,
              response_format: nil,
              tools: [],
              extra: %{}
  end

  defmodule LMRequest do
    defstruct messages: [], config: %LMConfig{}, metadata: %{}
  end

  defmodule LMResponse do
    defstruct outputs: [], usage: %{}, cost: nil, raw: nil
  end
end
