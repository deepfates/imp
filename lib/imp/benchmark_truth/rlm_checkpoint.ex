defmodule Imp.BenchmarkTruth.RLMCheckpoint do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def start(opts), do: GenServer.start(__MODULE__, opts)
  def claim(server, key, intent), do: GenServer.call(server, {:claim, key, intent}, :infinity)
  def commit(server, key, outcome), do: GenServer.call(server, {:commit, key, outcome}, :infinity)
  def rows(server), do: GenServer.call(server, :rows)
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    identity = Keyword.fetch!(opts, :identity)
    state = load!(path, identity)

    ambiguous = state["intents"] |> Map.keys() |> Enum.sort()

    unless ambiguous == [],
      do:
        raise(
          ArgumentError,
          "cannot safely resume RLM campaign; durable dispatch intents have ambiguous outcomes: #{Enum.join(ambiguous, ", ")}"
        )

    {:ok, %{path: path, data: state}}
  end

  @impl true
  def handle_call({:claim, key, intent}, _from, state) do
    cond do
      Map.has_key?(state.data["committed"], key) ->
        {:reply, :already_committed, state}

      Map.has_key?(state.data["intents"], key) ->
        {:reply, {:error, :ambiguous}, state}

      true ->
        data = put_in(state.data, ["intents", key], Map.put(intent, "status", "dispatch_intent"))
        persist!(state.path, data)
        {:reply, :claimed, %{state | data: data}}
    end
  end

  def handle_call({:commit, key, outcome}, _from, state) do
    unless Map.has_key?(state.data["intents"], key),
      do: raise(ArgumentError, "cannot commit RLM row without durable intent: #{key}")

    data =
      state.data
      |> update_in(["intents"], &Map.delete(&1, key))
      |> put_in(["committed", key], outcome)

    persist!(state.path, data)
    {:reply, :ok, %{state | data: data}}
  end

  def handle_call(:rows, _from, state),
    do: {:reply, state.data["committed"] |> Map.values() |> Enum.sort_by(& &1["key"]), state}

  def handle_call(:snapshot, _from, state), do: {:reply, state.data, state}

  defp load!(path, identity) do
    case File.read(path) do
      {:ok, bytes} ->
        envelope = Jason.decode!(bytes)
        payload = envelope["payload"]

        unless envelope["payload_sha256"] == digest(payload),
          do: raise(ArgumentError, "RLM checkpoint checksum mismatch: #{path}")

        unless payload["identity"] == identity,
          do: raise(ArgumentError, "RLM checkpoint identity mismatch: #{path}")

        validate!(payload, path)

      {:error, :enoent} ->
        payload = %{
          "schema_version" => 1,
          "identity" => identity,
          "intents" => %{},
          "committed" => %{}
        }

        persist!(path, payload)
        payload

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read RLM checkpoint", path: path
    end
  rescue
    error in Jason.DecodeError ->
      raise ArgumentError, "invalid RLM checkpoint JSON #{path}: #{Exception.message(error)}"
  end

  defp validate!(
         %{"schema_version" => 1, "intents" => intents, "committed" => committed} = payload,
         _path
       )
       when is_map(intents) and is_map(committed), do: payload

  defp validate!(_payload, path),
    do: raise(ArgumentError, "invalid RLM checkpoint structure: #{path}")

  defp persist!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      envelope = %{"payload_sha256" => digest(payload), "payload" => payload}
      File.write!(tmp, Jason.encode!(envelope, pretty: true) <> "\n", [:sync])
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end
  end

  defp digest(term),
    do: term |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
