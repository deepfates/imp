defmodule Imp.Playbook.Operation.Remove do
  @moduledoc "Removes an entry while retaining a provenance tombstone."
  @enforce_keys [:id]
  defstruct [:id, :expected_revision]

  @type t :: %__MODULE__{id: String.t(), expected_revision: pos_integer() | nil}
  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []),
    do: %__MODULE__{id: id, expected_revision: Keyword.get(opts, :expected_revision)}
end
