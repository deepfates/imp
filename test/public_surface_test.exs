defmodule PublicSurfaceTest do
  use ExUnit.Case

  @public_modules [
    DSEx,
    DSEx.Adapter,
    DSEx.Adapter.Chat,
    DSEx.Adapter.JSON,
    DSEx.Adapter.XML,
    DSEx.Adapter.TwoStep,
    DSEx.Adapters.Types,
    DSEx.Agent,
    DSEx.Agent.Runtime,
    DSEx.Cache,
    DSEx.Clients.DatabricksTrainer,
    DSEx.Clients.HTTPTrainer,
    DSEx.Clients.OpenAITrainer,
    DSEx.Clients.ReqLLM,
    DSEx.Clients.Trainer,
    DSEx.Clients.TrainingJob,
    DSEx.Core,
    DSEx.Core.Assistant,
    DSEx.Core.Developer,
    DSEx.Core.LMConfig,
    DSEx.Core.LMRequest,
    DSEx.Core.LMResponse,
    DSEx.Core.Message,
    DSEx.Core.System,
    DSEx.Core.ToolCall,
    DSEx.Core.ToolResult,
    DSEx.Core.User,
    DSEx.Datasets,
    DSEx.Datasets.Colors,
    DSEx.Datasets.DataLoader,
    DSEx.Datasets.Dataset,
    DSEx.Datasets.GSM8K,
    DSEx.Datasets.HotPotQA,
    DSEx.Datasets.MATH,
    DSEx.Embeddings,
    DSEx.Embeddings.BagOfWords,
    DSEx.AdapterParseError,
    DSEx.ContextWindowExceededError,
    DSEx.Error,
    DSEx.Errors,
    DSEx.Evaluate,
    DSEx.Evaluate.CompleteAndGrounded,
    DSEx.Evaluate.Result,
    DSEx.Evaluate.SemanticF1,
    DSEx.Example,
    DSEx.HTTP,
    DSEx.LM,
    DSEx.LMError,
    DSEx.LM.Static,
    DSEx.MCP,
    DSEx.MCP.Catalog,
    DSEx.MCP.HTTPClient,
    DSEx.MCP.StdioClient,
    DSEx.MCP.StreamableHTTPClient,
    DSEx.Metrics,
    DSEx.Metrics.Result,
    DSEx.Module,
    DSEx.Optimize.Anything,
    DSEx.Optimize.Anything.Artifact,
    DSEx.Optimize.Anything.Candidate,
    DSEx.Optimize.Anything.Evaluation,
    DSEx.Optimize.Anything.Report,
    DSEx.Optimize.GEPA,
    DSEx.Optimize.GEPA.Candidate,
    DSEx.Optimize.GEPA.Report,
    DSEx.Optimizer.BetterTogether,
    DSEx.Optimizer.BootstrapFewShot,
    DSEx.Optimizer.BootstrapFinetune,
    DSEx.Optimizer.COPRO,
    DSEx.Optimizer.Ensemble,
    DSEx.Optimizer.GEPA,
    DSEx.Optimizer.GRPO,
    DSEx.Optimizer.InstructionProposer,
    DSEx.Optimizer.InstructionSearch,
    DSEx.Optimizer.KNNFewShot,
    DSEx.Optimizer.LabeledFewShot,
    DSEx.Optimizer.MIPROv2,
    DSEx.Optimizer.RandomSearch,
    DSEx.Optimizer.Report,
    DSEx.Optimizer.SIMBA,
    DSEx.Optimizer.SignatureOptimizer,
    DSEx.Predict.Aggregation,
    DSEx.Predict.BestOfN,
    DSEx.Predict.ChainOfThought,
    DSEx.Predict.CodeAct,
    DSEx.Predict.KNN,
    DSEx.Predict.MultiChainComparison,
    DSEx.Predict.Parallel,
    DSEx.Predict.Predict,
    DSEx.Predict.ProgramOfThought,
    DSEx.Predict.RAG,
    DSEx.Predict.RLM,
    DSEx.Predict.ReAct,
    DSEx.Predict.Refine,
    DSEx.Prediction,
    DSEx.Redaction,
    DSEx.Retrieve,
    DSEx.Retrieve.Memory,
    DSEx.Retrievers.Databricks,
    DSEx.Retrievers.HTTP,
    DSEx.Retrievers.KNN,
    DSEx.Retrievers.Weaviate,
    DSEx.Sandbox,
    DSEx.Saving,
    DSEx.Schema,
    DSEx.Settings,
    DSEx.Signature,
    DSEx.Signature.Field,
    DSEx.Streaming,
    DSEx.Streaming.Messages,
    DSEx.Streaming.Messages.StreamListener,
    DSEx.Streaming.Messages.StreamResponse,
    DSEx.Streaming.Messages.StatusMessage,
    DSEx.Streaming.Messages.StatusMessageProvider,
    DSEx.Tasks,
    DSEx.Telemetry,
    DSEx.Tool
  ]

  defmodule ExplodingProgram do
    @behaviour DSEx.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs), do: raise("program exploded")
  end

  defmodule InvalidPredictionProgram do
    @behaviour DSEx.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs), do: {:ok, %{answer: "not a prediction"}}
  end

  defmodule ErrorProgram do
    @behaviour DSEx.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs), do: {:error, :wrapped_failed}
  end

  setup do
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "prediction public surface has executable equivalents" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "4", rationale: "math"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert DSEx.majority(["A", "a", "B"]) == "A"

    assert %DSEx.Prediction{} =
             DSEx.majority([
               DSEx.Prediction.new(answer: "A"),
               DSEx.Prediction.new(answer: "A"),
               DSEx.Prediction.new(answer: "B")
             ])

    assert DSEx.majority([%{"answer" => "Paris"}, %{answer: "paris"}, %{answer: "Lyon"}],
             field: :answer
           ) == "Paris"

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Aggregation\.majority\/2: expected keyword options/,
                 fn ->
                   DSEx.majority(["A"], :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Aggregation\.majority\/2: invalid value for :normalize option: expected a unary function/,
                 fn ->
                   DSEx.majority(["A"], normalize: :not_a_function)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.Aggregation\.majority\/2: invalid value for :field option: expected nil or an atom\/string field name/,
                 fn ->
                   DSEx.majority(["A"], field: [])
                 end

    assert {:ok, pred} = DSEx.call(program, %{question: "2+2?"})
    assert DSEx.get(pred, :answer) == "4"

    mcc = DSEx.multi_chain_comparison("question -> answer", lm: lm, m: 2)

    assert {:ok, compared} =
             DSEx.call(mcc, %{
               question: "2+2?",
               completions: [%{reasoning: "add", answer: "4"}, %{reasoning: "count", answer: "4"}]
             })

    assert DSEx.get(compared, :answer) == "4"

    assert {:ok, compared_from_strings} =
             DSEx.call(mcc, %{
               "question" => "2+2?",
               "completions" => [
                 %{"reasoning" => "add", "answer" => "4"},
                 DSEx.Prediction.new(reasoning: "count", answer: "4")
               ]
             })

    assert DSEx.get(compared_from_strings, :answer) == "4"

    assert {:error, {:invalid_completions, ~s("not-a-list")}} =
             DSEx.call(mcc, %{
               question: "2+2?",
               completions: "not-a-list"
             })

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.MultiChainComparison\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.multi_chain_comparison("question -> answer", %{m: 2})
                 end

    assert {:error, {:invalid_multi_chain_inputs, message}} =
             DSEx.call(mcc, :not_inputs)

    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_multi_chain_inputs, "expected inputs as {key, value} pairs"}} =
             DSEx.call(mcc, [:not_a_pair])

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.MultiChainComparison\.new\/2: invalid value for :m option: expected a positive integer/,
                 fn ->
                   DSEx.multi_chain_comparison("question -> answer", lm: lm, m: 0)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.MultiChainComparison\.new\/2: invalid value for :M option: expected a positive integer/,
                 fn ->
                   DSEx.multi_chain_comparison("question -> answer", lm: lm, M: "2")
                 end

    metric = DSEx.exact_match(:answer)

    assert {:ok, best} =
             program
             |> DSEx.best_of_n(metric, n: 2)
             |> DSEx.call(%{question: "2+2?"})

    assert DSEx.get(best, :answer) == "4"

    assert {:ok, refined} =
             program
             |> DSEx.refine(metric, max_attempts: 1)
             |> DSEx.call(%{question: "2+2?"})

    assert DSEx.get(refined, :answer) == "4"
    assert [%{attempt: 1}] = DSEx.get(refined, :refine_history)

    assert [{:ok, first}, {:ok, second}] =
             DSEx.parallel(program, [%{question: "2+2?"}, %{question: "sqrt 16?"}],
               max_concurrency: 2
             )

    assert Enum.map([first, second], &DSEx.get(&1, :answer)) == ["4", "4"]

    trainset = [
      DSEx.example(question: "capital France", answer: "Paris") |> DSEx.with_inputs(:question),
      DSEx.example(question: "capital Germany", answer: "Berlin") |> DSEx.with_inputs(:question)
    ]

    knn = DSEx.knn(1, trainset, field: "question")
    assert [nearest] = DSEx.nearest(knn, %{question: "France"})
    assert DSEx.get(nearest, :answer) == "Paris"

    assert_raise ArgumentError, ~r/DSEx.nearest\/2 expects a DSEx KNN predictor/, fn ->
      DSEx.nearest(program, %{question: "France"})
    end

    rlm_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{action: "submit", result: %{answer: "4"}} end]
    }

    rlm = DSEx.rlm("question, logs -> answer", lm: rlm_lm, max_iterations: 2)

    assert {:ok, rlm_pred} =
             DSEx.Predict.RLM.call(rlm, %{question: "2+2?", logs: "large context"})

    assert DSEx.Prediction.get(rlm_pred, :answer) == "4"
    assert [%{action: :submit}] = rlm_pred.metadata.rlm_trace
  end

  test "rag wraps a program with retrieved context and metadata" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    base = DSEx.predict("question, context -> answer", lm: lm)
    retriever = DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}])
    rag = DSEx.rag(base, retriever, k: 1)

    assert {:ok, prediction} = DSEx.call(rag, %{question: "capital France"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1
    assert [%{text: "France has capital Paris"}] = prediction.metadata.retrieval.docs
  end

  test "rag query selectors resolve equivalent atom and string input keys" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}
    base = DSEx.predict("question, context -> answer", lm: lm)

    parent = self()

    retriever = fn query, _opts ->
      send(parent, {:retrieved_query, query})
      {:ok, [%{text: "doc for #{query}"}]}
    end

    assert {:ok, _prediction} =
             base
             |> DSEx.rag(retriever, query_field: "question", k: 1)
             |> DSEx.call(%{question: "capital"})

    assert_receive {:retrieved_query, "capital"}

    assert {:ok, _prediction} =
             base
             |> DSEx.rag(retriever, query_field: :question, k: 1)
             |> DSEx.call(%{"question" => "capital"})

    assert_receive {:retrieved_query, "capital"}

    assert {:ok, _prediction} =
             base
             |> DSEx.rag(retriever, query_field: ["question", :topic], k: 1)
             |> DSEx.call(%{"topic" => "France", question: "capital"})

    assert_receive {:retrieved_query, "capital France"}
  end

  test "rag treats zero k as explicit no documents and rejects negative k" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "unknown"} end]
    }

    base = DSEx.predict("question, context -> answer", lm: lm)
    retriever = DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1)
    rag = DSEx.rag(base, retriever, k: 0)

    assert rag.k == 0
    assert {:ok, prediction} = DSEx.call(rag, %{question: "capital France"})
    assert prediction.metadata.retrieval.count == 0
    assert prediction.metadata.retrieval.docs == []

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RAG\.new\/3: invalid value for :k option: expected non negative integer/,
                 fn ->
                   DSEx.rag(base, retriever, k: -3)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RAG\.new\/3: invalid value for :query_field option: expected an atom\/string field name or a non-empty list of field names/,
                 fn ->
                   DSEx.rag(base, retriever, query_field: [])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RAG\.new\/3: invalid value for :context_field option: expected an atom\/string field name/,
                 fn ->
                   DSEx.rag(base, retriever, context_field: [:context])
                 end
  end

  test "rag reports invalid and failed wrapped program results without crashing" do
    retriever = DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}])

    invalid = DSEx.rag(%InvalidPredictionProgram{}, retriever, k: 1)

    assert {:error,
            {:invalid_module_prediction, PublicSurfaceTest.InvalidPredictionProgram,
             "%{answer: \"not a prediction\"}"}} =
             DSEx.call(invalid, %{question: "capital France"})

    failed = DSEx.rag(%ErrorProgram{}, retriever, k: 1)

    assert {:error, :wrapped_failed} = DSEx.call(failed, %{question: "capital France"})
  end

  test "rag reports invalid options inputs and retrieved docs clearly" do
    base = DSEx.predict("question, context -> answer", lm: %{module: DSEx.LM.Static, opts: []})
    retriever = DSEx.Retrieve.Memory.new([%{text: "France has capital Paris"}])

    assert_raise ArgumentError, ~r/DSEx\.Predict\.RAG\.new\/3: expected keyword options/, fn ->
      DSEx.rag(base, retriever, :not_options)
    end

    rag = DSEx.rag(base, retriever)

    assert {:error, {:invalid_rag_inputs, message}} = DSEx.Predict.RAG.call(rag, :not_inputs)
    assert message =~ "expected a map or field pair list"

    assert {:error, {:invalid_rag_inputs, "expected inputs as {key, value} pairs"}} =
             DSEx.Predict.RAG.call(rag, [:not_a_pair])

    bad_doc_rag = DSEx.rag(base, fn _query, _opts -> {:ok, [:not_a_doc]} end)

    assert {:error, {:invalid_retriever_document, :not_a_doc}} =
             DSEx.Predict.RAG.call(bad_doc_rag, %{question: "capital France"})

    bad_pair_doc_rag = DSEx.rag(base, fn _query, _opts -> {:ok, [[:not_a_pair]]} end)

    assert {:error, {:invalid_retriever_document, [:not_a_pair]}} =
             DSEx.Predict.RAG.call(bad_pair_doc_rag, %{question: "capital France"})
  end

  test "react and code act execute operational loops" do
    react_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "pong"}}]}
        end
      ]
    }

    agent = DSEx.react("question -> answer", [], lm: react_lm, max_iters: 2)
    assert {:ok, pred} = DSEx.Predict.ReAct.call(agent, %{question: "ping"})
    assert DSEx.Prediction.get(pred, :answer) == "pong"

    pot_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "n * n"} end]
    }

    code_act = DSEx.code_act("n -> answer", [], lm: pot_lm)
    assert {:ok, code_pred} = DSEx.Predict.CodeAct.call(code_act, %{n: 5})
    assert DSEx.Prediction.get(code_pred, :answer) == 25
  end

  test "program of thought and code act default computed values to the task output field" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "n * 2"} end]
    }

    pot = DSEx.program_of_thought("n -> doubled", lm: lm)
    assert {:ok, pot_pred} = DSEx.call(pot, %{n: 3})
    assert DSEx.Prediction.get(pot_pred, :doubled) == 6
    refute Map.has_key?(DSEx.Prediction.to_map(pot_pred), :answer)

    code_act = DSEx.code_act("n -> doubled", [], lm: lm)
    assert {:ok, code_pred} = DSEx.call(code_act, %{n: 3})
    assert DSEx.Prediction.get(code_pred, :doubled) == 6
    refute Map.has_key?(DSEx.Prediction.to_map(code_pred), :answer)

    assert_raise ArgumentError, ~r/:output_field must be one of the signature outputs/, fn ->
      DSEx.program_of_thought("n -> doubled", lm: lm, output_field: :answer)
    end
  end

  test "optimizer public surface composes programs" do
    metric = DSEx.Metrics.exact_match(:answer)
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.with_inputs(:question),
      DSEx.example(question: "sqrt 16?", answer: "4")
      |> DSEx.with_inputs(:question)
    ]

    knn =
      DSEx.Optimizer.KNNFewShot.new(1, trainset)
      |> DSEx.Optimizer.KNNFewShot.compile(program)

    assert {:ok, knn_pred} = DSEx.Optimizer.KNNFewShot.Program.call(knn, %{question: "2+2?"})
    assert knn_pred.metadata.knn_few_shot.demo_count == 1
    assert [demo] = knn_pred.metadata.knn_few_shot.demos
    assert DSEx.Example.get(demo, :question) == "2+2?"

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

  test "knn few-shot reports retrieval failures and rejects negative k" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    assert_raise ArgumentError,
                 ~r/DSEx\.Retrievers\.KNN\.new\/2 expects examples to be an enumerable/,
                 fn ->
                   DSEx.Optimizer.KNNFewShot.new(1, :not_an_enumerable_trainset)
                 end

    empty =
      DSEx.Optimizer.KNNFewShot.new(0, [
        DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)
      ])
      |> DSEx.Optimizer.KNNFewShot.compile(program)

    assert {:ok, prediction} = DSEx.Optimizer.KNNFewShot.Program.call(empty, %{question: "2+2?"})
    assert prediction.metadata.knn_few_shot.demo_count == 0

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.KNNFewShot\.new\/3 expects k to be a non-negative integer/,
                 fn ->
                   DSEx.Optimizer.KNNFewShot.new(-2, [
                     DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)
                   ])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.KNNFewShot\.new\/3: invalid value for :field option: expected an atom\/string field name or a non-empty list of field names/,
                 fn ->
                   DSEx.Optimizer.KNNFewShot.new(
                     1,
                     [
                       DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)
                     ],
                     field: ""
                   )
                 end
  end

  test "ensemble captures child failures and reducer failures as structured results" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    ensemble =
      DSEx.Optimizer.Ensemble.new()
      |> DSEx.Optimizer.Ensemble.compile([program, %ExplodingProgram{}])

    assert {:ok, prediction} =
             DSEx.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert [{:ok, %DSEx.Prediction{}}, {:error, {:ensemble_program_failed, "program exploded"}}] =
             DSEx.Prediction.get(prediction, :outputs)

    reducer =
      DSEx.Optimizer.Ensemble.new(reduce_fn: fn _predictions -> raise "reducer exploded" end)
      |> DSEx.Optimizer.Ensemble.compile([program])

    assert {:error, {:ensemble_reduce_failed, "reducer exploded", [{:ok, %DSEx.Prediction{}}]}} =
             DSEx.Optimizer.Ensemble.Program.call(reducer, %{question: "2+2?"})
  end

  test "composition optimizer constructors reject invalid boundary contracts" do
    metric = DSEx.Metrics.exact_match(:answer)

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.Ensemble\.new\/1: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.Ensemble.new(%{size: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.Ensemble\.new\/1: invalid value for :reduce_fn option: expected nil or an arity-1 function/,
                 fn ->
                   DSEx.Optimizer.Ensemble.new(reduce_fn: fn -> %{} end)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.Ensemble\.new\/1: .*:size.*non negative integer/s,
                 fn ->
                   DSEx.Optimizer.Ensemble.new(size: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.Ensemble\.compile\/2 expects an enumerable of programs/,
                 fn ->
                   DSEx.Optimizer.Ensemble.new() |> DSEx.Optimizer.Ensemble.compile(:not_programs)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.SignatureOptimizer\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.SignatureOptimizer.new(metric, %{candidates: []})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.SignatureOptimizer\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   DSEx.Optimizer.SignatureOptimizer.new(fn _example -> true end)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BetterTogether\.new\/2 expects optimizers to be an enumerable of key\/value pairs/,
                 fn ->
                   DSEx.Optimizer.BetterTogether.new(metric, :not_optimizers)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BetterTogether\.new\/2 expects a metric function with arity 2/,
                 fn ->
                   DSEx.Optimizer.BetterTogether.new(fn _example, _prediction, _trace -> true end)
                 end

    better = DSEx.Optimizer.BetterTogether.new(metric, %{p: DSEx.Optimizer.LabeledFewShot.new()})

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BetterTogether\.compile\/5: expected keyword options/,
                 fn ->
                   lm = %{
                     module: DSEx.LM.Static,
                     opts: [handler: fn _messages, _opts -> %{answer: "4"} end]
                   }

                   program = DSEx.predict("question -> answer", lm: lm)

                   DSEx.Optimizer.BetterTogether.compile(better, program, [], [], %{
                     strategy: "p"
                   })
                 end
  end

  test "ensemble reducer can return plain prediction fields" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    ensemble =
      DSEx.Optimizer.Ensemble.new(reduce_fn: fn _predictions -> %{answer: "4"} end)
      |> DSEx.Optimizer.Ensemble.compile([program])

    assert {:ok, prediction} =
             DSEx.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert DSEx.Prediction.get(prediction, :answer) == "4"
  end

  test "evaluation metrics, auto-evaluation, streaming messages, datasets, cache, and core structs work" do
    assert DSEx.Metrics.em("The Answer!", ["answer"])
    assert DSEx.Metrics.f1("red blue", "red green") > 0

    lm = %{
      module: DSEx.LM.Static,
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

    listener =
      %DSEx.Streaming.Messages.StreamListener{}
      |> DSEx.Streaming.Messages.StreamListener.record(:chunk)

    assert listener.events == [:chunk]

    assert %DSEx.Streaming.Messages.StreamResponse{chunk: "ok", done: true} =
             %DSEx.Streaming.Messages.StreamResponse{chunk: "ok", done: true}

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
    assert Enum.all?(@public_modules, &Code.ensure_loaded?/1)

    facade_exports = [
      configure: 1,
      settings: 0,
      context: 2,
      signature: 1,
      signature: 2,
      example: 1,
      with_inputs: 2,
      inputs: 1,
      labels: 1,
      prediction: 1,
      to_map: 1,
      get: 2,
      get: 3,
      evaluate: 3,
      evaluate: 4,
      exact_match: 0,
      exact_match: 1,
      extractive_qa: 2,
      extractive_qa: 3,
      classification: 2,
      classification: 3,
      classification_report: 1,
      classification_report: 2,
      majority: 1,
      majority: 2,
      optimize: 3,
      optimize: 4,
      dump: 1,
      load: 1,
      save!: 2,
      load!: 1,
      predict: 1,
      predict: 2,
      with_demos: 2,
      chain_of_thought: 1,
      chain_of_thought: 2,
      memory: 1,
      memory: 2,
      retrieve: 2,
      retrieve: 3,
      rag: 2,
      rag: 3,
      react: 3,
      tool: 3,
      tool: 4,
      react: 2,
      program_of_thought: 1,
      program_of_thought: 2,
      code_act: 1,
      code_act: 2,
      code_act: 3,
      rlm: 1,
      rlm: 2,
      call: 2,
      req_llm: 1,
      req_llm: 2
    ]

    assert Enum.all?(facade_exports, fn {name, arity} ->
             function_exported?(DSEx, name, arity)
           end)

    assert %DSEx.Clients.ReqLLM{} = DSEx.req_llm("openai:gpt-test")

    assert %DSEx.Retrievers.HTTP{} = DSEx.Retrievers.HTTP.new("https://retriever.example")
    assert %DSEx.MCP.HTTPClient{} = DSEx.MCP.HTTPClient.new("https://mcp.example")

    assert %DSEx.MCP.StreamableHTTPClient{} =
             DSEx.MCP.StreamableHTTPClient.new("https://mcp.example")

    assert %DSEx.Clients.HTTPTrainer{} =
             DSEx.Clients.OpenAITrainer.new(training_file: "file-test")
  end

  test "documented product modules are deliberately included in the public surface" do
    public = MapSet.new(@public_modules)

    missing =
      :dsex
      |> Application.spec(:modules)
      |> Enum.filter(&dsex_module?/1)
      |> Enum.filter(&documented_module?/1)
      |> Enum.reject(&MapSet.member?(public, &1))
      |> Enum.sort()

    assert missing == []
  end

  test "public product modules are deliberately documented" do
    undocumented =
      @public_modules
      |> Enum.reject(&documented_module?/1)
      |> Enum.sort()

    assert undocumented == []
  end

  test "borrowed adapter aliases do not leak into the DSEx product surface" do
    borrowed_name = "BA" <> "ML"

    refute Code.ensure_loaded?(Module.concat(DSEx.Adapter, String.to_atom(borrowed_name)))

    docs =
      ["README.md" | Path.wildcard("docs/*.md")]
      |> Enum.map_join("\n", &File.read!/1)

    refute docs =~ borrowed_name
  end

  defp dsex_module?(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.DSEx")
  end

  defp documented_module?(module) do
    match?({:docs_v1, _, _, _, %{"en" => _}, _, _}, Code.fetch_docs(module))
  end
end
