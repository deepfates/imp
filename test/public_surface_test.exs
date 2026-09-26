defmodule PublicSurfaceTest do
  use ExUnit.Case

  @behavioral_modules [
    Imp,
    Imp.Adapter,
    Imp.Adapter.Chat,
    Imp.Adapter.JSON,
    Imp.Adapter.PlanFirst,
    Imp.Adapter.XML,
    Imp.Adapter.TwoStep,
    Imp.Adapter.Types,
    Imp.Adapter.Types.ToolCall,
    Imp.Adapter.Types.ToolCallResults,
    Imp.Adapter.Types.ToolCalls,
    Imp.Adapter.Types.ToolResult,
    Imp.Cache,
    Imp.Capabilities,
    Imp.Clients.DatabricksTrainer,
    Imp.Clients.HTTPTrainer,
    Imp.Clients.MLXLMTrainer,
    Imp.Clients.OpenAITrainer,
    Imp.Clients.ReinforcementSession,
    Imp.Clients.ReqLLM,
    Imp.Clients.ReqLLMBatch,
    Imp.Clients.Trainer,
    Imp.Clients.TrainingJob,
    Imp.Confidence,
    Imp.Confidence.Calibration,
    Imp.Confidence.Scoring,
    Imp.Confidence.Scoring.LinearBlend,
    Imp.Confidence.Scoring.Sigmoid,
    Imp.Confidence.Scoring.Threshold,
    Imp.Core,
    Imp.Core.Assistant,
    Imp.Core.Developer,
    Imp.Core.LMConfig,
    Imp.Core.LMRequest,
    Imp.Core.LMResponse,
    Imp.Core.Message,
    Imp.Core.System,
    Imp.Core.User,
    Imp.Datasets,
    Imp.Datasets.Colors,
    Imp.Datasets.DataLoader,
    Imp.Datasets.Dataset,
    Imp.Datasets.GSM8K,
    Imp.Datasets.HotPotQA,
    Imp.Datasets.MATH,
    Imp.Embeddings,
    Imp.Embeddings.BagOfWords,
    Imp.AdapterParseError,
    Imp.Assertion,
    Imp.Error,
    Imp.Errors,
    Imp.Execution,
    Imp.Execution.Authorization,
    Imp.Evaluate,
    Imp.Evaluate.CompleteAndGrounded,
    Imp.Evaluate.Result,
    Imp.Evaluate.SemanticF1,
    Imp.Example,
    Imp.ExternalCommand,
    Imp.ExternalCommand.Handle,
    Imp.HTTP,
    Imp.History,
    Imp.LM,
    Imp.LM.Result,
    Imp.LMError,
    Imp.LM.Static,
    Imp.Logprobs,
    Imp.MCP,
    Imp.MCP.OAuth,
    Imp.MCP.OAuth.Store,
    Imp.Metrics,
    Imp.Metrics.Result,
    Imp.Module,
    Imp.Observability,
    Imp.Observability.Inspection,
    Imp.Observability.ProgressSubscription,
    Imp.Observability.Status,
    Imp.Observability.Trace,
    Imp.Optimize.Anything,
    Imp.Optimize.Anything.Config,
    Imp.Optimize.Anything.Config.Engine,
    Imp.Optimize.Anything.Config.Merge,
    Imp.Optimize.Anything.Config.Refiner,
    Imp.Optimize.Anything.Config.Reflection,
    Imp.Optimize.Anything.Config.Tracking,
    Imp.Optimize.Anything.Result,
    Imp.Optimize.Anything.StructuredStrategy,
    Imp.Optimizer,
    Imp.Optimizer.Artifact,
    Imp.Optimizer.Avatar,
    Imp.Optimizer.Avatar.EvalResult,
    Imp.Optimizer.BetterTogether,
    Imp.Optimizer.BootstrapFewShot,
    Imp.Optimizer.BootstrapFewShotWithRandomSearch,
    Imp.Optimizer.BootstrapFinetune,
    Imp.Optimizer.BootstrapFewShotWithRandomSearch,
    Imp.Optimizer.COPRO,
    Imp.Optimizer.Ensemble,
    Imp.Optimizer.GEPA,
    Imp.Optimizer.GEPA.Adapter,
    Imp.Optimizer.GEPA.Acceptance,
    Imp.Optimizer.GEPA.Callback,
    Imp.Optimizer.GEPA.Candidate,
    Imp.Optimizer.GEPA.CandidateSelector,
    Imp.Optimizer.GEPA.ComBee,
    Imp.Optimizer.GEPA.ComBee.BatchController,
    Imp.Optimizer.GEPA.ComBee.BatchController.Options,
    Imp.Optimizer.GEPA.ComBee.BatchController.Report,
    Imp.Optimizer.GEPA.ComBee.BatchController.Trial,
    Imp.Optimizer.GEPA.ComBee.Options,
    Imp.Optimizer.GEPA.ComBee.Plan,
    Imp.Optimizer.GEPA.ComBee.Policy,
    Imp.Optimizer.GEPA.ComBee.Report,
    Imp.Optimizer.GEPA.ComponentFeedback,
    Imp.Optimizer.GEPA.ConfidenceAdapter,
    Imp.Optimizer.GEPA.Evaluation,
    Imp.Optimizer.GEPA.EvaluationCache,
    Imp.Optimizer.GEPA.EvaluationCache.Entry,
    Imp.Optimizer.GEPA.EvaluationCache.Backend,
    Imp.Optimizer.GEPA.EvaluationCache.Disk,
    Imp.Optimizer.GEPA.EvaluationCache.Memory,
    Imp.Optimizer.GEPA.EvaluationPolicy,
    Imp.Optimizer.GEPA.Frontier,
    Imp.Optimizer.GEPA.Merge,
    Imp.Optimizer.GEPA.ModuleSelector,
    Imp.Optimizer.GEPA.Pareto,
    Imp.Optimizer.GEPA.Result,
    Imp.Optimizer.GEPA.Stopper,
    Imp.Optimizer.GEPA.Stopper.State,
    Imp.Optimizer.GRPO,
    Imp.Optimizer.GRPO.Callback,
    Imp.Optimizer.InferRules,
    Imp.Optimizer.InstructionProposer,
    Imp.Optimizer.InstructionSearch,
    Imp.Optimizer.KNNFewShot,
    Imp.Optimizer.LabeledFewShot,
    Imp.Optimizer.MIPROv2,
    Imp.Optimizer.Component,
    Imp.Optimizer.Parameter,
    Imp.Optimizer.Parameter.Change,
    Imp.Optimizer.Parameter.Set,
    Imp.Optimizer.Playbook,
    Imp.Optimizer.Playbook.Result,
    Imp.Optimizer.Playbook.Usage,
    Imp.Optimizer.BootstrapFewShotWithRandomSearch,
    Imp.Optimizer.Report,
    Imp.Optimizer.Sampling,
    Imp.Optimizer.SIMBA,
    Imp.Optimizer.SignatureOptimizer,
    Imp.Optimizer.Trajectory,
    Imp.Optimizer.Trajectory.Cache,
    Imp.Optimizer.Trajectory.DecodeError,
    Imp.Optimizer.Trajectory.Event,
    Imp.Optimizer.Trajectory.Failure,
    Imp.Optimizer.Trajectory.Parameter,
    Imp.Optimizer.Trajectory.Timing,
    Imp.Optimizer.Trajectory.Usage,
    Imp.Optimizer.TrajectoryRunner,
    Imp.Optimizer.TrainingError,
    Imp.Optimizer.TrainingJobAdoption,
    Imp.Optimizer.TrainingResult,
    Imp.Playbook,
    Imp.Playbook.WithContext,
    Imp.Playbook.Delta,
    Imp.Playbook.Entry,
    Imp.Playbook.Operation.Add,
    Imp.Playbook.Operation.Merge,
    Imp.Playbook.Operation.Remove,
    Imp.Playbook.Operation.Revise,
    Imp.Playbook.Operation.UpdateCounters,
    Imp.Playbook.Policy,
    Imp.Playbook.Provenance,
    Imp.Playbook.Tombstone,
    Imp.Predict.Aggregation,
    Imp.Predict.Assertions,
    Imp.Predict.Avatar,
    Imp.Predict.Avatar.Action,
    Imp.Predict.Avatar.ActionOutput,
    Imp.Predict.BestOfN,
    Imp.Predict.ChainOfThought,
    Imp.Predict.CodeAct,
    Imp.Predict.KNN,
    Imp.Predict.MultiChainComparison,
    Imp.Predict.Parallel,
    Imp.Predict,
    Imp.Predict.ProgramOfThought,
    Imp.Predict.RAG,
    Imp.Predict.RLM,
    Imp.Predict.RLM.SandboxSerializable,
    Imp.Predict.ReAct,
    Imp.Predict.ReActV2,
    Imp.Predict.Refine,
    Imp.Predict.Search,
    Imp.Predict.Search.Candidate,
    Imp.Predict.Search.Result,
    Imp.Prediction,
    Imp.ProgramParameters,
    Imp.Redaction,
    Imp.Retrieve,
    Imp.Retrieve.Memory,
    Imp.Retrievers.Databricks,
    Imp.Retrievers.HTTP,
    Imp.Retrievers.Weaviate,
    Imp.Sandbox,
    Imp.Saving,
    Imp.Saving.Registry,
    Imp.Schema,
    Imp.Settings,
    Imp.Signature,
    Imp.Signature.Field,
    Imp.Streaming,
    Imp.Streaming.Messages,
    Imp.Streaming.Messages.StreamListener,
    Imp.Streaming.Messages.StreamResponse,
    Imp.Streaming.Messages.StatusMessage,
    Imp.Tasks,
    Imp.Telemetry,
    Imp.Tracking.Backend,
    Imp.Tracking.MLflow,
    Imp.Tracking.Session,
    Imp.Tracking.Transport,
    Imp.Tracking.Transport.Req,
    Imp.Tracking.WandB,
    Imp.Tracking.WandB.Backend,
    Imp.Tracking.WandB.Transport,
    Imp.Training.ChatDataset,
    Imp.Training.FastSlow.AdvantageGroup,
    Imp.Training.FastSlow.Backend,
    Imp.Training.FastSlow.Budget,
    Imp.Training.FastSlow.CachedTrajectory,
    Imp.Training.FastSlow.Checkpoint,
    Imp.Training.FastSlow.Config,
    Imp.Training.FastSlow.DatasetState,
    Imp.Training.FastSlow.Event,
    Imp.Training.FastSlow.Lookahead,
    Imp.Training.FastSlow.OperationIntent,
    Imp.Training.FastSlow.PromptPopulation,
    Imp.Training.FastSlow.ReuseCache,
    Imp.Training.FastSlow.Rollout,
    Imp.Training.FastSlow.Runner,
    Imp.Training.FastSlow.Runner.Context,
    Imp.Training.FastSlow.State,
    Imp.Training.FastSlow.Terminal,
    Imp.Training.FastSlow.Theta,
    Imp.Tool
  ]

  defmodule ExplodingProgram do
    @behaviour Imp.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs), do: raise("program exploded")
  end

  defmodule GuardedProgram do
    @behaviour Imp.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs) do
      {:error,
       Imp.OperationalSafetyError.exception(
         kind: :transport,
         message: "ensemble child transport guard"
       )}
    end
  end

  defmodule InvalidPredictionProgram do
    @behaviour Imp.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs), do: {:ok, %{answer: "not a prediction"}}
  end

  defmodule ErrorProgram do
    @behaviour Imp.Module
    defstruct []

    @impl true
    def call(%__MODULE__{}, _inputs), do: {:error, :wrapped_failed}
  end

  setup do
    Imp.configure(lm: nil, adapter: Imp.Adapter.Chat)
    # Restore global Imp.Settings to defaults on exit (test isolation). See dee-fqsr.
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  test "prediction public surface has executable equivalents" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4", rationale: "math"} end)

    program = Imp.predict("question -> answer", lm: lm)

    assert Imp.majority(["A", "a", "B"]) == "A"

    assert %Imp.Prediction{} =
             Imp.majority([
               Imp.Prediction.new(answer: "A"),
               Imp.Prediction.new(answer: "A"),
               Imp.Prediction.new(answer: "B")
             ])

    assert Imp.majority([%{"answer" => "Paris"}, %{answer: "paris"}, %{answer: "Lyon"}],
             field: :answer
           ) == "Paris"

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Aggregation\.majority\/2: expected keyword options/,
                 fn ->
                   Imp.majority(["A"], :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Aggregation\.majority\/2: invalid value for :normalize option: expected a unary function/,
                 fn ->
                   Imp.majority(["A"], normalize: :not_a_function)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Aggregation\.majority\/2: invalid value for :field option: expected nil or an atom\/string field name/,
                 fn ->
                   Imp.majority(["A"], field: [])
                 end

    assert {:ok, pred} = Imp.call(program, %{question: "2+2?"})
    assert Imp.get(pred, :answer) == "4"

    mcc = Imp.multi_chain_comparison("question -> answer", lm: lm, m: 2)

    assert {:ok, compared} =
             Imp.call(mcc, %{
               question: "2+2?",
               completions: [%{reasoning: "add", answer: "4"}, %{reasoning: "count", answer: "4"}]
             })

    assert Imp.get(compared, :answer) == "4"

    assert {:ok, compared_from_strings} =
             Imp.call(mcc, %{
               "question" => "2+2?",
               "completions" => [
                 %{"reasoning" => "add", "answer" => "4"},
                 Imp.Prediction.new(reasoning: "count", answer: "4")
               ]
             })

    assert Imp.get(compared_from_strings, :answer) == "4"

    assert {:error, {:invalid_completions, ~s("not-a-list")}} =
             Imp.call(mcc, %{
               question: "2+2?",
               completions: "not-a-list"
             })

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.MultiChainComparison\.new\/2: expected keyword options/,
                 fn ->
                   Imp.multi_chain_comparison("question -> answer", %{m: 2})
                 end

    assert {:error, {:invalid_multi_chain_inputs, message}} =
             Imp.call(mcc, :not_inputs)

    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_multi_chain_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.call(mcc, [:not_a_pair])

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.MultiChainComparison\.new\/2: invalid value for :m option: expected a positive integer/,
                 fn ->
                   Imp.multi_chain_comparison("question -> answer", lm: lm, m: 0)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.MultiChainComparison\.new\/2: invalid value for :M option: expected a positive integer/,
                 fn ->
                   Imp.multi_chain_comparison("question -> answer", lm: lm, M: "2")
                 end

    metric = Imp.exact_match(:answer)

    assert {:ok, best} =
             program
             |> Imp.best_of_n(metric, n: 2)
             |> Imp.call(%{question: "2+2?"})

    assert Imp.get(best, :answer) == "4"

    assert {:ok, refined} =
             program
             |> Imp.refine(metric, n: 1)
             |> Imp.call(%{question: "2+2?"})

    assert Imp.get(refined, :answer) == "4"
    assert [%{attempt: 1}] = Imp.get(refined, :refine_history)

    assert [{:ok, first}, {:ok, second}] =
             Imp.parallel(program, [%{question: "2+2?"}, %{question: "sqrt 16?"}], num_threads: 2)

    assert Enum.map([first, second], &Imp.get(&1, :answer)) == ["4", "4"]

    trainset = [
      Imp.example(question: "capital France", answer: "Paris") |> Imp.with_inputs(:question),
      Imp.example(question: "capital Germany", answer: "Berlin") |> Imp.with_inputs(:question)
    ]

    knn = Imp.knn(1, trainset, vectorizer: Imp.Embeddings.BagOfWords)
    assert [nearest] = Imp.nearest(knn, %{question: "France"})
    assert Imp.get(nearest, :answer) == "Paris"

    assert_raise ArgumentError, ~r/Imp.nearest\/2 expects an Imp KNN predictor/, fn ->
      Imp.nearest(program, %{question: "France"})
    end

    rlm_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: ~S|submit(%{answer: "4"})|} end)

    rlm = Imp.rlm("question, logs -> answer", lm: rlm_lm, max_iterations: 2)

    assert {:ok, rlm_pred} =
             Imp.Predict.RLM.call(rlm, %{question: "2+2?", logs: "large context"})

    assert Imp.Prediction.get(rlm_pred, :answer) == "4"
    assert [%{action: :submit}] = rlm_pred.metadata.rlm_trace
  end

  test "rag wraps a program with retrieved context and metadata" do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      )

    base = Imp.predict("question, context -> answer", lm: lm)
    retriever = Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}])
    rag = Imp.rag(base, retriever, k: 1)

    assert {:ok, prediction} = Imp.call(rag, %{question: "capital France"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1
    assert [%{text: "France has capital Paris"}] = prediction.metadata.retrieval.docs
  end

  test "rag query selectors resolve equivalent atom and string input keys" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
    base = Imp.predict("question, context -> answer", lm: lm)

    parent = self()

    retriever = fn query, _opts ->
      send(parent, {:retrieved_query, query})
      {:ok, [%{text: "doc for #{query}"}]}
    end

    assert {:ok, _prediction} =
             base
             |> Imp.rag(retriever, query_field: "question", k: 1)
             |> Imp.call(%{question: "capital"})

    assert_receive {:retrieved_query, "capital"}

    assert {:ok, _prediction} =
             base
             |> Imp.rag(retriever, query_field: :question, k: 1)
             |> Imp.call(%{"question" => "capital"})

    assert_receive {:retrieved_query, "capital"}

    assert {:ok, _prediction} =
             base
             |> Imp.rag(retriever, query_field: ["question", :topic], k: 1)
             |> Imp.call(%{"topic" => "France", question: "capital"})

    assert_receive {:retrieved_query, "capital France"}
  end

  test "rag treats zero k as explicit no documents and rejects negative k" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "unknown"} end)

    base = Imp.predict("question, context -> answer", lm: lm)
    retriever = Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1)
    rag = Imp.rag(base, retriever, k: 0)

    assert rag.k == 0
    assert {:ok, prediction} = Imp.call(rag, %{question: "capital France"})
    assert prediction.metadata.retrieval.count == 0
    assert prediction.metadata.retrieval.docs == []

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RAG\.new\/3: invalid value for :k option: expected non negative integer/,
                 fn ->
                   Imp.rag(base, retriever, k: -3)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RAG\.new\/3: invalid value for :query_field option: expected an atom\/string field name or a non-empty list of field names/,
                 fn ->
                   Imp.rag(base, retriever, query_field: [])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RAG\.new\/3: invalid value for :context_field option: expected an atom\/string field name/,
                 fn ->
                   Imp.rag(base, retriever, context_field: [:context])
                 end
  end

  test "rag can perform multi-hop retrieval by expanding the query with prior passages" do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "The Eiffel Tower is in Paris." and
               prompt =~ "Paris is the capital of France.",
             do: %{answer: "France"},
             else: %{answer: "unknown"}
        end
      )

    base = Imp.predict("question, context -> answer", lm: lm)
    parent = self()

    retriever = fn query, opts ->
      send(parent, {:retrieval_hop, query, opts[:k]})

      cond do
        query =~ "Paris" ->
          {:ok, [%{id: "answer", text: "Paris is the capital of France."}]}

        query =~ "Eiffel" ->
          {:ok, [%{id: "bridge", text: "The Eiffel Tower is in Paris."}]}

        true ->
          {:ok, []}
      end
    end

    rag = Imp.rag(base, retriever, k: 1, hops: 2)

    assert {:ok, prediction} =
             Imp.call(rag, %{question: "Which country has the capital of Eiffel's city?"})

    assert Imp.get(prediction, :answer) == "France"
    assert prediction.metadata.retrieval.count == 2
    assert Enum.map(prediction.metadata.retrieval.docs, & &1.id) == ["bridge", "answer"]
    assert Enum.map(prediction.metadata.retrieval.hops, & &1.count) == [1, 1]

    assert_receive {:retrieval_hop, first_query, 1}
    assert first_query =~ "Eiffel"
    refute first_query =~ "Paris"

    assert_receive {:retrieval_hop, second_query, 1}
    assert second_query =~ "Eiffel"
    assert second_query =~ "The Eiffel Tower is in Paris."
  end

  test "rag reports invalid and failed wrapped program results without crashing" do
    retriever = Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}])

    invalid = Imp.rag(%InvalidPredictionProgram{}, retriever, k: 1)

    assert {:error,
            {:invalid_module_prediction, PublicSurfaceTest.InvalidPredictionProgram,
             "%{answer: \"not a prediction\"}"}} =
             Imp.call(invalid, %{question: "capital France"})

    failed = Imp.rag(%ErrorProgram{}, retriever, k: 1)

    assert {:error, :wrapped_failed} = Imp.call(failed, %{question: "capital France"})
  end

  test "rag reports invalid options inputs and retrieved docs clearly" do
    base = Imp.predict("question, context -> answer", lm: Imp.LM.Static.new())
    retriever = Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}])

    assert_raise ArgumentError, ~r/Imp\.Predict\.RAG\.new\/3: expected keyword options/, fn ->
      Imp.rag(base, retriever, :not_options)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RAG\.new\/3: invalid value for :hops option: expected positive integer/,
                 fn ->
                   Imp.rag(base, retriever, hops: 0)
                 end

    rag = Imp.rag(base, retriever)

    assert {:error, {:invalid_rag_inputs, message}} = Imp.Predict.RAG.call(rag, :not_inputs)
    assert message =~ "expected a map or field pair list"

    assert {:error, {:invalid_rag_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.Predict.RAG.call(rag, [:not_a_pair])

    bad_doc_rag = Imp.rag(base, fn _query, _opts -> {:ok, [:not_a_doc]} end)

    assert {:error, {:invalid_retriever_document, :not_a_doc}} =
             Imp.Predict.RAG.call(bad_doc_rag, %{question: "capital France"})

    bad_pair_doc_rag = Imp.rag(base, fn _query, _opts -> {:ok, [[:not_a_pair]]} end)

    assert {:error, {:invalid_retriever_document, [:not_a_pair]}} =
             Imp.Predict.RAG.call(bad_pair_doc_rag, %{question: "capital France"})
  end

  test "react and code act execute operational loops" do
    react_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "pong"}}]}
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: react_lm, max_iters: 2)
    assert {:ok, pred} = Imp.Predict.ReAct.call(agent, %{question: "ping"})
    assert Imp.Prediction.get(pred, :answer) == "pong"

    pot_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{program: "n * n"} end)

    code_act = Imp.code_act("n -> answer", [], lm: pot_lm)
    assert {:ok, code_pred} = Imp.Predict.CodeAct.call(code_act, %{n: 5})
    assert Imp.Prediction.get(code_pred, :answer) == 25
  end

  test "program of thought and code act default computed values to the task output field" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{program: "n * 2"} end)

    pot = Imp.program_of_thought("n -> doubled", lm: lm)
    assert {:ok, pot_pred} = Imp.call(pot, %{n: 3})
    assert Imp.Prediction.get(pot_pred, :doubled) == 6
    refute Map.has_key?(Imp.Prediction.to_map(pot_pred), :answer)

    code_act = Imp.code_act("n -> doubled", [], lm: lm)
    assert {:ok, code_pred} = Imp.call(code_act, %{n: 3})
    assert Imp.Prediction.get(code_pred, :doubled) == 6
    refute Map.has_key?(Imp.Prediction.to_map(code_pred), :answer)

    assert_raise ArgumentError, ~r/:output_field must be one of the signature outputs/, fn ->
      Imp.program_of_thought("n -> doubled", lm: lm, output_field: :answer)
    end
  end

  test "optimizer public surface composes programs" do
    metric = Imp.Metrics.exact_match(:answer)
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)
    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "2+2?", answer: "4")
      |> Imp.with_inputs(:question),
      Imp.example(question: "sqrt 16?", answer: "4")
      |> Imp.with_inputs(:question)
    ]

    knn =
      Imp.Optimizer.KNNFewShot.new(1, trainset, vectorizer: Imp.Embeddings.BagOfWords)
      |> Imp.Optimizer.KNNFewShot.compile(program)

    assert {:ok, knn_pred} = Imp.Optimizer.KNNFewShot.Program.call(knn, %{question: "2+2?"})
    assert knn_pred.metadata.knn_few_shot.demo_count == 1
    assert [demo] = knn_pred.metadata.knn_few_shot.demos
    assert Imp.Example.get(demo, :question) == "2+2?"

    ensemble =
      Imp.Optimizer.Ensemble.new(
        reduce_fn: fn preds ->
          Imp.Prediction.new(answer: Imp.Predict.Aggregation.majority(preds, field: :answer))
        end
      )
      |> Imp.Optimizer.Ensemble.compile([program, program])

    assert {:ok, ens_pred} =
             Imp.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert Imp.Prediction.get(ens_pred, :answer) == "4"

    better =
      Imp.Optimizer.BetterTogether.new(metric, %{
        p: Imp.Optimizer.LabeledFewShot.new(k: 1)
      })

    compiled =
      Imp.Optimizer.BetterTogether.compile(better, program, trainset, trainset, strategy: "p")

    assert {:ok, _} = Imp.Predict.call(compiled, %{question: "2+2?"})
  end

  test "knn few-shot reports retrieval failures and rejects negative k" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)
    program = Imp.predict("question -> answer", lm: lm)

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.KNN\.new\/3 expects trainset to be an enumerable/,
                 fn ->
                   Imp.Optimizer.KNNFewShot.new(1, :not_an_enumerable_trainset,
                     vectorizer: Imp.Embeddings.BagOfWords
                   )
                 end

    empty =
      Imp.Optimizer.KNNFewShot.new(
        0,
        [Imp.example(question: "2+2?", answer: "4") |> Imp.with_inputs(:question)],
        vectorizer: Imp.Embeddings.BagOfWords
      )
      |> Imp.Optimizer.KNNFewShot.compile(program)

    assert {:ok, prediction} = Imp.Optimizer.KNNFewShot.Program.call(empty, %{question: "2+2?"})
    assert prediction.metadata.knn_few_shot.demo_count == 0

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.KNN\.new\/3 expects k to be a non-negative integer/,
                 fn ->
                   Imp.Optimizer.KNNFewShot.new(
                     -2,
                     [Imp.example(question: "2+2?", answer: "4") |> Imp.with_inputs(:question)],
                     vectorizer: Imp.Embeddings.BagOfWords
                   )
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.KNNFewShot\.new\/3: required :vectorizer option not found/,
                 fn ->
                   Imp.Optimizer.KNNFewShot.new(1, [
                     Imp.example(question: "2+2?", answer: "4") |> Imp.with_inputs(:question)
                   ])
                 end
  end

  test "ensemble captures child failures and reducer failures as structured results" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)
    program = Imp.predict("question -> answer", lm: lm)

    ensemble =
      Imp.Optimizer.Ensemble.new()
      |> Imp.Optimizer.Ensemble.compile([program, %ExplodingProgram{}])

    assert {:ok, prediction} =
             Imp.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert [
             {:ok, %Imp.Prediction{}},
             {:error, {:ensemble_program_failed, %RuntimeError{message: "program exploded"}}}
           ] =
             Imp.Prediction.get(prediction, :outputs)

    reducer =
      Imp.Optimizer.Ensemble.new(reduce_fn: fn _predictions -> raise "reducer exploded" end)
      |> Imp.Optimizer.Ensemble.compile([program])

    assert {:error,
            {:ensemble_reduce_failed, %RuntimeError{message: "reducer exploded"},
             [{:ok, %Imp.Prediction{}}]}} =
             Imp.Optimizer.Ensemble.Program.call(reducer, %{question: "2+2?"})
  end

  test "ensemble preserves operational safety through children and reducers" do
    guarded_child =
      Imp.Optimizer.Ensemble.new()
      |> Imp.Optimizer.Ensemble.compile([%GuardedProgram{}])

    assert_raise Imp.OperationalSafetyError, "ensemble child transport guard", fn ->
      Imp.Optimizer.Ensemble.Program.call(guarded_child, %{question: "2+2?"})
    end

    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)
      )

    guarded_reducer =
      Imp.Optimizer.Ensemble.new(
        reduce_fn: fn _predictions ->
          {:error,
           Imp.OperationalSafetyError.exception(
             kind: :cost,
             message: "ensemble reducer cost guard"
           )}
        end
      )
      |> Imp.Optimizer.Ensemble.compile([program])

    assert_raise Imp.OperationalSafetyError, "ensemble reducer cost guard", fn ->
      Imp.Optimizer.Ensemble.Program.call(guarded_reducer, %{question: "2+2?"})
    end
  end

  test "composition optimizer constructors reject invalid boundary contracts" do
    metric = Imp.Metrics.exact_match(:answer)

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.Ensemble\.new\/1: expected keyword options/,
                 fn ->
                   Imp.Optimizer.Ensemble.new(%{size: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.Ensemble\.new\/1: invalid value for :reduce_fn option: expected nil or an arity-1 function/,
                 fn ->
                   Imp.Optimizer.Ensemble.new(reduce_fn: fn -> %{} end)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.Ensemble\.new\/1: .*:size.*non negative integer/s,
                 fn ->
                   Imp.Optimizer.Ensemble.new(size: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.Ensemble\.compile\/2 expects an enumerable of programs/,
                 fn ->
                   Imp.Optimizer.Ensemble.new() |> Imp.Optimizer.Ensemble.compile(:not_programs)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.SignatureOptimizer\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.SignatureOptimizer.new(metric, %{candidates: []})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.SignatureOptimizer\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Optimizer.SignatureOptimizer.new(fn _example -> true end)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.new\/2 expects optimizers to be an enumerable of key\/value pairs/,
                 fn ->
                   Imp.Optimizer.BetterTogether.new(metric, :not_optimizers)
                 end

    assert %Imp.Optimizer.BetterTogether{} =
             Imp.Optimizer.BetterTogether.new(fn _example, _prediction, _trace -> true end)

    better = Imp.Optimizer.BetterTogether.new(metric, %{p: Imp.Optimizer.LabeledFewShot.new()})

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: expected keyword options/,
                 fn ->
                   lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)

                   program = Imp.predict("question -> answer", lm: lm)

                   Imp.Optimizer.BetterTogether.compile(better, program, [], [], %{
                     strategy: "p"
                   })
                 end
  end

  test "ensemble reducer can return plain prediction fields" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "4"} end)
    program = Imp.predict("question -> answer", lm: lm)

    ensemble =
      Imp.Optimizer.Ensemble.new(reduce_fn: fn _predictions -> %{answer: "4"} end)
      |> Imp.Optimizer.Ensemble.compile([program])

    assert {:ok, prediction} =
             Imp.Optimizer.Ensemble.Program.call(ensemble, %{question: "2+2?"})

    assert Imp.Prediction.get(prediction, :answer) == "4"
  end

  test "evaluation metrics, auto-evaluation, streaming messages, datasets, cache, and core structs work" do
    assert Imp.Metrics.em("The Answer!", ["answer"])
    assert Imp.Metrics.f1("red blue", "red green") > 0

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{reasoning: "judge", precision: 1, recall: 1, f1: 1, completeness: 1, groundedness: 1}
        end
      )

    assert {:ok, sem} =
             Imp.Evaluate.SemanticF1.new(lm: lm)
             |> Imp.Evaluate.SemanticF1.call(%{
               question: "q",
               ground_truth: "a",
               system_response: "a"
             })

    assert Imp.Prediction.get(sem, :f1) == 1

    assert %Imp.Streaming.Messages.StatusMessage{message: "ok"} =
             %Imp.Streaming.Messages.StatusMessage{message: "ok"}

    listener =
      %Imp.Streaming.Messages.StreamListener{}
      |> Imp.Streaming.Messages.StreamListener.record(:chunk)

    assert listener.events == [:chunk]

    assert %Imp.Streaming.Messages.StreamResponse{chunk: "ok", done: true} =
             %Imp.Streaming.Messages.StreamResponse{chunk: "ok", done: true}

    examples =
      Imp.Datasets.Colors.load!([
        %{input: "red", label: "warm"},
        %{input: "blue", label: "cool"}
      ])

    dataset = Imp.Datasets.Dataset.new(examples, train: 0.5)
    assert length(dataset.train) == 1

    assert Imp.Cache.put(:x, 42) == 42
    assert Imp.Cache.get(:x) == 42

    assert %Imp.Core.LMRequest{messages: [%Imp.Core.User{content: "hi"}]}
  end

  test "documented public modules and facade constructors remain available" do
    assert Enum.all?(@behavioral_modules, &Code.ensure_loaded?/1)

    assert Enum.all?(manifest_public_modules(), &Code.ensure_loaded?/1)

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
      with_lm: 2,
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
      avatar: 2,
      avatar: 3,
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
      rlm_serializable: 2,
      rlm_serializable: 3,
      call: 2,
      start_optimizer_budget: 1,
      budgeted_lm: 2,
      budgeted_lm: 3,
      req_llm: 1,
      req_llm: 2
    ]

    assert Enum.all?(facade_exports, fn {name, arity} ->
             function_exported?(Imp, name, arity)
           end)

    assert %Imp.Clients.ReqLLM{} = Imp.req_llm("openai:gpt-test")

    assert %Imp.Retrievers.HTTP{} = Imp.Retrievers.HTTP.new("https://retriever.example")
    assert {:ok, %Imp.MCP.Import{tools: [], cleanup: cleanup}} = Imp.MCP.connect([])
    assert :ok = cleanup.()

    assert %Imp.Clients.HTTPTrainer{} =
             Imp.Clients.OpenAITrainer.new(training_file: "file-test")
  end

  test "documented product modules are deliberately included in the public surface" do
    public = MapSet.new(manifest_public_modules())

    assert Enum.all?(public, fn module ->
             imp_module?(module) and documented_module?(module)
           end)

    assert Enum.all?(Mix.Tasks.Imp.PublicApi.manifest()["modules"], fn entry ->
             entry["category"] != "internal"
           end)
  end

  test "public product modules are deliberately documented" do
    undocumented =
      manifest_public_modules()
      |> Enum.reject(&documented_module?/1)
      |> Enum.sort()

    assert undocumented == []
  end

  test "borrowed adapter aliases do not leak into the Imp product surface" do
    borrowed_name = "BA" <> "ML"

    refute Code.ensure_loaded?(Module.concat(Imp.Adapter, String.to_atom(borrowed_name)))

    docs =
      ["README.md" | Path.wildcard("docs/**/*.md")]
      |> Enum.reject(
        # These documents exist to NAME other systems: prior art, the research
        # landscape, and the upstream exam (which must account for every
        # upstream test, including adapters we deliberately do not ship).
        &(&1 in [
            "README.md",
            "docs/differentials/RESEARCH_LANDSCAPE.md",
            "docs/differentials/UPSTREAM_EXAM.md"
          ])
      )
      |> Enum.map_join("\n", &File.read!/1)

    refute docs =~ borrowed_name
  end

  defp imp_module?(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Imp")
  end

  defp manifest_public_modules do
    Mix.Tasks.Imp.PublicApi.manifest()["modules"]
    |> Enum.map(&module_from_string(&1["module"]))
  end

  defp module_from_string(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end

  defp documented_module?(module) do
    match?({:docs_v1, _, _, _, %{"en" => _}, _, _}, Code.fetch_docs(module))
  end
end
