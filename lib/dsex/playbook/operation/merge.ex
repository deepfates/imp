defmodule DSEx.Playbook.Operation.Merge do
  @moduledoc "Replaces two or more entries and tombstones every source entry."
  @enforce_keys [:ids, :content]
  defstruct [
    :ids,
    :content,
    :id,
    section: "general",
    status: :active,
    provenance: nil,
    expected_revisions: %{}
  ]

  @type t :: %__MODULE__{
          ids: [String.t()],
          content: String.t(),
          id: String.t() | nil,
          section: String.t(),
          status: DSEx.Playbook.Entry.status(),
          provenance: DSEx.Playbook.Provenance.t() | term(),
          expected_revisions: %{optional(String.t()) => pos_integer()}
        }

  @spec new([String.t()], String.t(), keyword()) :: t()
  def new(ids, content, opts \\ []) do
    %__MODULE__{
      ids: ids,
      content: content,
      id: Keyword.get(opts, :id),
      section: Keyword.get(opts, :section, "general"),
      status: Keyword.get(opts, :status, :active),
      provenance: Keyword.get(opts, :provenance),
      expected_revisions: Keyword.get(opts, :expected_revisions, %{})
    }
  end
end
