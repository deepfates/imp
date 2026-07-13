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
    @moduledoc "Stream observer that records events and can attach a callback without altering them."

    defstruct events: [], on_event: nil

    def new(opts \\ []) do
      opts =
        DSEx.Options.validate!(
          opts,
          [on_event: [type: {:custom, __MODULE__, :validate_callback, []}, default: nil]],
          "DSEx.Streaming.Messages.StreamListener.new/1"
        )

      %__MODULE__{on_event: opts[:on_event]}
    end

    def record(%__MODULE__{events: events} = listener, event),
      do: %{listener | events: events ++ [event]}

    def attach(%__MODULE__{} = listener, enumerable) do
      unless Enumerable.impl_for(enumerable) do
        raise ArgumentError, "StreamListener.attach/2 expects an enumerable"
      end

      Stream.map(enumerable, fn event ->
        notify(listener, event)
        event
      end)
    end

    def validate_callback(nil), do: {:ok, nil}
    def validate_callback(callback) when is_function(callback, 1), do: {:ok, callback}

    def validate_callback(callback),
      do: {:error, "expected nil or an arity-1 function, got: #{inspect(callback)}"}

    defp notify(%__MODULE__{on_event: nil}, _event), do: :ok
    defp notify(%__MODULE__{on_event: callback}, event), do: callback.(event)
  end
end
