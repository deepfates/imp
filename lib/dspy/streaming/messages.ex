defmodule DSPy.Streaming.Messages do
  @moduledoc "Streaming message structs compatible with DSPy's public streaming vocabulary."

  defmodule StreamResponse do
    defstruct [:chunk, done: false, metadata: %{}]
  end

  defmodule StatusMessage do
    defstruct [:message, level: :info, metadata: %{}]
  end

  defmodule StatusMessageProvider do
    defstruct messages: []

    def push(%__MODULE__{messages: messages} = provider, message) do
      %{provider | messages: messages ++ [message]}
    end
  end

  defmodule StreamListener do
    defstruct events: []

    def record(%__MODULE__{events: events} = listener, event),
      do: %{listener | events: events ++ [event]}
  end
end
