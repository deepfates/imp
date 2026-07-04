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
end
