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

  test "documented public modules and facade constructors remain available" do
    public_modules = [
      DSEx,
      DSEx.Adapter.Chat,
      DSEx.Adapter.JSON,
      DSEx.Adapter.XML,
      DSEx.Adapter.TwoStep,
      DSEx.Cache,
      DSEx.Clients.Databricks,
      DSEx.Clients.DatabricksTrainer,
      DSEx.Clients.HTTPLM,
      DSEx.Clients.Local,
      DSEx.Clients.LiteLLM,
      DSEx.Clients.OpenAI,
      DSEx.Clients.OpenAITrainer,
      DSEx.Clients.ReqLLM,
      DSEx.Clients.Trainer,
      DSEx.Datasets,
      DSEx.Embeddings,
      DSEx.Evaluate,
      DSEx.Example,
      DSEx.MCP,
      DSEx.Metrics,
      DSEx.Optimize.Anything,
      DSEx.Optimize.GEPA,
      DSEx.Optimizer.BetterTogether,
      DSEx.Optimizer.BootstrapFewShot,
      DSEx.Optimizer.BootstrapFinetune,
      DSEx.Optimizer.COPRO,
      DSEx.Optimizer.Ensemble,
      DSEx.Optimizer.GEPA,
      DSEx.Optimizer.InstructionSearch,
      DSEx.Optimizer.KNNFewShot,
      DSEx.Optimizer.LabeledFewShot,
      DSEx.Optimizer.MIPROv2,
      DSEx.Optimizer.RandomSearch,
      DSEx.Optimizer.SIMBA,
      DSEx.Predict.BestOfN,
      DSEx.Predict.ChainOfThought,
      DSEx.Predict.CodeAct,
      DSEx.Predict.Parallel,
      DSEx.Predict.Predict,
      DSEx.Predict.RLM,
      DSEx.Predict.ReAct,
      DSEx.Predict.ReActV2,
      DSEx.Predict.Refine,
      DSEx.Prediction,
      DSEx.Retrieve,
      DSEx.Retrievers.Databricks,
      DSEx.Retrievers.HTTP,
      DSEx.Retrievers.KNN,
      DSEx.Retrievers.Weaviate,
      DSEx.Saving,
      DSEx.Signature,
      DSEx.Streaming,
      DSEx.Telemetry,
      DSEx.Tool
    ]

    assert Enum.all?(public_modules, &Code.ensure_loaded?/1)

    facade_exports = [
      configure: 1,
      settings: 0,
      context: 2,
      signature: 1,
      signature: 2,
      example: 1,
      prediction: 1,
      get: 2,
      get: 3,
      majority: 1,
      majority: 2,
      predict: 1,
      predict: 2,
      chain_of_thought: 1,
      chain_of_thought: 2,
      react: 3,
      react: 2,
      program_of_thought: 1,
      program_of_thought: 2,
      code_act: 1,
      code_act: 2,
      code_act: 3,
      react_v2: 3,
      rlm: 1,
      rlm: 2,
      call: 2,
      openai: 1,
      openai: 2,
      req_llm: 1,
      req_llm: 2,
      litellm: 1,
      litellm: 2,
      local_lm: 1,
      local_lm: 2,
      databricks: 1,
      databricks: 2
    ]

    assert Enum.all?(facade_exports, fn {name, arity} ->
             function_exported?(DSEx, name, arity)
           end)

    assert %DSEx.Clients.ReqLLM{} = DSEx.req_llm("openai:gpt-test")

    assert %DSEx.Clients.HTTPLM{provider: :openai} =
             DSEx.openai("gpt-test", api_key: "sk-test")

    assert %DSEx.Retrievers.HTTP{} = DSEx.Retrievers.HTTP.new("https://retriever.example")
    assert %DSEx.MCP.HTTPClient{} = DSEx.MCP.HTTPClient.new("https://mcp.example")

    assert %DSEx.MCP.StreamableHTTPClient{} =
             DSEx.MCP.StreamableHTTPClient.new("https://mcp.example")

    assert %DSEx.Clients.HTTPTrainer{} =
             DSEx.Clients.OpenAITrainer.new(training_file: "file-test")
  end
end
