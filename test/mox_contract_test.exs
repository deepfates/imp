defmodule MoxContractTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  test "DSEx.LM generate contract drives Predict through a verified mock" do
    expect(DSEx.Test.LMMock, :generate, fn messages, opts ->
      assert [%{role: :system}, %{role: :user, content: content}] = messages
      assert content =~ "Capital?"
      assert Keyword.fetch!(opts, :temperature) == 0
      {:ok, %{answer: "Paris"}}
    end)

    program =
      DSEx.predict("question -> answer",
        lm: DSEx.Test.LMMock,
        config: [temperature: 0]
      )

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital?"})
    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "DSEx.Streaming uses an LM stream callback through a verified mock" do
    expect(DSEx.Test.LMMock, :stream, fn lm, messages, opts ->
      assert lm == DSEx.Test.LMMock
      assert [%{role: :system}, %{role: :user}] = messages
      assert Keyword.fetch!(opts, :sample) == true

      [
        %DSEx.Streaming.Messages.StreamResponse{chunk: "po"},
        %DSEx.Streaming.Messages.StreamResponse{chunk: "ng", done: true}
      ]
    end)

    program =
      DSEx.predict("question -> answer",
        lm: DSEx.Test.LMMock,
        config: [sample: true]
      )

    assert ["po", "ng"] =
             program
             |> DSEx.Streaming.stream(%{question: "say pong"}, provider_stream: true)
             |> Enum.map(& &1.chunk)
  end

  test "DSEx.Streaming provider mode streams through ChainOfThought wrappers" do
    expect(DSEx.Test.LMMock, :stream, fn lm, messages, _opts ->
      assert lm == DSEx.Test.LMMock
      rendered = Enum.map_join(messages, "\n", & &1.content)
      assert rendered =~ "[[ ## reasoning ## ]]"
      assert rendered =~ "[[ ## answer ## ]]"

      [
        %DSEx.Streaming.Messages.StreamResponse{chunk: "because "},
        %DSEx.Streaming.Messages.StreamResponse{chunk: "Paris", done: true}
      ]
    end)

    program = DSEx.chain_of_thought("question -> answer", lm: DSEx.Test.LMMock)

    assert ["because ", "Paris"] =
             program
             |> DSEx.Streaming.stream(%{question: "France?"}, provider_stream: true)
             |> Enum.map(& &1.chunk)
  end

  test "DSEx.Retrieve behaviour contract is verified by Mox" do
    expect(DSEx.Test.RetrieverMock, :retrieve, fn query, opts ->
      assert query == "beam"
      assert Keyword.fetch!(opts, :k) == 2
      {:ok, [%{text: "BEAM", score: 1.0}]}
    end)

    assert {:ok, [%{text: "BEAM", score: 1.0}]} =
             DSEx.Retrieve.retrieve(DSEx.Test.RetrieverMock, "beam", k: 2)
  end

  test "DSEx.Clients.Trainer behaviour contract is verified by Mox" do
    lm = DSEx.req_llm("openai:gpt-test")
    examples = [DSEx.example(question: "q", answer: "a")]

    expect(DSEx.Test.TrainerMock, :finetune, fn ^lm, ^examples, opts ->
      assert Keyword.fetch!(opts, :suffix) == "contract"

      {:ok,
       DSEx.Clients.TrainingJob.new(%{
         provider: :mock,
         model: "gpt-test",
         status: :running,
         training_data: examples
       })}
    end)

    assert {:ok, %DSEx.Clients.TrainingJob{provider: :mock, status: :running}} =
             DSEx.Clients.Trainer.finetune(DSEx.Test.TrainerMock, lm, examples,
               suffix: "contract"
             )
  end
end
