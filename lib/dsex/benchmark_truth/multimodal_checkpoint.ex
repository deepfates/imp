defmodule DSEx.BenchmarkTruth.MultimodalCheckpoint do
  @moduledoc false

  def load!(path, identity) do
    checkpoint =
      case File.read(path) do
        {:ok, json} -> decode!(json)
        {:error, :enoent} -> %{"completed" => %{}, "identity" => identity, "in_progress" => %{}}
        {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
      end

    unless checkpoint["identity"] == identity do
      raise ArgumentError, "multimodal checkpoint identity mismatch"
    end

    if map_size(checkpoint["in_progress"]) > 0 do
      ids = checkpoint["in_progress"] |> Map.keys() |> Enum.sort() |> Enum.join(", ")

      raise ArgumentError,
            "ambiguous multimodal dispatch outcome for #{ids}; inspect provider logs and start a new checkpoint or explicitly reconcile the row"
    end

    write!(path, checkpoint)
    checkpoint
  end

  def record_intents!(path, checkpoint, samples) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    updated =
      Enum.reduce(samples, checkpoint, fn sample, acc ->
        id = sample["id"]

        if Map.has_key?(acc["completed"], id) or Map.has_key?(acc["in_progress"], id) do
          raise ArgumentError, "duplicate multimodal dispatch intent for #{id}"
        end

        put_in(acc, ["in_progress", id], %{
          "intent_recorded_at" => now,
          "sample_id" => id
        })
      end)

    write!(path, updated)
    updated
  end

  def record_outcome!(path, checkpoint, sample_id, row) do
    unless Map.has_key?(checkpoint["in_progress"], sample_id) do
      raise ArgumentError, "multimodal outcome without durable intent for #{sample_id}"
    end

    updated =
      checkpoint
      |> update_in(["in_progress"], &Map.delete(&1, sample_id))
      |> put_in(["completed", sample_id], row)

    write!(path, updated)
    updated
  end

  def completed_rows(checkpoint, sample_order) do
    Enum.flat_map(sample_order, fn id ->
      case checkpoint["completed"][id] do
        nil -> []
        row -> [row]
      end
    end)
  end

  defp decode!(json) do
    %{"payload" => payload, "payload_sha256" => expected} = Jason.decode!(json)
    actual = sha256(Jason.encode!(payload))

    unless expected == actual do
      raise ArgumentError, "multimodal checkpoint checksum mismatch"
    end

    unless Map.keys(payload) |> Enum.sort() == ~w(completed identity in_progress) do
      raise ArgumentError, "malformed multimodal checkpoint payload"
    end

    unless is_map(payload["completed"]) and is_map(payload["in_progress"]) do
      raise ArgumentError, "malformed multimodal checkpoint row maps"
    end

    payload
  end

  defp write!(path, checkpoint) do
    File.mkdir_p!(Path.dirname(path))

    envelope = %{
      "payload" => checkpoint,
      "payload_sha256" => sha256(Jason.encode!(checkpoint))
    }

    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(envelope, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    checkpoint
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
