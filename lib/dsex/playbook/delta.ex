defmodule DSEx.Playbook.Delta do
  @moduledoc """
  An ordered, atomic set of playbook operations with optional optimistic guards.
  """

  alias DSEx.Playbook.Operation.{Add, Merge, Remove, Revise, UpdateCounters}

  @enforce_keys [:operations]
  defstruct [:operations, :expected_revision, :parent_hash]

  @type operation :: Add.t() | Revise.t() | Merge.t() | Remove.t() | UpdateCounters.t()
  @type t :: %__MODULE__{
          operations: [operation()],
          expected_revision: non_neg_integer() | nil,
          parent_hash: String.t() | nil
        }

  @spec new([operation()], keyword()) :: t()
  def new(operations, opts \\ []) do
    %__MODULE__{
      operations: operations,
      expected_revision: Keyword.get(opts, :expected_revision),
      parent_hash: Keyword.get(opts, :parent_hash)
    }
  end
end
