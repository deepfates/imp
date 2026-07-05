defmodule ParitySurfaceTest do
  use ExUnit.Case

  setup do
    DSPy.configure(lm: nil, adapter: DSPy.Adapter.Chat, retriever: nil)
    :ok
  end

  test "prediction public surface has executable equivalents" do
    lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "4", rationale: "math"} end]
    }

    program = DSPy.predict("question -> answer", lm: lm)

    assert DSPy.majority(["A", "a", "B"]) == "A"
    assert {:ok, pred} = DSPy.Predict.Predict.call(program, %{question: "2+2?"})
    assert DSPy.Prediction.get(pred, :answer) == "4"

    mcc = DSPy.Predict.MultiChainComparison.new("question -> answer", lm: lm, m: 2)

    assert {:ok, compared} =
             DSPy.Predict.MultiChainComparison.call(mcc, %{
               question: "2+2?",
               completions: [%{reasoning: "add", answer: "4"}, %{reasoning: "count", answer: "4"}]
             })

    assert DSPy.Prediction.get(compared, :answer) == "4"

    rlm_lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{action: "submit", result: %{answer: "4"}} end]
    }

    rlm = DSPy.rlm("question, logs -> answer", lm: rlm_lm, max_iterations: 2)

    assert {:ok, rlm_pred} =
             DSPy.Predict.RLM.call(rlm, %{question: "2+2?", logs: "large context"})

    assert DSPy.Prediction.get(rlm_pred, :answer) == "4"
    assert [%{action: :submit}] = rlm_pred.metadata.rlm_trace
  end

  test "react v2 and code act execute operational loops" do
    react_lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "pong"}}]}
        end
      ]
    }

    agent = DSPy.react_v2("question -> answer", [], lm: react_lm, max_iters: 2)
    assert {:ok, pred} = DSPy.Predict.ReActV2.call(agent, %{question: "ping"})
    assert DSPy.Prediction.get(pred, :answer) == "pong"

    pot_lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{program: "n * n"} end]
    }

    code_act = DSPy.code_act("n -> answer", [], lm: pot_lm)
    assert {:ok, code_pred} = DSPy.Predict.CodeAct.call(code_act, %{n: 5})
    assert DSPy.Prediction.get(code_pred, :answer) == 25
  end

  test "teleprompt public surface composes programs" do
    metric = DSPy.Metrics.exact_match(:answer)
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSPy.predict("question -> answer", lm: lm)

    trainset = [
      DSPy.example(question: "2+2?", answer: "4") |> DSPy.Example.with_inputs(:question),
      DSPy.example(question: "sqrt 16?", answer: "4") |> DSPy.Example.with_inputs(:question)
    ]

    knn =
      DSPy.Teleprompt.KNNFewShot.new(1, trainset) |> DSPy.Teleprompt.KNNFewShot.compile(program)

    assert {:ok, _} = DSPy.Teleprompt.KNNFewShot.Program.call(knn, %{question: "2+2?"})

    ensemble =
      DSPy.Teleprompt.Ensemble.new(
        reduce_fn: fn preds ->
          DSPy.Prediction.new(answer: DSPy.Predict.Aggregation.majority(preds, field: :answer))
        end
      )
      |> DSPy.Teleprompt.Ensemble.compile([program, program])

    assert {:ok, ens_pred} = DSPy.Teleprompt.Ensemble.Program.call(ensemble, %{question: "2+2?"})
    assert DSPy.Prediction.get(ens_pred, :answer) == "4"

    better =
      DSPy.Teleprompt.BetterTogether.new(metric, %{p: DSPy.Teleprompt.LabeledFewShot.new(k: 1)})

    compiled =
      DSPy.Teleprompt.BetterTogether.compile(better, program, trainset, trainset, strategy: "p")

    assert {:ok, _} = DSPy.Predict.Predict.call(compiled, %{question: "2+2?"})
  end

  test "evaluation metrics, auto-evaluation, streaming messages, datasets, cache, and core structs work" do
    assert DSPy.Metrics.em("The Answer!", ["answer"])
    assert DSPy.Metrics.f1("red blue", "red green") > 0

    lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{reasoning: "judge", precision: 1, recall: 1, f1: 1, completeness: 1, groundedness: 1}
        end
      ]
    }

    assert {:ok, sem} =
             DSPy.Evaluate.SemanticF1.new(lm: lm)
             |> DSPy.Evaluate.SemanticF1.call(%{
               question: "q",
               ground_truth: "a",
               system_response: "a"
             })

    assert DSPy.Prediction.get(sem, :f1) == 1

    provider =
      %DSPy.Streaming.Messages.StatusMessageProvider{}
      |> DSPy.Streaming.Messages.StatusMessageProvider.push(
        %DSPy.Streaming.Messages.StatusMessage{message: "ok"}
      )

    assert length(provider.messages) == 1

    examples =
      DSPy.Datasets.Colors.load([%{input: "red", label: "warm"}, %{input: "blue", label: "cool"}])

    dataset = DSPy.Datasets.Dataset.new(examples, train: 0.5)
    assert length(dataset.train) == 1

    assert DSPy.Cache.put(:x, 42) == 42
    assert DSPy.Cache.get(:x) == 42

    assert %DSPy.Core.LMRequest{messages: [%DSPy.Core.User{content: "hi"}]}
  end
end
