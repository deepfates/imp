defmodule DSEx.BenchmarkTruth.ProviderTrainingCampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.ProviderTrainingCampaign

  test "the pinned dataset verifies its split and payload digests" do
    dataset =
      "benchmarks/data/provider-training-banking77-v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert ProviderTrainingCampaign.valid_dataset?(dataset)

    tampered = put_in(dataset, ["train", Access.at(0), "route"], "R93")
    refute ProviderTrainingCampaign.valid_dataset?(tampered)
  end

  test "training and held-out inference share the chat representation" do
    signature =
      DSEx.signature(
        %{
          inputs: [%{name: :utterance, type: :string}],
          outputs: [
            %{name: :route, type: :string, constraints: %{enum: ["R17", "R42"]}}
          ]
        },
        "Route the query to an opaque code."
      )

    example =
      DSEx.example(utterance: "I do not recognize this payment", route: "R42")
      |> DSEx.with_inputs(:utterance)

    messages = ProviderTrainingCampaign.training_messages(signature, example)
    assistant = Enum.find(messages, &(&1.role == :assistant))

    assert List.last(messages).role == :assistant
    assert assistant.content =~ "[[ ## route ## ]]\nR42"

    assert {:ok, prediction} = DSEx.Adapter.Chat.parse(signature, assistant.content, [])
    assert DSEx.get(prediction, :route) == "R42"

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> assistant.content end]
    }

    program = ProviderTrainingCampaign.evaluation_program(signature, lm)

    assert program.adapter == DSEx.Adapter.Chat

    assert {:ok, prediction} =
             DSEx.call(program, %{utterance: "I do not recognize this payment"})

    assert DSEx.get(prediction, :route) == "R42"
  end
end
