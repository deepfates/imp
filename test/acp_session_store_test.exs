defmodule Imp.ACP.SessionStoreTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Imp.ACP.SessionStore

  setup do
    root = Path.join(System.tmp_dir!(), "imp-acp-store-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    store = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, workspace: workspace, store: store}
  end

  test "persists a private JSON session and restores its typed history", context do
    session_id = session_id("a")
    metadata = %{cwd: context.workspace}
    history = Imp.History.new([%{question: "first", answer: "observed"}])
    transcript = [%{"user" => "first", "assistant" => "observed"}]

    assert :ok = SessionStore.create(context.store, session_id, metadata)
    assert :ok = SessionStore.persist(context.store, session_id, metadata, history, transcript)

    assert {:ok, restored} = SessionStore.load(context.store, session_id, context.workspace)
    assert restored.transcript == transcript
    assert {:ok, loaded_history} = SessionStore.load_history(restored.history)
    assert Imp.History.messages(loaded_history) == Imp.History.messages(history)

    store_mode = File.stat!(context.store).mode |> band(0o777)
    file_mode = File.stat!(Path.join(context.store, session_id <> ".json")).mode |> band(0o777)
    assert store_mode == 0o700
    assert file_mode == 0o600
  end

  test "workspace identity and generated session IDs fail closed", context do
    session_id = session_id("b")
    assert :ok = SessionStore.create(context.store, session_id, %{cwd: context.workspace})

    assert {:error, :workspace_mismatch} =
             SessionStore.load(context.store, session_id, Path.join(context.root, "other"))

    assert {:error, :invalid_session_id} =
             SessionStore.load(context.store, "../#{session_id}", context.workspace)

    assert {:error, :invalid_session_id} = SessionStore.delete(context.store, "../../outside")
  end

  test "corrupt records do not become resumable sessions", context do
    session_id = session_id("c")
    File.mkdir_p!(context.store)
    File.write!(Path.join(context.store, session_id <> ".json"), "not-json")

    assert {:error, :invalid_session_record} =
             SessionStore.load(context.store, session_id, context.workspace)

    assert {:ok, []} = SessionStore.list(context.store, %{"cwd" => context.workspace})
  end

  test "unsupported history and malformed transcripts fail without replacing the record",
       context do
    session_id = session_id("f")
    metadata = %{cwd: context.workspace}
    assert :ok = SessionStore.create(context.store, session_id, metadata)

    assert {:error, :unsupported_session_history} =
             SessionStore.persist(context.store, session_id, metadata, %{opaque: true}, [])

    assert {:error, :invalid_session_transcript} =
             SessionStore.persist(context.store, session_id, metadata, nil, [%{"user" => 1}])

    assert {:ok, %{transcript: [], history: nil}} =
             SessionStore.load(context.store, session_id, context.workspace)
  end

  test "listing is scoped to the exact selected workspace", context do
    other = Path.join(context.root, "other")
    File.mkdir_p!(other)
    first = session_id("d")
    second = session_id("e")

    assert :ok = SessionStore.create(context.store, first, %{cwd: context.workspace})
    assert :ok = SessionStore.create(context.store, second, %{cwd: other})

    assert {:ok, [%{"sessionId" => ^first}]} =
             SessionStore.list(context.store, %{"cwd" => context.workspace})

    assert {:ok, [%{"sessionId" => ^second}]} =
             SessionStore.list(context.store, %{"cwd" => other})
  end

  defp session_id(character), do: "imp_" <> String.duplicate(character, 24)
end
