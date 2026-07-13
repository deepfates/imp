defmodule DSEx.Playbook.Operation.Revise do
  @moduledoc "Revises an entry while retaining its ID and linking to its prior hash."
  @enforce_keys [:id, :content]
  defstruct [
    :id,
    :content,
    :expected_revision,
    section: :preserve,
    status: :preserve,
    provenance: :preserve
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          expected_revision: pos_integer() | nil,
          section: String.t() | :preserve,
          status: DSEx.Playbook.Entry.status() | :preserve,
          provenance: DSEx.Playbook.Provenance.t() | :preserve | term()
        }
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(id, content, opts \\ []) do
    %__MODULE__{
      id: id,
      content: content,
      expected_revision: Keyword.get(opts, :expected_revision),
      section: Keyword.get(opts, :section, :preserve),
      status: Keyword.get(opts, :status, :preserve),
      provenance: Keyword.get(opts, :provenance, :preserve)
    }
  end
end
