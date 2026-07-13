defmodule DSEx.Playbook.Operation.UpdateCounters do
  @moduledoc "Atomically increments an entry's helpful and harmful counters."

  @enforce_keys [:id]
  defstruct [:id, :expected_revision, helpful: 0, harmful: 0]

  @type t :: %__MODULE__{
          id: String.t(),
          helpful: non_neg_integer(),
          harmful: non_neg_integer(),
          expected_revision: pos_integer() | nil
        }

  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []) do
    %__MODULE__{
      id: id,
      helpful: Keyword.get(opts, :helpful, 0),
      harmful: Keyword.get(opts, :harmful, 0),
      expected_revision: Keyword.get(opts, :expected_revision)
    }
  end
end
