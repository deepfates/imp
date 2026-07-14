defmodule Imp.Playbook.Operation.Add do
  @moduledoc "Adds one normalized entry."
  @enforce_keys [:content]
  defstruct [
    :content,
    :id,
    section: "general",
    status: :active,
    helpful: 0,
    harmful: 0,
    provenance: nil
  ]

  @type t :: %__MODULE__{
          content: String.t(),
          id: String.t() | nil,
          section: String.t(),
          status: Imp.Playbook.Entry.status(),
          helpful: non_neg_integer(),
          harmful: non_neg_integer(),
          provenance: Imp.Playbook.Provenance.t() | term()
        }
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) do
    %__MODULE__{
      content: content,
      id: Keyword.get(opts, :id),
      section: Keyword.get(opts, :section, "general"),
      status: Keyword.get(opts, :status, :active),
      helpful: Keyword.get(opts, :helpful, 0),
      harmful: Keyword.get(opts, :harmful, 0),
      provenance: Keyword.get(opts, :provenance)
    }
  end
end
