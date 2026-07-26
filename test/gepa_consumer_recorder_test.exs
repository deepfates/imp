defmodule Imp.GEPAConsumerRecorderTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Instructions
  alias Imp.Observability.StageRecorder

  test "observes a multiline instruction through Chat's canonical objective rendering" do
    instruction = """
    ## Task Instruction
    Choose exactly one route.

    ## Output Contract
    Return the named route field and completion marker.
    """

    signature = Imp.signature("utterance -> route", instruction)
    messages = Imp.Adapter.Chat.format(signature, %{utterance: "synthetic input"}, [])
    rendered = Enum.map_join(messages, "\n", & &1.content)

    refute String.contains?(rendered, instruction)
    assert Instructions.rendered_objective?(instruction, messages)
    assert Instructions.rendered_objective?(instruction, rendered)
    refute Instructions.rendered_objective?(instruction <> "\nChanged", messages)
  end

  test "persists a completed stage before a later acceptance failure" do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-stage-recorder-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "selected-test.json")
    stage = %{status: "complete", accuracy: 0.25, rows: [%{id: "row-1", actual: "R42"}]}
    on_exit(fn -> File.rm_rf!(root) end)

    assert_raise RuntimeError, "instruction-use acceptance failed", fn ->
      StageRecorder.persist_then_validate!(path, stage, fn persisted ->
        assert File.exists?(path)
        assert Jason.decode!(File.read!(path))["accuracy"] == persisted.accuracy
        raise "instruction-use acceptance failed"
      end)
    end

    assert Jason.decode!(File.read!(path)) == Jason.decode!(Jason.encode!(stage))
    assert Path.wildcard(path <> ".tmp-*") == []
  end
end
