defmodule Imp.ReActV2RoundTripTest do
  # A saved agent must ask the model what the agent it was saved from asks.
  use ExUnit.Case, async: true

  test "a loaded ReActV2 rebuilds its loop's guidance, request shape and tool roster" do
    run = fn _args -> "seen" end
    registry = Imp.Saving.Registry.new(%{look: run})
    look = Imp.tool(:look, "Look around", run)

    for signature <- ["question -> answer", "question -> answer, confidence: float"] do
      agent = Imp.react(signature, [look])

      loaded =
        agent
        |> Imp.dump(registry: registry)
        |> Jason.encode!()
        |> Jason.decode!()
        |> Imp.load!(registry: registry)

      assert loaded.react.adapter_opts == agent.react.adapter_opts
      assert loaded.react.config == agent.react.config
      assert loaded.react.signature.metadata[:text_field] == :next_thought
    end
  end
end
