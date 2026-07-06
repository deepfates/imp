defmodule PublicSurfaceTest do
  use ExUnit.Case

  setup do
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "prediction public surface has executable equivalents" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "4", rationale: "math"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert DSEx.majority(["A", "a", "B"]) == "A"
    assert {:ok, pred} = DSEx.Predict.Predict.call(program, %{question: "2+2?"})
    assert DSEx.Prediction.get(pred, :answer) == "4"

    mcc = DSEx.Predict.MultiChainComparison.new("question -> answer", lm: lm, m: 2)

    assert {:ok, compared} =
             DSEx.Predict.MultiChainComparison.call(mcc, %{
               question: "2+2?",
               completions: [%{reasoning: "add", answer: "4"}, %{reasoning: "count", answer: "4"}]
             })

    assert DSEx.Prediction.get(compared, :answer) == "4"

    rlm_lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{action: "submit", result: %{answer: "4"}} end]
    }

    rlm = DSEx.rlm("question, logs -> answer", lm: rlm_lm, max_iterations: 2)

    assert {:ok, rlm_pred} =
             DSEx.Predict.RLM.call(rlm, %{question: "2+2?", logs: "large context"})

    assert DSEx.Prediction.get(rlm_pred, :answer) == "4"
    assert [%{action: :submit}] = rlm_pred.metadata.rlm_trace
  end

  test "react v2 and code act execute operational loops" do
    react_lm = %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "pong"}}]}
        end
      ]
    }

    agent = DSEx.react_v2("question -> answer", [], lm: react_lm, max_iters: 2)
    assert {:ok, pred} = DSEx.Predict.ReActV2.call(agent, %{question: "ping"})
    assert DSEx.Prediction.get(pred, :answer) == "pong"

    pot_lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{program: "n * n"} end]
    }

    code_act = DSEx.code_act("n -> answer", [], lm: pot_lm)
    assert {:ok, code_pred} = DSEx.Predict.CodeAct.call(code_act, %{n: 5})
    assert DSEx.Prediction.get(code_pred, :answer) == 25
  end

  test "optimizer public surface composes programs" do
    metric = DSEx.Metrics.exact_match(:answer)
    lm = %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.Example.with_inputs(:question),
      DSEx.example(question: "sqrt 16?", answer: "4")
      |> DSEx.Example.with_inputs(:question)
    ]

    knn =
      DSEx.Optimizer.KNNFewShot.new(1, trainset)
      |> DSEx.Optimizer.KNNFewShot.compile(program)

    assert {:ok, _} = DSEx.Optimizer.KNNFewShot.Program.call(knn, %{question: "2+2?"})

    ensemble =
      DSEx.Optimizer.Ensemble.new(
        reduce_fn: fn preds ->
          DSEx.Prediction.new(answer: DSEx.Predict.Aggregation.majority(preds, field: :answer))
        end
      )
      |> DSEx.Optimizer.Ensemble.compile([program, program])

    assert {:ok, ens_pred} =
             DSEx.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert DSEx.Prediction.get(ens_pred, :answer) == "4"

    better =
      DSEx.Optimizer.BetterTogether.new(metric, %{
        p: DSEx.Optimizer.LabeledFewShot.new(k: 1)
      })

    compiled =
      DSEx.Optimizer.BetterTogether.compile(better, program, trainset, trainset, strategy: "p")

    assert {:ok, _} = DSEx.Predict.Predict.call(compiled, %{question: "2+2?"})
  end

  test "evaluation metrics, auto-evaluation, streaming messages, datasets, cache, and core structs work" do
    assert DSEx.Metrics.em("The Answer!", ["answer"])
    assert DSEx.Metrics.f1("red blue", "red green") > 0

    lm = %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{reasoning: "judge", precision: 1, recall: 1, f1: 1, completeness: 1, groundedness: 1}
        end
      ]
    }

    assert {:ok, sem} =
             DSEx.Evaluate.SemanticF1.new(lm: lm)
             |> DSEx.Evaluate.SemanticF1.call(%{
               question: "q",
               ground_truth: "a",
               system_response: "a"
             })

    assert DSEx.Prediction.get(sem, :f1) == 1

    provider =
      %DSEx.Streaming.Messages.StatusMessageProvider{}
      |> DSEx.Streaming.Messages.StatusMessageProvider.push(
        %DSEx.Streaming.Messages.StatusMessage{message: "ok"}
      )

    assert length(provider.messages) == 1

    examples =
      DSEx.Datasets.Colors.load([
        %{input: "red", label: "warm"},
        %{input: "blue", label: "cool"}
      ])

    dataset = DSEx.Datasets.Dataset.new(examples, train: 0.5)
    assert length(dataset.train) == 1

    assert DSEx.Cache.put(:x, 42) == 42
    assert DSEx.Cache.get(:x) == 42

    assert %DSEx.Core.LMRequest{messages: [%DSEx.Core.User{content: "hi"}]}
  end
end
