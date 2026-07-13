defmodule DSEx.Playbook do
  @moduledoc """
  Provider-independent, immutable instructions with transactional evolution.

  A delta is evaluated against a private candidate and committed only if every
  operation and final policy bound succeeds. Content equality is exact after
  `DSEx.Playbook.Entry.normalize/1`; no semantic or fuzzy deduplication occurs.
  """

  alias DSEx.Playbook.{Canonical, Delta, Entry, Policy, Provenance, Tombstone}
  alias DSEx.Playbook.Operation.{Add, Merge, Remove, Revise, UpdateCounters}

  @enforce_keys [:id, :revision, :entries, :tombstones, :policy, :hash]
  defstruct [:id, :parent_hash, :hash, revision: 0, entries: [], tombstones: [], policy: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          revision: non_neg_integer(),
          parent_hash: String.t() | nil,
          entries: [Entry.t()],
          tombstones: [Tombstone.t()],
          policy: Policy.t(),
          hash: String.t()
        }
  @type error :: {:error, term()}

  @doc "Creates an empty playbook with a stable ID and canonical root hash."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    policy = opts |> Keyword.get(:policy, Policy.new()) |> normalize_policy()
    id = Keyword.get(opts, :id, default_id(policy))

    unless Entry.valid_id?(id), do: raise(ArgumentError, "invalid playbook id: #{inspect(id)}")

    rehash(%__MODULE__{
      id: id,
      revision: 0,
      entries: [],
      tombstones: [],
      policy: policy,
      hash: ""
    })
  end

  @doc "Applies all operations or returns an error without a partially updated playbook."
  @spec apply_delta(t(), Delta.t() | [Delta.operation()]) :: {:ok, t()} | error()
  def apply_delta(%__MODULE__{} = playbook, operations) when is_list(operations),
    do: apply_delta(playbook, Delta.new(operations))

  def apply_delta(%__MODULE__{} = playbook, %Delta{} = delta) do
    with :ok <- validate_delta(playbook, delta),
         {:ok, candidate} <- apply_operations(playbook, delta.operations),
         :ok <- validate_final(candidate) do
      committed =
        candidate
        |> Map.put(:revision, playbook.revision + 1)
        |> Map.put(:parent_hash, playbook.hash)
        |> rehash()

      {:ok, committed}
    end
  end

  def apply_delta(_playbook, _delta), do: {:error, :invalid_playbook_or_delta}

  @doc "Returns a deterministic data-only representation."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = playbook) do
    %{
      "entries" => Enum.map(playbook.entries, &dump_entry/1),
      "hash" => playbook.hash,
      "id" => playbook.id,
      "parent_hash" => playbook.parent_hash,
      "policy" => dump_policy(playbook.policy),
      "revision" => playbook.revision,
      "schema_version" => 2,
      "tombstones" => Enum.map(playbook.tombstones, &dump_tombstone/1)
    }
  end

  @doc "Serializes a playbook as canonical JSON with lexicographically sorted keys."
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{} = playbook), do: playbook |> dump() |> Canonical.encode()

  @doc "Renders active entries in stable playbook order."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{entries: entries}) do
    active = Enum.filter(entries, &(&1.status == :active))

    active
    |> Enum.map(& &1.section)
    |> Enum.uniq()
    |> Enum.map_join("\n\n", fn section ->
      rendered_entries =
        active
        |> Enum.filter(&(&1.section == section))
        |> Enum.map_join("\n\n", fn entry ->
          "## #{entry.id} (revision #{entry.revision})\n\n#{entry.content}"
        end)

      "# #{section}\n\n#{rendered_entries}"
    end)
  end

  @doc "Returns an entry by ID, regardless of its active status."
  @spec fetch(t(), String.t()) :: {:ok, Entry.t()} | :error
  def fetch(%__MODULE__{entries: entries}, id),
    do: Enum.find_value(entries, :error, &if(&1.id == id, do: {:ok, &1}))

  defp validate_delta(playbook, %Delta{} = delta) do
    cond do
      not is_list(delta.operations) ->
        {:error, :operations_must_be_a_list}

      delta.operations == [] ->
        {:error, :empty_delta}

      length(delta.operations) > playbook.policy.max_operations ->
        {:error, {:too_many_operations, length(delta.operations)}}

      not is_nil(delta.expected_revision) and delta.expected_revision != playbook.revision ->
        {:error, {:stale_playbook_revision, delta.expected_revision, playbook.revision}}

      not is_nil(delta.parent_hash) and delta.parent_hash != playbook.hash ->
        {:error, {:parent_hash_mismatch, delta.parent_hash, playbook.hash}}

      true ->
        :ok
    end
  end

  defp apply_operations(playbook, operations) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, playbook}, fn {operation, index}, {:ok, candidate} ->
      case apply_operation(candidate, operation, index) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {:operation_failed, index, reason}}}
      end
    end)
  end

  defp apply_operation(playbook, %Add{} = operation, index) do
    with {:ok, content} <- validate_content(operation.content, playbook.policy),
         {:ok, fields} <- add_fields(operation, playbook.policy),
         :ok <- ensure_unique_content(playbook, content, []),
         {:ok, id} <- operation_id(playbook, operation.id, content, index),
         :ok <- ensure_unused_id(playbook, id) do
      entry = Entry.build(content, Keyword.put(fields, :id, id))
      {:ok, %{playbook | entries: playbook.entries ++ [entry]}}
    end
  end

  defp apply_operation(playbook, %Revise{} = operation, _index) do
    with {:ok, entry} <- fetch_or_error(playbook, operation.id),
         :ok <- expected_revision(entry, operation.expected_revision),
         {:ok, content} <- validate_content(operation.content, playbook.policy),
         {:ok, fields} <- revision_fields(entry, operation, playbook.policy),
         :ok <- ensure_changed(entry, content, fields),
         :ok <- ensure_unique_content(playbook, content, [entry.id]) do
      revised =
        Entry.build(
          content,
          fields ++
            [id: entry.id, revision: entry.revision + 1, parent_hash: entry.hash]
        )

      {:ok, replace_entry(playbook, entry.id, revised)}
    end
  end

  defp apply_operation(playbook, %UpdateCounters{} = operation, _index) do
    with {:ok, entry} <- fetch_or_error(playbook, operation.id),
         :ok <- expected_revision(entry, operation.expected_revision),
         :ok <- validate_counter_increment(operation.helpful, playbook.policy),
         :ok <- validate_counter_increment(operation.harmful, playbook.policy),
         :ok <- ensure_counter_change(operation),
         {:ok, helpful} <- bounded_sum([entry.helpful, operation.helpful], playbook.policy),
         {:ok, harmful} <- bounded_sum([entry.harmful, operation.harmful], playbook.policy) do
      updated =
        Entry.build(entry.content,
          id: entry.id,
          section: entry.section,
          status: entry.status,
          helpful: helpful,
          harmful: harmful,
          provenance: entry.provenance,
          revision: entry.revision + 1,
          parent_hash: entry.hash
        )

      {:ok, replace_entry(playbook, entry.id, updated)}
    end
  end

  defp apply_operation(playbook, %Remove{} = operation, _index) do
    with {:ok, entry} <- fetch_or_error(playbook, operation.id),
         :ok <- expected_revision(entry, operation.expected_revision) do
      tombstone = %Tombstone{
        entry: entry,
        operation: :remove,
        at_revision: playbook.revision + 1
      }

      {:ok,
       %{
         playbook
         | entries: Enum.reject(playbook.entries, &(&1.id == entry.id)),
           tombstones: playbook.tombstones ++ [tombstone]
       }}
    end
  end

  defp apply_operation(playbook, %Merge{} = operation, index) do
    with :ok <- validate_merge_ids(operation.ids),
         {:ok, sources} <- fetch_sources(playbook, operation.ids),
         :ok <- expected_revisions(sources, operation.expected_revisions),
         {:ok, content} <- validate_content(operation.content, playbook.policy),
         {:ok, fields} <- merge_fields(sources, operation, playbook.policy),
         :ok <- ensure_unique_content(playbook, content, operation.ids),
         {:ok, id} <- operation_id(playbook, operation.id, content, index),
         :ok <- ensure_unused_id(playbook, id) do
      merged = Entry.build(content, Keyword.put(fields, :id, id))
      source_ids = MapSet.new(operation.ids)

      tombstones =
        Enum.map(sources, fn entry ->
          %Tombstone{
            entry: entry,
            operation: :merge,
            at_revision: playbook.revision + 1,
            replacement_id: merged.id
          }
        end)

      first_index = Enum.find_index(playbook.entries, &MapSet.member?(source_ids, &1.id))
      survivors = Enum.reject(playbook.entries, &MapSet.member?(source_ids, &1.id))
      entries = List.insert_at(survivors, first_index, merged)
      {:ok, %{playbook | entries: entries, tombstones: playbook.tombstones ++ tombstones}}
    end
  end

  defp apply_operation(_playbook, operation, _index),
    do: {:error, {:invalid_operation, operation}}

  defp validate_content(content, policy) when is_binary(content) do
    normalized = Entry.normalize(content)

    case Policy.validate_content(normalized, policy) do
      :ok -> {:ok, normalized}
      error -> error
    end
  end

  defp validate_content(content, policy), do: Policy.validate_content(content, policy)

  defp ensure_unique_content(playbook, content, excluded_ids) do
    case Enum.find(playbook.entries, &(&1.content == content and &1.id not in excluded_ids)) do
      nil -> :ok
      entry -> {:error, {:duplicate_content, entry.id}}
    end
  end

  defp ensure_changed(entry, content, fields) do
    unchanged? =
      entry.content == content and entry.section == fields[:section] and
        entry.status == fields[:status] and entry.helpful == fields[:helpful] and
        entry.harmful == fields[:harmful] and entry.provenance == fields[:provenance]

    if unchanged?, do: {:error, :unchanged_entry}, else: :ok
  end

  defp operation_id(playbook, nil, content, index) do
    seed = [playbook.id, playbook.revision + 1, index, content]
    {:ok, "ent_" <> String.slice(Canonical.hash(seed), 0, 24)}
  end

  defp operation_id(_playbook, id, _content, _index) do
    if Entry.valid_id?(id), do: {:ok, id}, else: {:error, {:invalid_entry_id, id}}
  end

  defp ensure_unused_id(playbook, id) do
    historical_ids = Enum.map(playbook.tombstones, & &1.entry.id)

    if Enum.any?(playbook.entries, &(&1.id == id)) or id in historical_ids,
      do: {:error, {:duplicate_id, id}},
      else: :ok
  end

  defp fetch_or_error(playbook, id) do
    case fetch(playbook, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:entry_not_found, id}}
    end
  end

  defp expected_revision(_entry, nil), do: :ok
  defp expected_revision(%Entry{revision: revision}, revision), do: :ok

  defp expected_revision(entry, expected),
    do: {:error, {:stale_entry_revision, entry.id, expected, entry.revision}}

  defp validate_merge_ids(ids) when is_list(ids) and length(ids) >= 2 do
    if Enum.all?(ids, &is_binary/1) and length(Enum.uniq(ids)) == length(ids),
      do: :ok,
      else: {:error, :merge_ids_must_be_unique_strings}
  end

  defp validate_merge_ids(_ids), do: {:error, :merge_requires_at_least_two_ids}

  defp fetch_sources(playbook, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, entries} ->
      case fetch_or_error(playbook, id) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp expected_revisions(_sources, revisions) when revisions == %{}, do: :ok

  defp expected_revisions(sources, revisions) when is_map(revisions) do
    Enum.reduce_while(sources, :ok, fn entry, :ok ->
      case expected_revision_for(entry, revisions) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp expected_revisions(_sources, _revisions), do: {:error, :expected_revisions_must_be_a_map}

  defp expected_revision_for(entry, revisions) do
    case Map.fetch(revisions, entry.id) do
      {:ok, expected} -> expected_revision(entry, expected)
      :error -> {:error, {:missing_expected_revision, entry.id}}
    end
  end

  defp replace_entry(playbook, id, replacement) do
    %{playbook | entries: Enum.map(playbook.entries, &if(&1.id == id, do: replacement, else: &1))}
  end

  defp add_fields(operation, policy) do
    provenance = operation.provenance || %Provenance{}

    Entry.validate_fields(
      [
        section: operation.section,
        status: operation.status,
        helpful: operation.helpful,
        harmful: operation.harmful,
        provenance: provenance
      ],
      policy
    )
  end

  defp revision_fields(entry, operation, policy) do
    Entry.validate_fields(
      [
        section: preserve(operation.section, entry.section),
        status: preserve(operation.status, entry.status),
        helpful: entry.helpful,
        harmful: entry.harmful,
        provenance: preserve(operation.provenance, entry.provenance)
      ],
      policy
    )
  end

  defp merge_fields(sources, operation, policy) do
    with {:ok, supplied} <- normalize_provenance(operation.provenance),
         :ok <- Entry.validate_provenance(supplied, policy),
         {:ok, helpful} <- bounded_sum(Enum.map(sources, & &1.helpful), policy),
         {:ok, harmful} <- bounded_sum(Enum.map(sources, & &1.harmful), policy) do
      provenance = merged_provenance(sources, supplied)

      Entry.validate_fields(
        [
          section: operation.section,
          status: operation.status,
          helpful: helpful,
          harmful: harmful,
          provenance: provenance
        ],
        policy
      )
    end
  end

  defp merged_provenance(sources, supplied) do
    source_references = %Provenance{
      source_ids: Enum.map(sources, & &1.id),
      digests: Enum.map(sources, & &1.hash)
    }

    Provenance.merge([source_references | Enum.map(sources, & &1.provenance)] ++ [supplied])
  end

  defp normalize_provenance(nil), do: {:ok, %Provenance{}}
  defp normalize_provenance(%Provenance{} = provenance), do: {:ok, provenance}
  defp normalize_provenance(_provenance), do: {:error, :invalid_provenance}

  defp preserve(:preserve, previous), do: previous
  defp preserve(value, _previous), do: value

  defp validate_counter_increment(value, policy), do: Policy.validate_counter(value, policy)

  defp ensure_counter_change(%UpdateCounters{helpful: 0, harmful: 0}),
    do: {:error, :empty_counter_update}

  defp ensure_counter_change(_operation), do: :ok

  defp bounded_sum(values, policy) do
    Enum.reduce_while(values, {:ok, 0}, fn value, {:ok, total} ->
      with :ok <- Policy.validate_counter(value, policy),
           sum = total + value,
           :ok <- Policy.validate_counter(sum, policy) do
        {:cont, {:ok, sum}}
      else
        {:error, _reason} -> {:halt, {:error, {:counter_overflow, policy.max_counter}}}
      end
    end)
  end

  defp validate_final(playbook) do
    count = length(playbook.entries)
    tombstone_count = length(playbook.tombstones)

    bytes =
      Enum.reduce(playbook.entries, 0, &(Entry.semantic_bytes(&1) + &2)) +
        Enum.reduce(playbook.tombstones, 0, &(Entry.semantic_bytes(&1.entry) + &2))

    cond do
      count > playbook.policy.max_entries ->
        {:error, {:too_many_entries, count}}

      tombstone_count > playbook.policy.max_tombstones ->
        {:error, {:too_many_tombstones, tombstone_count}}

      bytes > playbook.policy.max_playbook_bytes ->
        {:error, {:playbook_too_large, bytes}}

      true ->
        :ok
    end
  end

  defp rehash(playbook) do
    payload = playbook |> dump() |> Map.delete("hash")
    %{playbook | hash: Canonical.hash(payload)}
  end

  defp default_id(policy),
    do: "pb_" <> String.slice(Canonical.hash(dump_policy(policy)), 0, 24)

  defp normalize_policy(%Policy{} = policy), do: Policy.new(Map.from_struct(policy))
  defp normalize_policy(opts), do: Policy.new(opts)

  defp dump_entry(entry) do
    %{
      "content" => entry.content,
      "harmful" => entry.harmful,
      "hash" => entry.hash,
      "helpful" => entry.helpful,
      "id" => entry.id,
      "parent_hash" => entry.parent_hash,
      "provenance" => Entry.provenance_payload(entry.provenance),
      "revision" => entry.revision,
      "section" => entry.section,
      "status" => Atom.to_string(entry.status)
    }
  end

  defp dump_tombstone(tombstone) do
    %{
      "at_revision" => tombstone.at_revision,
      "entry" => dump_entry(tombstone.entry),
      "operation" => Atom.to_string(tombstone.operation),
      "replacement_id" => tombstone.replacement_id
    }
  end

  defp dump_policy(policy) do
    %{
      "max_entries" => policy.max_entries,
      "max_entry_bytes" => policy.max_entry_bytes,
      "max_operations" => policy.max_operations,
      "max_playbook_bytes" => policy.max_playbook_bytes,
      "max_provenance_items" => policy.max_provenance_items,
      "max_section_bytes" => policy.max_section_bytes,
      "max_source_id_bytes" => policy.max_source_id_bytes,
      "max_tombstones" => policy.max_tombstones,
      "max_counter" => policy.max_counter,
      "reject_secrets" => policy.reject_secrets
    }
  end
end
