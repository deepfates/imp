defmodule DSEx.Playbook.Provenance do
  @moduledoc """
  Bounded references to stable source identities and SHA-256 digests.

  Provenance deliberately cannot contain examples, traces, prompts, reasoning,
  or arbitrary metadata. Those artifacts belong outside the playbook domain.
  """

  defstruct source_ids: [], digests: []

  @type t :: %__MODULE__{source_ids: [String.t()], digests: [String.t()]}

  @doc "Builds a provenance reference set. Validation against policy occurs on admission."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unknown = Keyword.keys(opts) -- [:source_ids, :digests]
    if unknown != [], do: raise(ArgumentError, "unknown provenance fields: #{inspect(unknown)}")

    %__MODULE__{
      source_ids: Keyword.get(opts, :source_ids, []),
      digests: Keyword.get(opts, :digests, [])
    }
  end

  @doc false
  @spec merge([t()]) :: t()
  def merge(provenances) do
    %__MODULE__{
      source_ids: provenances |> Enum.flat_map(& &1.source_ids) |> Enum.uniq() |> Enum.sort(),
      digests: provenances |> Enum.flat_map(& &1.digests) |> Enum.uniq() |> Enum.sort()
    }
  end
end
