defmodule Imp.History do
  @moduledoc """
  Immutable conversation history for signature-shaped Imp programs.

  `Imp.History` mirrors the DSPy `History` primitive philosophically: history is
  not a bag of raw chat messages, but a sequence of prior task turns keyed by the
  same fields as the signature. For a signature like `"question, history ->
  answer"`, a turn can be `%{question: "Capital of France?", answer: "Paris"}`.

  The Chat adapter renders each turn as prior user/assistant messages by
  splitting fields according to the active signature. This keeps history
  optimizer-friendly, serializable, and independent from any one provider's chat
  message schema.

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

  @doc "Redacts secret-looking values while preserving history structure."
  def redact(%__MODULE__{messages: messages} = history, keys \\ Imp.Redaction.default_keys()) do
    %{history | messages: Imp.Redaction.redact(messages, keys)}
  end

  @doc "Dumps history to a JSON-safe map."
  def dump(%__MODULE__{messages: messages}) do
    %{
      "type" => "history",
      "messages" => Imp.Optimizer.Report.json_safe(messages)
    }
  end

  @doc "Loads a JSON-safe history map produced by `dump/1`."
  def load(%{"type" => "history", "messages" => messages}) when is_list(messages) do
    messages
    |> Imp.Optimizer.Report.restore_json_safe()
    |> new()
  end

  def load(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Imp.Optimizer.Report.restore_json_safe()
    |> new()
  end

  def load(state) do
    raise ArgumentError,
          "Imp.History.load/1 expects a history map with list \"messages\"; got: #{inspect(state)}"
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
