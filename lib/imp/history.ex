defmodule Imp.History do
  @moduledoc """
  Immutable conversation history for signature-shaped Imp programs.

  A history is a sequence of prior task turns keyed by the same fields as the
  signature, not raw chat messages. For a signature like
  `"question, history -> answer"`, a turn can be
  `%{question: "Capital of France?", answer: "Paris"}`. Turns are normalized
  through `Imp.Example`, so a turn must be a field map or a list of field pairs.

  The Chat adapter renders each turn as prior user/assistant messages by
  splitting the fields according to the active signature, which keeps a history
  serializable and independent of any one provider's chat message schema.

      iex> history =
      ...>   Imp.History.new()
      ...>   |> Imp.History.append(%{question: "Capital of France?", answer: "Paris"})
      iex> Imp.History.messages(history)
      [%{answer: "Paris", question: "Capital of France?"}]

  """

  @type field_key :: atom() | String.t()
  @type turn :: %{optional(field_key()) => term()}
  @type t :: %__MODULE__{messages: [turn()]}

  defstruct messages: []

  @doc "Builds history from a list of signature-shaped field maps."
  def new(messages \\ [])

  def new(%__MODULE__{} = history), do: history

  def new(messages) when is_list(messages) do
    %__MODULE__{messages: Enum.map(messages, &normalize_turn!/1)}
  end

  def new(messages) do
    raise ArgumentError,
          "Imp.History.new/1 expects a list of field maps; got: #{inspect(messages)}"
  end

  @doc "Appends one signature-shaped history turn."
  def append(%__MODULE__{messages: messages} = history, turn) do
    %{history | messages: messages ++ [normalize_turn!(turn)]}
  end

  def append(history, turn) do
    raise ArgumentError,
          "Imp.History.append/2 expects an Imp.History and field map; got: #{inspect(history)} and #{inspect(turn)}"
  end

  @doc "Returns the signature-shaped field maps in insertion order."
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  One turn without the time each of its tool results came back
  (`returned_at`, recorded by `Imp.Predict.ReActV2`). That time is a fact of
  one run rather than of the program, so what is built from a trajectory for
  another model to read, such as an optimizer's reflection prompt, leaves it
  out and reads the same for the same trajectory in any run. Any other value
  is returned as it is.
  """
  @spec without_return_times(term()) :: term()
  def without_return_times(%{} = turn) when not is_struct(turn) do
    Enum.reduce([:tool_call_results, "tool_call_results"], turn, fn key, turn ->
      case Map.get(turn, key) do
        results when is_list(results) ->
          Map.put(turn, key, Enum.map(results, &without_return_time/1))

        _other ->
          turn
      end
    end)
  end

  def without_return_times(other), do: other

  defp without_return_time(%{} = result) when not is_struct(result),
    do: Map.drop(result, [:returned_at, "returned_at"])

  defp without_return_time(result), do: result

  @doc "Redacts secret-looking values while preserving history structure."
  def redact(%__MODULE__{messages: messages} = history, keys \\ Imp.Redaction.default_keys()) do
    %{history | messages: Imp.Redaction.redact(messages, keys)}
  end

  @doc "Dumps history to a JSON-safe map."
  def dump(%__MODULE__{messages: messages}) do
    %{
      "type" => "history",
      "messages" => Imp.Optimizer.Report.encode_term(messages)
    }
  end

  @doc """
  Loads a JSON-safe history map produced by `dump/1`.

  Existing atoms and typed values are preserved. Loading never creates atoms: a
  symbolic atom whose owning capability is not loaded becomes its exact name as
  a string, so earlier turns stay usable after a restart or a capability
  removal. Dumping the loaded history records that string representation.

  Malformed tags and map-key collisions introduced by this conversion are
  rejected, and a state without a list `"messages"` raises `ArgumentError`.
  """
  def load!(%{"type" => "history", "messages" => messages}) when is_list(messages) do
    messages
    |> Imp.Optimizer.Report.decode_term_compatible()
    |> new()
  end

  def load!(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Imp.Optimizer.Report.decode_term_compatible()
    |> new()
  end

  def load!(state) do
    raise ArgumentError,
          "Imp.History.load!/1 expects a history map with list \"messages\"; got: #{inspect(state)}"
  end

  defp normalize_turn!(turn) when is_map(turn) or is_list(turn) do
    turn
    |> Imp.Example.new()
    |> Imp.Example.to_map()
  end

  defp normalize_turn!(turn) do
    raise ArgumentError,
          "Imp.History messages must be field maps or field pair lists; got: #{inspect(turn)}"
  end
end
