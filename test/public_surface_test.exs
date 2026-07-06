defmodule PublicSurfaceTest do
  use ExUnit.Case

  setup do
    Dachshund.configure(lm: nil, adapter: Dachshund.Adapter.Chat, retriever: nil)
    :ok
  end

  test "prediction public surface has executable equivalents" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "4", rationale: "math"} end]
    }

    program = Dachshund.predict("question -> answer", lm: lm)

    assert Dachshund.majority(["A", "a", "B"]) == "A"
    assert {:ok, pred} = Dachshund.Predict.Predict.call(program, %{question: "2+2?"})
    assert Dachshund.Prediction.get(pred, :answer) == "4"

    mcc = Dachshund.Predict.MultiChainComparison.new("question -> answer", lm: lm, m: 2)

    assert {:ok, compared} =
             Dachshund.Predict.MultiChainComparison.call(mcc, %{
               question: "2+2?",
               completions: [%{reasoning: "add", answer: "4"}, %{reasoning: "count", answer: "4"}]
             })

    assert Dachshund.Prediction.get(compared, :answer) == "4"

    rlm_lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{action: "submit", result: %{answer: "4"}} end]
    }

    rlm = Dachshund.rlm("question, logs -> answer", lm: rlm_lm, max_iterations: 2)

    assert {:ok, rlm_pred} =
             Dachshund.Predict.RLM.call(rlm, %{question: "2+2?", logs: "large context"})

    assert Dachshund.Prediction.get(rlm_pred, :answer) == "4"
    assert [%{action: :submit}] = rlm_pred.metadata.rlm_trace
  end

  test "react v2 and code act execute operational loops" do
    react_lm = %{
      module: Dachshund.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "pong"}}]}
        end
      ]
    }

    agent = Dachshund.react_v2("question -> answer", [], lm: react_lm, max_iters: 2)
    assert {:ok, pred} = Dachshund.Predict.ReActV2.call(agent, %{question: "ping"})
    assert Dachshund.Prediction.get(pred, :answer) == "pong"

    pot_lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{program: "n * n"} end]
    }

    code_act = Dachshund.code_act("n -> answer", [], lm: pot_lm)
    assert {:ok, code_pred} = Dachshund.Predict.CodeAct.call(code_act, %{n: 5})
    assert Dachshund.Prediction.get(code_pred, :answer) == 25
  end

  test "optimizer public surface composes programs" do
    metric = Dachshund.Metrics.exact_match(:answer)
    lm = %{module: Dachshund.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = Dachshund.predict("question -> answer", lm: lm)

    trainset = [
      Dachshund.example(question: "2+2?", answer: "4")
      |> Dachshund.Example.with_inputs(:question),
      Dachshund.example(question: "sqrt 16?", answer: "4")
      |> Dachshund.Example.with_inputs(:question)
    ]

    knn =
      Dachshund.Optimizer.KNNFewShot.new(1, trainset)
      |> Dachshund.Optimizer.KNNFewShot.compile(program)

    assert {:ok, _} = Dachshund.Optimizer.KNNFewShot.Program.call(knn, %{question: "2+2?"})

    ensemble =
      Dachshund.Optimizer.Ensemble.new(
        reduce_fn: fn preds ->
          Dachshund.Prediction.new(
            answer: Dachshund.Predict.Aggregation.majority(preds, field: :answer)
          )
        end
      )
      |> Dachshund.Optimizer.Ensemble.compile([program, program])

    assert {:ok, ens_pred} =
             Dachshund.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert Dachshund.Prediction.get(ens_pred, :answer) == "4"

    better =
      Dachshund.Optimizer.BetterTogether.new(metric, %{
        p: Dachshund.Optimizer.LabeledFewShot.new(k: 1)
      })

    compiled =
      Dachshund.Optimizer.BetterTogether.compile(better, program, trainset, trainset,
        strategy: "p"
      )

    assert {:ok, _} = Dachshund.Predict.Predict.call(compiled, %{question: "2+2?"})
  end

  test "evaluation metrics, auto-evaluation, streaming messages, datasets, cache, and core structs work" do
    assert Dachshund.Metrics.em("The Answer!", ["answer"])
    assert Dachshund.Metrics.f1("red blue", "red green") > 0

    lm = %{
      module: Dachshund.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{reasoning: "judge", precision: 1, recall: 1, f1: 1, completeness: 1, groundedness: 1}
        end
      ]
    }

    assert {:ok, sem} =
             Dachshund.Evaluate.SemanticF1.new(lm: lm)
             |> Dachshund.Evaluate.SemanticF1.call(%{
               question: "q",
               ground_truth: "a",
               system_response: "a"
             })

    assert Dachshund.Prediction.get(sem, :f1) == 1

    provider =
      %Dachshund.Streaming.Messages.StatusMessageProvider{}
      |> Dachshund.Streaming.Messages.StatusMessageProvider.push(
        %Dachshund.Streaming.Messages.StatusMessage{message: "ok"}
      )

    assert length(provider.messages) == 1

    examples =
      Dachshund.Datasets.Colors.load([
        %{input: "red", label: "warm"},
        %{input: "blue", label: "cool"}
      ])

    dataset = Dachshund.Datasets.Dataset.new(examples, train: 0.5)
    assert length(dataset.train) == 1

    assert Dachshund.Cache.put(:x, 42) == 42
    assert Dachshund.Cache.get(:x) == 42

    assert %Dachshund.Core.LMRequest{messages: [%Dachshund.Core.User{content: "hi"}]}
  end
end
