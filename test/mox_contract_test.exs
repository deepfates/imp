defmodule MoxContractTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "Imp.LM generate contract drives Predict through a verified mock" do
    expect(Imp.Test.LMMock, :generate, fn messages, opts ->
      assert [%{role: :system}, %{role: :user, content: content}] = messages
      assert content =~ "Capital?"
      assert Keyword.fetch!(opts, :temperature) == 0
      {:ok, %{answer: "Paris"}}
    end)

    program =
      Imp.predict("question -> answer",
        lm: Imp.Test.LMMock,
        config: [temperature: 0]
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital?"})
    assert Imp.get(prediction, :answer) == "Paris"
  end

  test "Imp.Streaming uses an LM stream callback through a verified mock" do
    expect(Imp.Test.LMMock, :stream, fn lm, messages, opts ->
      assert lm == Imp.Test.LMMock
      assert [%{role: :system}, %{role: :user}] = messages
      assert Keyword.fetch!(opts, :sample) == true

      [
        %Imp.Streaming.Messages.StreamResponse{chunk: "po"},
        %Imp.Streaming.Messages.StreamResponse{chunk: "ng", done: true}
      ]
    end)

    program =
      Imp.predict("question -> answer",
        lm: Imp.Test.LMMock,
        config: [sample: true]
      )

    assert ["po", "ng"] =
             program
             |> Imp.Streaming.stream(%{question: "say pong"}, provider_stream: true)
             |> Enum.map(& &1.chunk)
  end

  test "Imp.Streaming provider mode streams through ChainOfThought wrappers" do
    expect(Imp.Test.LMMock, :stream, fn lm, messages, _opts ->
      assert lm == Imp.Test.LMMock
      rendered = Enum.map_join(messages, "\n", & &1.content)
      assert rendered =~ "[[ ## reasoning ## ]]"
      assert rendered =~ "[[ ## answer ## ]]"

      [
        %Imp.Streaming.Messages.StreamResponse{chunk: "because "},
        %Imp.Streaming.Messages.StreamResponse{chunk: "Paris", done: true}
      ]
    end)

    program = Imp.chain_of_thought("question -> answer", lm: Imp.Test.LMMock)

    assert ["because ", "Paris"] =
             program
             |> Imp.Streaming.stream(%{question: "France?"}, provider_stream: true)
             |> Enum.map(& &1.chunk)
  end

  test "Imp.Retrieve behaviour contract is verified by Mox" do
    expect(Imp.Test.RetrieverMock, :retrieve, fn query, opts ->
      assert query == "beam"
      assert Keyword.fetch!(opts, :k) == 2
      {:ok, [%{text: "BEAM", score: 1.0}]}
    end)

    assert {:ok, [%{text: "BEAM", score: 1.0}]} =
             Imp.Retrieve.retrieve(Imp.Test.RetrieverMock, "beam", k: 2)
  end

  test "Imp.Clients.Trainer behaviour contract is verified by Mox" do
    lm = Imp.req_llm("openai:gpt-test")
    examples = [Imp.example(question: "q", answer: "a")]

    expect(Imp.Test.TrainerMock, :supported_methods, fn -> [:sft] end)

    expect(Imp.Test.TrainerMock, :finetune, fn ^lm, ^examples, opts ->
      assert Keyword.fetch!(opts, :suffix) == "contract"

      {:ok,
       Imp.Clients.TrainingJob.new(%{
         provider: :mock,
         model: "gpt-test",
         status: :running,
         training_data: examples
       })}
    end)

    assert {:ok, %Imp.Clients.TrainingJob{provider: :mock, status: :running}} =
             Imp.Clients.Trainer.finetune(Imp.Test.TrainerMock, lm, examples, suffix: "contract")
  end
end
