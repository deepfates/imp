defmodule DSEx.Training.ChatDataset do
  @moduledoc """
  Deterministically materializes DSEx examples as MLX-LM chat JSONL.

  Prompts and assistant completions are rendered by the configured DSEx adapter.
  Validation selection is stable and stratified by caller-selected example fields.
  """

  @type dataset :: %{
          train_jsonl: binary(),
          valid_jsonl: binary(),
          train_sha256: String.t(),
          valid_sha256: String.t(),
          dataset_sha256: String.t(),
          train_count: non_neg_integer(),
          valid_count: non_neg_integer()
        }

  @spec build([DSEx.Example.t()], DSEx.Signature.t(), module(), keyword()) ::
          {:ok, dataset()} | {:error, term()}
  def build(examples, signature, adapter, opts \\ [])

  def build(examples, %DSEx.Signature{} = signature, adapter, opts)
      when is_list(examples) and is_atom(adapter) do
    with :ok <- require_examples(examples),
         {:ok, config} <- validate_opts(opts),
         :ok <- validate_adapter(adapter),
         {:ok, items} <- encode_examples(examples, signature, adapter, config.stratify_by) do
      {train, valid} = split(items, config.validation_fraction, config.seed)
      train_jsonl = render_jsonl(train)
      valid_jsonl = render_jsonl(valid)
      train_sha = sha256(train_jsonl)
      valid_sha = sha256(valid_jsonl)

      {:ok,
       %{
         train_jsonl: train_jsonl,
         valid_jsonl: valid_jsonl,
         train_sha256: train_sha,
         valid_sha256: valid_sha,
         dataset_sha256: sha256(canonical_json(%{"train" => train_sha, "valid" => valid_sha})),
         train_count: length(train),
         valid_count: length(valid)
       }}
    end
  rescue
    error -> {:error, {:chat_dataset_failed, DSEx.Redaction.redact(Exception.message(error))}}
  end

  def build(_examples, _signature, _adapter, _opts), do: {:error, :invalid_chat_dataset_arguments}

  @doc false
  def canonical_json(value), do: IO.iodata_to_binary(encode_json(value))

  defp encode_examples(examples, signature, adapter, stratify_by) do
    examples
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%DSEx.Example{} = example, index}, {:ok, acc} ->
        case encode_example(example, signature, adapter) do
          {:ok, row} ->
            bytes = canonical_json(row)
            stratum = stratum(example, stratify_by)
            {:cont, {:ok, [%{row: row, bytes: bytes, stratum: canonical_json(stratum)} | acc]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_chat_training_example, index, reason}}}
        end

      {invalid, index}, _acc ->
        {:halt, {:error, {:invalid_chat_training_example, index, {:expected_example, invalid}}}}
    end)
    |> case do
      {:ok, items} -> {:ok, add_occurrence_keys(Enum.reverse(items))}
      error -> error
    end
  end

  defp encode_example(example, signature, adapter) do
    inputs = example |> DSEx.Example.inputs() |> DSEx.Example.to_map()
    prompt = adapter.format(signature, inputs, demos: example.demos)
    with_label = adapter.format(signature, inputs, demos: example.demos ++ [example])

    with {:ok, inserted} <- inserted_messages(prompt, with_label),
         {:ok, assistant} <- last_assistant(inserted),
         {:ok, prompt} <- normalize_messages(prompt),
         {:ok, assistant} <- normalize_message(assistant),
         messages <- prompt ++ [assistant],
         :ok <- require_labeled_assistant_end(messages) do
      {:ok, %{"messages" => messages}}
    end
  rescue
    error -> {:error, {:adapter_render_failed, DSEx.Redaction.redact(Exception.message(error))}}
  end

  defp inserted_messages(base, expanded) do
    prefix_count = common_prefix_count(base, expanded)
    base_tail = Enum.drop(base, prefix_count)
    expanded_tail = Enum.drop(expanded, prefix_count)
    suffix_count = common_suffix_count(base_tail, expanded_tail)
    inserted_count = length(expanded_tail) - suffix_count

    if inserted_count > 0,
      do: {:ok, Enum.take(expanded_tail, inserted_count)},
      else: {:error, :adapter_did_not_render_demo}
  end

  defp common_prefix_count(left, right) do
    left |> Enum.zip(right) |> Enum.take_while(fn {a, b} -> a == b end) |> length()
  end

  defp common_suffix_count(left, right),
    do: common_prefix_count(Enum.reverse(left), Enum.reverse(right))

  defp last_assistant(messages) do
    case messages
         |> Enum.filter(&(message_role(&1) in [:assistant, "assistant"]))
         |> List.last() do
      nil -> {:error, :adapter_demo_missing_assistant}
      message -> {:ok, message}
    end
  end

  defp normalize_messages(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize_message(message) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_message(message) when is_map(message) do
    role = message_role(message)
    content = Map.get(message, :content, Map.get(message, "content"))

    if role in [:system, :user, :assistant, "system", "user", "assistant"] and is_binary(content) do
      {:ok, %{"role" => to_string(role), "content" => content}}
    else
      {:error, {:unsupported_chat_message, DSEx.Redaction.redact(message)}}
    end
  end

  defp normalize_message(message), do: {:error, {:unsupported_chat_message, message}}

  defp message_role(message) when is_map(message),
    do: Map.get(message, :role, Map.get(message, "role"))

  defp require_labeled_assistant_end(messages) do
    case List.last(messages) do
      %{"role" => "assistant", "content" => content}
      when is_binary(content) and byte_size(content) > 0 ->
        :ok

      _other ->
        {:error, :training_conversation_must_end_at_labeled_assistant}
    end
  end

  defp stratum(_example, []), do: "all"

  defp stratum(example, fields) do
    fields
    |> Enum.map(fn field -> {to_string(field), DSEx.Example.get(example, field)} end)
    |> Map.new()
  end

  defp split([], _fraction, _seed), do: {[], []}
  defp split([item], _fraction, _seed), do: {[item], []}
  defp split(items, 0, seed), do: {sort_rows(items, seed), []}

  defp split(items, fraction, seed) do
    target =
      items |> length() |> Kernel.*(fraction) |> round() |> max(1) |> min(length(items) - 1)

    ranked_groups =
      items
      |> Enum.group_by(& &1.stratum)
      |> Enum.sort_by(fn {stratum, _rows} -> stratum end)
      |> Enum.map(fn {stratum, rows} ->
        ranked = Enum.sort_by(rows, &sha256("#{seed}:#{stratum}:#{&1.key}"))
        ideal = length(rows) * fraction
        quota = min(floor(ideal), max(length(rows) - 1, 0))
        %{stratum: stratum, rows: ranked, ideal: ideal, quota: quota}
      end)

    allocated = Enum.sum(Enum.map(ranked_groups, & &1.quota))

    ranked_groups =
      if allocated < target do
        distribute_quotas(ranked_groups, target - allocated)
      else
        ranked_groups
      end

    valid_set =
      ranked_groups
      |> Enum.flat_map(&Enum.take(&1.rows, &1.quota))
      |> MapSet.new(& &1.key)

    {valid, train} = Enum.split_with(items, &MapSet.member?(valid_set, &1.key))

    {sort_rows(train, seed), sort_rows(valid, seed)}
  end

  defp distribute_quotas(groups, 0), do: groups

  defp distribute_quotas(groups, remaining) do
    candidates =
      groups
      |> Enum.with_index()
      |> Enum.filter(fn {group, _index} -> group.quota < max(length(group.rows) - 1, 0) end)
      |> Enum.sort_by(fn {group, _index} -> {group.quota - group.ideal, group.stratum} end)

    case candidates do
      [] ->
        distribute_without_strata(groups, remaining)

      [{_group, index} | _rest] ->
        groups =
          List.update_at(groups, index, &Map.update!(&1, :quota, fn quota -> quota + 1 end))

        distribute_quotas(groups, remaining - 1)
    end
  end

  defp distribute_without_strata(groups, remaining) do
    Enum.reduce_while(1..remaining, groups, fn _, acc ->
      case Enum.find_index(acc, &(&1.quota < length(&1.rows))) do
        nil ->
          {:halt, acc}

        index ->
          {:cont, List.update_at(acc, index, &Map.update!(&1, :quota, fn quota -> quota + 1 end))}
      end
    end)
  end

  defp sort_rows(rows, seed), do: Enum.sort_by(rows, &sha256("#{seed}:#{&1.key}"))
  defp render_jsonl(rows), do: Enum.map_join(rows, "", &(&1.bytes <> "\n"))

  defp validate_adapter(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :format, 3),
      do: :ok,
      else: {:error, {:invalid_chat_dataset_adapter, adapter}}
  end

  defp require_examples([]), do: {:error, :chat_training_examples_required}
  defp require_examples(_examples), do: :ok

  defp add_occurrence_keys(items) do
    items
    |> Enum.sort_by(&{&1.bytes, &1.stratum})
    |> Enum.map_reduce(%{}, fn item, counts ->
      occurrence = Map.get(counts, item.bytes, 0)

      {Map.put(item, :key, "#{item.bytes}:#{occurrence}"),
       Map.put(counts, item.bytes, occurrence + 1)}
    end)
    |> elem(0)
  end

  defp validate_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      fraction = Keyword.get(opts, :validation_fraction, 0.1)
      seed = Keyword.get(opts, :seed, 0)
      stratify_by = opts |> Keyword.get(:stratify_by, []) |> List.wrap()

      cond do
        not (is_number(fraction) and fraction >= 0 and fraction < 1) ->
          {:error, :invalid_validation_fraction}

        not is_integer(seed) ->
          {:error, :invalid_dataset_seed}

        not Enum.all?(stratify_by, &(is_atom(&1) or is_binary(&1))) ->
          {:error, :invalid_stratify_by}

        true ->
          {:ok, %{validation_fraction: fraction, seed: seed, stratify_by: stratify_by}}
      end
    else
      {:error, :invalid_chat_dataset_options}
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_chat_dataset_options}

  defp encode_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
      |> Enum.sort_by(&elem(&1, 0))

    [
      "{",
      entries
      |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", encode_json(nested)] end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  defp encode_json(value) when is_list(value),
    do: ["[", value |> Enum.map(&encode_json/1) |> Enum.intersperse(","), "]"]

  defp encode_json(value), do: Jason.encode!(value)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
