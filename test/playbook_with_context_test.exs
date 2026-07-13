defmodule DSEx.Playbook.WithContextTest do
  use ExUnit.Case, async: true

  alias DSEx.Playbook
  alias DSEx.Playbook.{Provenance, WithContext}
  alias DSEx.Playbook.Operation.Add
  alias DSEx.ProgramParameters

  test "injects active guidance once without exposing provenance" do
    test_pid = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(test_pid, {:messages, messages})
          %{answer: "ok"}
        end
      ]
    }

    digest = String.duplicate("a", 64)

    {:ok, playbook} =
      Playbook.apply_delta(Playbook.new(id: "runtime"), [
        Add.new("Prefer primary sources.",
          id: "evidence",
          section: "Research",
          provenance: Provenance.new(source_ids: ["private:source"], digests: [digest])
        )
      ])

    wrapper =
      "question -> answer"
      |> DSEx.signature("Answer directly.")
      |> DSEx.predict(lm: lm)
      |> DSEx.with_playbook(playbook)

    assert {:ok, _prediction} = DSEx.call(wrapper, %{question: "Why?"})
    assert_receive {:messages, messages}

    rendered = inspect(messages, limit: :infinity)
    assert count(rendered, "# Playbook") == 1
    assert count(rendered, "Prefer primary sources.") == 1
    refute rendered =~ "private:source"
    refute rendered =~ digest

    assert ProgramParameters.predictors(wrapper)
           |> hd()
           |> Map.fetch!(:predictor)
           |> Map.fetch!(:signature)
           |> Map.fetch!(:instructions) == "Answer directly."
  end

  test "optimizer updates preserve the playbook and target base instructions" do
    playbook = Playbook.new(id: "optimizer")
    wrapper = WithContext.new(DSEx.predict("question -> answer"), playbook)

    updated = ProgramParameters.put_instruction(wrapper, :main, "Be exact.")

    assert updated.playbook == playbook

    assert hd(ProgramParameters.predictors(updated)).predictor.signature.instructions ==
             "Be exact."
  end

  test "constructor rejects structs that cannot receive predictor context" do
    assert_raise ArgumentError, ~r/executable DSEx program/, fn ->
      WithContext.new(%URI{scheme: "https"}, Playbook.new())
    end
  end

  test "empty playbooks leave runtime messages unchanged" do
    test_pid = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(test_pid, {:messages, messages})
          %{answer: "ok"}
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: lm)
    wrapper = DSEx.with_playbook(program, Playbook.new(id: "empty"))

    assert {:ok, _} = DSEx.call(program, %{question: "same"})
    assert_receive {:messages, base_messages}
    assert {:ok, _} = DSEx.call(wrapper, %{question: "same"})
    assert_receive {:messages, wrapped_messages}
    assert wrapped_messages == base_messages
  end

  test "portable save and load retain the program and validated playbook" do
    {:ok, playbook} =
      Playbook.apply_delta(Playbook.new(id: "portable"), [Add.new("Use concise answers.")])

    wrapper = DSEx.with_playbook(DSEx.predict("question -> answer"), playbook)
    state = DSEx.Saving.dump(wrapper)
    restored = DSEx.Saving.load(state)

    assert restored == wrapper
    assert DSEx.Saving.dump(restored) == state
  end

  test "loading rejects tampered hashes and extra fields" do
    {:ok, playbook} =
      Playbook.apply_delta(Playbook.new(id: "tamper"), [Add.new("Keep this stable.")])

    state = Playbook.dump(playbook)
    tampered = put_in(state, ["entries", Access.at(0), "content"], "Changed.")

    entry_rehashed =
      tampered
      |> put_in(
        ["entries", Access.at(0), "hash"],
        String.duplicate("0", 64)
      )

    root_rehashed =
      Map.put(
        entry_rehashed,
        "hash",
        DSEx.Playbook.Canonical.hash(Map.delete(entry_rehashed, "hash"))
      )

    assert_raise ArgumentError, ~r/hash_mismatch/, fn -> Playbook.load!(tampered) end
    assert_raise ArgumentError, ~r/entry.*hash_mismatch/, fn -> Playbook.load!(root_rehashed) end

    assert_raise ArgumentError, ~r/keys must be exactly/, fn ->
      Playbook.load!(Map.put(state, "extra", true))
    end
  end

  defp count(value, pattern), do: length(String.split(value, pattern)) - 1
end
