defmodule Imp.ACP.SessionStore do
  @moduledoc false

  @version 1
  @session_id ~r/\Aimp_[A-Za-z0-9_-]{24}\z/

  @spec enabled?(term()) :: boolean()
  def enabled?(root), do: is_binary(root) and root != ""

  @spec create(Path.t() | nil, String.t(), map()) :: :ok | {:error, term()}
  def create(nil, _session_id, _metadata), do: :ok

  def create(root, session_id, metadata) do
    now = timestamp()

    write(root, session_id, %{
      "version" => @version,
      "sessionId" => session_id,
      "cwd" => metadata.cwd,
      "createdAt" => now,
      "updatedAt" => now,
      "title" => nil,
      "meta" => Map.get(metadata, :meta) || %{},
      "history" => nil,
      "transcript" => []
    })
  end

  @spec persist(Path.t() | nil, String.t(), map(), Imp.History.t() | nil, [map()]) ::
          :ok | {:error, term()}
  def persist(nil, _session_id, _metadata, _history, _transcript), do: :ok

  def persist(root, session_id, metadata, history, transcript) do
    with {:ok, existing} <- read(root, session_id),
         {:ok, dumped_history} <- dump_history(history),
         {:ok, transcript} <- transcript(transcript) do
      record =
        existing
        |> Map.put("cwd", metadata.cwd)
        |> Map.put("updatedAt", timestamp())
        |> Map.put("title", title(transcript))
        # The session's own `_meta`, stored beside the history it produced. A
        # restored session must be the same thing it was, not whatever the
        # resuming request happens to say — see `Imp.ACP.Handler`.
        |> Map.put("meta", Map.get(metadata, :meta) || %{})
        |> Map.put("history", dumped_history)
        |> Map.put("transcript", transcript)

      write(root, session_id, record)
    end
  end

  @spec load(Path.t() | nil, String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def load(nil, _session_id, _cwd), do: {:error, :session_persistence_disabled}

  def load(root, session_id, cwd) do
    with {:ok, record} <- read(root, session_id),
         :ok <- validate_cwd(record, cwd),
         {:ok, transcript} <- transcript(record["transcript"]) do
      {:ok,
       %{
         record: record,
         meta: stored_meta(record),
         history: record["history"],
         transcript: transcript
       }}
    end
  end

  @doc false
  @spec load_history(Imp.History.t() | map() | nil) ::
          {:ok, Imp.History.t() | nil} | {:error, term()}
  def load_history(%Imp.History{} = history), do: {:ok, history}
  def load_history(nil), do: {:ok, nil}

  def load_history(history) when is_map(history) do
    {:ok, Imp.History.load(history)}
  rescue
    _exception -> {:error, :invalid_session_history}
  end

  def load_history(_history), do: {:error, :invalid_session_history}

  @spec list(Path.t() | nil, map()) :: {:ok, [map()]} | {:error, term()}
  def list(nil, _params), do: {:error, :session_persistence_disabled}

  def list(root, params) do
    root = Path.expand(root)
    cwd = params["cwd"]

    case File.ls(root) do
      {:ok, entries} ->
        sessions =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.flat_map(fn entry ->
            session_id = String.trim_trailing(entry, ".json")

            case read(root, session_id) do
              {:ok, record} -> [record]
              {:error, _reason} -> []
            end
          end)
          |> Enum.filter(&(not is_binary(cwd) or &1["cwd"] == Path.expand(cwd)))
          |> Enum.sort_by(&(&1["updatedAt"] || ""), :desc)
          |> Enum.map(&Map.take(&1, ["sessionId", "cwd", "title", "updatedAt"]))

        {:ok, sessions}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:session_store_list_failed, reason}}
    end
  end

  @spec delete(Path.t() | nil, String.t()) :: :ok | {:error, term()}
  def delete(nil, _session_id), do: {:error, :session_persistence_disabled}

  def delete(root, session_id) do
    with {:ok, path} <- session_path(root, session_id) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> {:error, :unknown_session}
        {:error, reason} -> {:error, {:session_store_delete_failed, reason}}
      end
    end
  end

  defp read(root, session_id) do
    with {:ok, path} <- session_path(root, session_id),
         {:ok, body} <- File.read(path),
         {:ok, record} <- Jason.decode(body),
         :ok <- validate_record(record, session_id) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :unknown_session}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_session_record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(root, session_id, record) do
    with {:ok, path} <- session_path(root, session_id),
         :ok <- ensure_root(root),
         {:ok, encoded} <- Jason.encode(record) do
      temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

      with :ok <- File.write(temporary, encoded, [:binary, :sync]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(temporary)
          {:error, {:session_store_write_failed, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_root(root) do
    root = Path.expand(root)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:session_store_create_failed, reason}}
    end
  end

  defp session_path(root, session_id) when is_binary(session_id) do
    if Regex.match?(@session_id, session_id) do
      {:ok, Path.join(Path.expand(root), session_id <> ".json")}
    else
      {:error, :invalid_session_id}
    end
  end

  defp session_path(_root, _session_id), do: {:error, :invalid_session_id}

  defp validate_record(
         %{"version" => @version, "sessionId" => session_id, "cwd" => cwd},
         session_id
       )
       when is_binary(cwd),
       do: :ok

  defp validate_record(_record, _session_id), do: {:error, :invalid_session_record}

  defp validate_cwd(%{"cwd" => stored}, cwd) when is_binary(cwd) do
    if stored == Path.expand(cwd), do: :ok, else: {:error, :workspace_mismatch}
  end

  defp validate_cwd(_record, _cwd), do: {:error, :workspace_mismatch}

  # Records written before sessions carried `_meta` have no "meta" key. They
  # resume as they always did — with whatever the endpoint's own default is —
  # rather than being refused for a field they could not have stored.
  defp stored_meta(%{"meta" => meta}) when is_map(meta), do: meta
  defp stored_meta(_record), do: %{}

  defp dump_history(%Imp.History{} = history), do: {:ok, Imp.History.dump(history)}
  defp dump_history(nil), do: {:ok, nil}
  defp dump_history(_history), do: {:error, :unsupported_session_history}

  defp transcript(entries) when is_list(entries) do
    if Enum.all?(entries, &valid_turn?/1),
      do: {:ok, entries},
      else: {:error, :invalid_session_transcript}
  end

  defp transcript(_entries), do: {:error, :invalid_session_transcript}

  defp valid_turn?(%{"user" => user, "assistant" => assistant}),
    do: is_binary(user) and is_binary(assistant)

  defp valid_turn?(_turn), do: false

  defp title([%{"user" => user} | _]), do: truncate(user, 120)
  defp title(_transcript), do: nil

  defp truncate(text, max) do
    if String.length(text) > max,
      do: String.slice(text, 0, max - 3) <> "...",
      else: text
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
