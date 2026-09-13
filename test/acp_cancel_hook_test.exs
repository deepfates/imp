defmodule Imp.ACPCancelHookTest do
  use ExUnit.Case, async: false

  defp session(parent, hook) do
    lm =
      Imp.LM.Static.new(
        handler: fn _, _ ->
          send(parent, {:worker, self()})

          receive do
            :finish -> %{answer: "done"}
          end
        end
      )

    options =
      Imp.ACP.Options.new(
        program: Imp.predict("question -> answer", lm: lm),
        permission_policy: :unrestricted,
        on_cancel: hook
      )

    {:ok, session} =
      Imp.ACP.Session.start_link(session_id: "test", options: options, metadata: %{cwd: "/tmp"})

    on_exit(fn -> if Process.alive?(session), do: Imp.ACP.Session.close(session) end)

    :ok =
      Imp.ACP.Session.prompt(session, [%{"type" => "text", "text" => "work"}], %{
        agent: nil,
        prompt_id: "prompt"
      })

    session
  end

  test "explicit cancellation invokes hook before stopping the observer" do
    parent = self()

    session =
      session(parent, fn _, _ ->
        send(parent, :cancel_requested)
        :ok
      end)

    assert_receive {:worker, worker}
    assert :ok = Imp.ACP.Session.cancel(session)
    assert_receive :cancel_requested
    refute Process.alive?(worker)
    Imp.ACP.Session.close(session)
    refute_receive :cancel_requested
  end

  test "attachment close does not request application cancellation" do
    parent = self()

    session =
      session(parent, fn _, _ ->
        send(parent, :cancel_requested)
        :ok
      end)

    assert_receive {:worker, worker}
    Imp.ACP.Session.close(session)
    refute Process.alive?(worker)
    refute_receive :cancel_requested
  end

  test "hook failure refuses cancellation and leaves the observer active" do
    session = session(self(), fn _, _ -> raise "failed" end)
    assert_receive {:worker, worker}
    assert {:error, :cancel_callback_failed} = Imp.ACP.Session.cancel(session)
    assert Process.alive?(worker)
    Imp.ACP.Session.close(session)
  end
end
