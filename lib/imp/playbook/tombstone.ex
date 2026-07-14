defmodule Imp.Playbook.Tombstone do
  @moduledoc "Removal and merge provenance retained in a playbook's hash chain."

  alias Imp.Playbook.Entry

  @enforce_keys [:entry, :operation, :at_revision]
  defstruct [:entry, :operation, :at_revision, :replacement_id]

  @type operation :: :remove | :merge
  @type t :: %__MODULE__{
          entry: Entry.t(),
          operation: operation(),
          at_revision: pos_integer(),
          replacement_id: String.t() | nil
        }
end
