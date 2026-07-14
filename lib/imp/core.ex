defmodule Imp.Core do
  @moduledoc "Core LM message/request/response structs mirroring Imp's public core vocabulary."

  defmodule Message do
    @moduledoc "Generic provider-neutral message with role, content, and metadata."

    defstruct [:role, :content, metadata: %{}]
  end

  defmodule System do
    @moduledoc "System message content for provider-neutral LM requests."

    defstruct [:content, metadata: %{}]
  end

  defmodule User do
    @moduledoc "User message content for provider-neutral LM requests."

    defstruct [:content, metadata: %{}]
  end

  defmodule Assistant do
    @moduledoc "Assistant message content plus any normalized tool calls."

    defstruct [:content, tool_calls: [], metadata: %{}]
  end

  defmodule Developer do
    @moduledoc "Developer instruction message for providers that support that role."

    defstruct [:content, metadata: %{}]
  end

  defmodule ToolCall do
    @moduledoc "Provider-neutral tool-call request emitted by an assistant message."

    defstruct [:id, :name, arguments: %{}]
  end

  defmodule ToolResult do
    @moduledoc "Provider-neutral tool result that can be sent back to an LM."

    defstruct [:id, :name, :result, is_error: false]
  end

  defmodule LMConfig do
    @moduledoc "Provider-neutral LM generation configuration."

    defstruct model: nil,
              temperature: nil,
              max_tokens: nil,
              response_format: nil,
              tools: [],
              extra: %{}
  end

  defmodule LMRequest do
    @moduledoc "Provider-neutral LM request: messages, generation config, and metadata."

    defstruct messages: [], config: %LMConfig{}, metadata: %{}
  end

  defmodule LMResponse do
    @moduledoc "Provider-neutral LM response: normalized outputs, usage, cost, and raw data."

    defstruct outputs: [], usage: %{}, cost: nil, raw: nil
  end
end
