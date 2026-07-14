defmodule Imp.Playbook.Entry do
  @moduledoc """
  An immutable, normalized playbook entry with a stable identity and hash chain.
  """

  alias Imp.Playbook.{Canonical, Policy, Provenance}

  @statuses [:active, :inactive]

  @enforce_keys [
    :id,
    :content,
    :section,
    :status,
    :helpful,
    :harmful,
    :provenance,
    :revision,
    :hash
  ]
  defstruct [
    :id,
    :content,
    :section,
    :status,
    :hash,
    helpful: 0,
    harmful: 0,
    provenance: %Provenance{},
    revision: 1,
    parent_hash: nil
  ]

  @type status :: :active | :inactive

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          section: String.t(),
          status: status(),
          helpful: non_neg_integer(),
          harmful: non_neg_integer(),
          provenance: Provenance.t(),
          revision: pos_integer(),
          parent_hash: String.t() | nil,
          hash: String.t()
        }

  @doc "Normalizes content for exact deduplication and canonical storage."
  @spec normalize(String.t()) :: String.t()
  def normalize(content) when is_binary(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.normalize(:nfc)
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  @doc "Builds an entry, raising when its content violates the policy."
  @spec new(String.t(), keyword()) :: t()
  def new(content, opts \\ []) do
    policy = Keyword.get(opts, :policy, Policy.new())
    normalized = normalize_content(content)

    with :ok <- Policy.validate_content(normalized, policy),
         {:ok, fields} <- validate_fields(opts, policy) do
      build(normalized, Keyword.merge(opts, fields))
    else
      {:error, reason} -> raise ArgumentError, "invalid playbook entry: #{inspect(reason)}"
    end
  end

  @doc false
  @spec build(String.t(), keyword()) :: t()
  def build(normalized, opts) do
    revision = Keyword.get(opts, :revision, 1)
    parent_hash = Keyword.get(opts, :parent_hash)
    id = Keyword.get(opts, :id, "ent_" <> String.slice(Canonical.hash(normalized), 0, 24))
    section = Keyword.get(opts, :section, "general")
    status = Keyword.get(opts, :status, :active)
    helpful = Keyword.get(opts, :helpful, 0)
    harmful = Keyword.get(opts, :harmful, 0)
    provenance = Keyword.get(opts, :provenance, %Provenance{})

    unless valid_id?(id), do: raise(ArgumentError, "invalid playbook entry id: #{inspect(id)}")

    unless is_integer(revision) and revision > 0,
      do: raise(ArgumentError, "invalid entry revision")

    payload = %{
      "content" => normalized,
      "harmful" => harmful,
      "helpful" => helpful,
      "id" => id,
      "parent_hash" => parent_hash,
      "provenance" => provenance_payload(provenance),
      "revision" => revision,
      "section" => section,
      "status" => Atom.to_string(status)
    }

    %__MODULE__{
      id: id,
      content: normalized,
      section: section,
      status: status,
      helpful: helpful,
      harmful: harmful,
      provenance: provenance,
      revision: revision,
      parent_hash: parent_hash,
      hash: Canonical.hash(payload)
    }
  end

  @doc false
  def valid_id?(id) do
    is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]*\z/, id)
  end

  @doc false
  def statuses, do: @statuses

  @doc false
  def provenance_payload(%Provenance{} = provenance) do
    %{"digests" => provenance.digests, "source_ids" => provenance.source_ids}
  end

  @doc false
  def validate_fields(opts, policy) do
    section = opts |> Keyword.get(:section, "general") |> normalize_section()
    status = Keyword.get(opts, :status, :active)
    helpful = Keyword.get(opts, :helpful, 0)
    harmful = Keyword.get(opts, :harmful, 0)
    provenance = Keyword.get(opts, :provenance, %Provenance{})

    with :ok <- Policy.validate_section(section, policy),
         :ok <- validate_status(status),
         :ok <- Policy.validate_counter(helpful, policy),
         :ok <- Policy.validate_counter(harmful, policy),
         :ok <- validate_provenance(provenance, policy) do
      provenance = %Provenance{
        source_ids: Enum.sort(provenance.source_ids),
        digests: Enum.sort(provenance.digests)
      }

      {:ok,
       [
         section: section,
         status: status,
         helpful: helpful,
         harmful: harmful,
         provenance: provenance
       ]}
    end
  end

  @doc false
  def validate_provenance(%Provenance{} = provenance, policy) do
    cond do
      not is_list(provenance.source_ids) or not is_list(provenance.digests) ->
        {:error, :invalid_provenance}

      length(provenance.source_ids) + length(provenance.digests) >
          policy.max_provenance_items ->
        {:error,
         {:too_many_provenance_items, length(provenance.source_ids) + length(provenance.digests)}}

      not unique_strings?(provenance.source_ids) or not unique_strings?(provenance.digests) ->
        {:error, :duplicate_or_invalid_provenance}

      invalid_id = Enum.find(provenance.source_ids, &(not valid_source_id?(&1, policy))) ->
        {:error, {:invalid_source_id, invalid_id}}

      invalid_digest = Enum.find(provenance.digests, &(not valid_digest?(&1))) ->
        {:error, {:invalid_digest, invalid_digest}}

      true ->
        :ok
    end
  end

  def validate_provenance(_provenance, _policy), do: {:error, :invalid_provenance}

  @doc false
  @spec semantic_bytes(t()) :: non_neg_integer()
  def semantic_bytes(%__MODULE__{} = entry) do
    byte_size(entry.content) + byte_size(entry.section) +
      Enum.reduce(entry.provenance.source_ids, 0, &(byte_size(&1) + &2)) +
      Enum.reduce(entry.provenance.digests, 0, &(byte_size(&1) + &2))
  end

  defp validate_status(status) when status in @statuses, do: :ok
  defp validate_status(status), do: {:error, {:invalid_status, status}}

  defp normalize_section(section) when is_binary(section), do: normalize(section)
  defp normalize_section(section), do: section

  defp unique_strings?(values),
    do: is_list(values) and Enum.all?(values, &is_binary/1) and Enum.uniq(values) == values

  defp valid_source_id?(id, policy) do
    byte_size(id) in 1..policy.max_source_id_bytes and String.valid?(id) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]*\z/, id) and
      (not policy.reject_secrets or Imp.Redaction.redact(id) == id)
  end

  defp valid_digest?(digest), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp normalize_content(content) when is_binary(content), do: normalize(content)
  defp normalize_content(content), do: content
end
