defmodule DSEx.Training.FastSlow.Event do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

  @enforce_keys [:sequence, :kind, :cycle]
  defstruct [:sequence, :kind, :cycle, :operation_id, :at, data: %{}]

  @type t :: %__MODULE__{
          sequence: non_neg_integer(),
          kind: String.t(),
          cycle: non_neg_integer(),
          operation_id: String.t() | nil,
          at: String.t() | nil,
          data: Config.json_value()
        }

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs
    event = struct!(__MODULE__, attrs)

    unless is_integer(event.sequence) and event.sequence >= 0,
      do: raise(ArgumentError, "event sequence must be a non-negative integer")

    unless is_integer(event.cycle) and event.cycle >= 0,
      do: raise(ArgumentError, "event cycle must be a non-negative integer")

    unless is_binary(event.kind) and event.kind != "",
      do: raise(ArgumentError, "event kind must be a non-empty string")

    if not is_nil(event.operation_id) and not valid_id?(event.operation_id),
      do: raise(ArgumentError, "event operation_id must be a SHA-256 identifier")

    if not is_nil(event.at) and not is_binary(event.at),
      do: raise(ArgumentError, "event at must be a string or nil")

    %{event | data: Config.json_safe!(event.data, [:event, :data])}
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id)
end

defmodule DSEx.Training.FastSlow.OperationIntent do
  @moduledoc false

  alias DSEx.Training.FastSlow.Config

  @states [:unreconciled, :confirmed, :retryable, :failed]
  @enforce_keys [:id, :kind, :cycle, :payload_digest, :payload]
  defstruct @enforce_keys ++ [reconciliation: :unreconciled, attempts: 0, result: nil]

  @type reconciliation :: :unreconciled | :confirmed | :retryable | :failed
  @type t :: %__MODULE__{
          id: String.t(),
          kind: String.t(),
          cycle: non_neg_integer(),
          payload_digest: String.t(),
          payload: Config.json_value(),
          reconciliation: reconciliation(),
          attempts: non_neg_integer(),
          result: Config.json_value() | nil
        }

  @spec new!(String.t(), non_neg_integer(), term()) :: t()
  def new!(kind, cycle, payload)
      when is_binary(kind) and kind != "" and is_integer(cycle) and cycle >= 0 do
    payload = Config.json_safe!(payload, [:operation_intent, :payload])
    payload_digest = Config.digest(payload)
    id = Config.digest(%{"cycle" => cycle, "kind" => kind, "payload_digest" => payload_digest})

    %__MODULE__{
      id: id,
      kind: kind,
      cycle: cycle,
      payload_digest: payload_digest,
      payload: payload
    }
  end

  def new!(_kind, _cycle, _payload),
    do: raise(ArgumentError, "operation intent kind and cycle are invalid")

  @spec reconcile(t(), reconciliation(), term()) :: t()
  def reconcile(%__MODULE__{} = intent, state, result \\ nil) when state in @states do
    unless valid_transition?(intent.reconciliation, state) do
      raise ArgumentError,
            "invalid operation reconciliation transition #{intent.reconciliation} -> #{state}"
    end

    result =
      if is_nil(result), do: nil, else: Config.json_safe!(result, [:operation_intent, :result])

    %{
      intent
      | reconciliation: state,
        attempts: intent.attempts + if(state == :retryable, do: 1, else: 0),
        result: result
    }
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = intent) do
    expected = new!(intent.kind, intent.cycle, intent.payload)

    unless intent.id == expected.id and intent.payload_digest == expected.payload_digest do
      raise ArgumentError, "operation intent identity or payload digest is invalid"
    end

    unless intent.reconciliation in @states and is_integer(intent.attempts) and
             intent.attempts >= 0 do
      raise ArgumentError, "operation intent reconciliation is invalid"
    end

    intent
  end

  defp valid_transition?(:unreconciled, state), do: state in @states
  defp valid_transition?(:retryable, state), do: state in [:retryable, :confirmed, :failed]
  defp valid_transition?(state, state), do: true
  defp valid_transition?(_from, _to), do: false
end
