defmodule DSEx.Streaming.Messages do
  @moduledoc """
  Streaming message structs for DSEx's public streaming vocabulary.

  These structs are ordinary data returned by `DSEx.Streaming` and provider
  clients. They are intentionally small so callers can pattern match on stream
  chunks, completion markers, status messages, and listener state without
  depending on provider-specific event shapes.
  """

  defmodule StreamResponse do
    @moduledoc """
    One normalized stream event.

    `:chunk` holds the provider text, parsed partial value, or error tuple.
    `:done` marks terminal events. `:metadata` carries redacted provider or
    runtime details.
    """

    defstruct [:chunk, done: false, metadata: %{}]
  end

  defmodule StatusMessage do
    @moduledoc "Status event emitted by long-running streaming workflows."

    defstruct [:message, level: :info, metadata: %{}]
  end

  defmodule StatusMessageProvider do
    @moduledoc "In-memory status message accumulator for tests and local tools."

    defstruct messages: []

    def push(%__MODULE__{messages: messages} = provider, message) do
      %{provider | messages: messages ++ [message]}
    end
  end

  defmodule StreamListener do
    @moduledoc "In-memory stream event listener for tests and local tools."

    defstruct events: []

    def record(%__MODULE__{events: events} = listener, event),
      do: %{listener | events: events ++ [event]}
  end
end
