defmodule DSEx.UpstreamFidelity do
  @moduledoc false

  @source_anchors %{
    dspy_docs: "https://dspy.ai/",
    dspy_rlm: "https://dspy.ai/diving-deeper/rlm/",
    deepwiki: "https://deepwiki.com/stanfordnlp/dspy",
    dspy_paper: "arXiv:2310.03714",
    dsp_paper: "arXiv:2212.14024",
    assertions_paper: "arXiv:2312.13382",
    mipro_v2_paper: "arXiv:2406.11695",
    gepa_paper: "arXiv:2507.19457",
    rlm_paper: "arXiv:2512.24601",
    optimize_anything_paper: "arXiv:2605.19633",
    gepa_repo: "https://github.com/gepa-ai/gepa"
  }

  @surfaces [
    %{category: :adapters, name: "Adapter", tokens: ["DSEx.Adapter"]},
    %{category: :adapters, name: "ChatAdapter", tokens: ["DSEx.Adapter.Chat"]},
    %{category: :adapters, name: "JSONAdapter", tokens: ["DSEx.Adapter.JSON"]},
    %{category: :adapters, name: "XMLAdapter", tokens: ["DSEx.Adapter.XML"]},
    %{category: :adapters, name: "TwoStepAdapter", tokens: ["DSEx.Adapter.TwoStep"]},
    %{category: :evaluation, name: "CompleteAndGrounded", tokens: ["CompleteAndGrounded"]},
    %{category: :evaluation, name: "Evaluate", tokens: ["DSEx.Evaluate"]},
    %{category: :evaluation, name: "EvaluationResult", tokens: ["EvaluationResult", "Report"]},
    %{category: :evaluation, name: "SemanticF1", tokens: ["SemanticF1"]},
    %{category: :evaluation, name: "answer_exact_match", tokens: ["exact_match"]},
    %{category: :evaluation, name: "answer_passage_match", tokens: ["extractive_qa"]},
    %{category: :experimental, name: "Citations", tokens: ["Citation"]},
    %{category: :experimental, name: "Document", tokens: ["Document"]},
    %{category: :models, name: "BaseLM", tokens: ["BaseLM", "typed LM"]},
    %{category: :models, name: "Embedder", tokens: ["Embeddings", "Embedder"]},
    %{category: :models, name: "LM", tokens: ["DSEx.LM", "ReqLLM"]},
    %{category: :modules, name: "BestOfN", tokens: ["BestOfN"]},
    %{category: :modules, name: "ChainOfThought", tokens: ["ChainOfThought"]},
    %{category: :modules, name: "CodeAct", tokens: ["CodeAct"]},
    %{category: :modules, name: "Module", tokens: ["DSEx.Module"]},
    %{category: :modules, name: "MultiChainComparison", tokens: ["MultiChainComparison"]},
    %{category: :modules, name: "Parallel", tokens: ["Parallel"]},
    %{category: :modules, name: "Predict", tokens: ["Predict"]},
    %{category: :modules, name: "ProgramOfThought", tokens: ["ProgramOfThought"]},
    %{category: :modules, name: "ReAct", tokens: ["ReAct"]},
    %{category: :modules, name: "ReActV2", tokens: ["ReActV2", "de-3uxx"]},
    %{category: :modules, name: "Refine", tokens: ["Refine"]},
    %{category: :modules, name: "RLM", tokens: ["RLM"]},
    %{category: :optimizers, name: "BetterTogether", tokens: ["BetterTogether"]},
    %{category: :optimizers, name: "BootstrapFewShot", tokens: ["BootstrapFewShot"]},
    %{
      category: :optimizers,
      name: "BootstrapFewShotWithRandomSearch",
      tokens: ["BootstrapFewShotWithRandomSearch", "RandomSearch"]
    },
    %{category: :optimizers, name: "BootstrapFinetune", tokens: ["BootstrapFinetune"]},
    %{category: :optimizers, name: "BootstrapRS", tokens: ["BootstrapRS", "RandomSearch"]},
    %{category: :optimizers, name: "COPRO", tokens: ["COPRO"]},
    %{category: :optimizers, name: "Ensemble", tokens: ["Ensemble"]},
    %{category: :optimizers, name: "GEPA", tokens: ["GEPA"]},
    %{category: :optimizers, name: "InferRules", tokens: ["InferRules", "de-9x31"]},
    %{category: :optimizers, name: "KNN", tokens: ["KNN"]},
    %{category: :optimizers, name: "KNNFewShot", tokens: ["KNNFewShot"]},
    %{category: :optimizers, name: "LabeledFewShot", tokens: ["LabeledFewShot"]},
    %{category: :optimizers, name: "MIPROv2", tokens: ["MIPROv2"]},
    %{category: :optimizers, name: "SIMBA", tokens: ["SIMBA"]},
    %{category: :primitives, name: "Audio", tokens: ["Audio"]},
    %{category: :primitives, name: "Code", tokens: ["Code"]},
    %{category: :primitives, name: "Example", tokens: ["DSEx.Example"]},
    %{category: :primitives, name: "History", tokens: ["History"]},
    %{category: :primitives, name: "Image", tokens: ["Image"]},
    %{category: :primitives, name: "Prediction", tokens: ["DSEx.Prediction"]},
    %{category: :primitives, name: "Tool", tokens: ["DSEx.Tool"]},
    %{category: :primitives, name: "ToolCalls", tokens: ["ToolCalls"]},
    %{category: :signatures, name: "InputField", tokens: ["InputField", "Signature.Field"]},
    %{category: :signatures, name: "OutputField", tokens: ["OutputField", "Signature.Field"]},
    %{category: :signatures, name: "Signature", tokens: ["DSEx.Signature"]},
    %{category: :tools, name: "ColBERTv2", tokens: ["ColBERTv2", "de-c2we"]},
    %{category: :tools, name: "Embeddings", tokens: ["Embeddings"]},
    %{category: :tools, name: "PythonInterpreter", tokens: ["PythonInterpreter", "DSEx.Sandbox"]},
    %{category: :utils, name: "Errors", tokens: ["Errors", "Exceptions"]},
    %{category: :utils, name: "configure", tokens: ["configure"]},
    %{category: :utils, name: "context", tokens: ["context"]},
    %{category: :utils, name: "StatusMessage", tokens: ["StatusMessage", "de-xt9k"]},
    %{
      category: :utils,
      name: "StatusMessageProvider",
      tokens: ["StatusMessageProvider", "de-xt9k"]
    },
    %{category: :utils, name: "StreamListener", tokens: ["StreamListener", "Streaming"]},
    %{category: :utils, name: "asyncify", tokens: ["async", "Parallel"]},
    %{category: :utils, name: "configure_cache", tokens: ["Cache"]},
    %{category: :utils, name: "inspect_history", tokens: ["inspect_history", "de-xt9k"]},
    %{category: :utils, name: "load", tokens: ["load"]},
    %{category: :utils, name: "streamify", tokens: ["stream", "Streaming"]},
    %{category: :advanced, name: "Assertions", tokens: ["Assertions", "de-b79l"]},
    %{category: :advanced, name: "MCP", tokens: ["MCP"]},
    %{category: :advanced, name: "Saving and loading", tokens: ["save/load", "Saving"]},
    %{category: :advanced, name: "Deployment", tokens: ["Deployment"]},
    %{category: :advanced, name: "Debugging and observability", tokens: ["observability"]},
    %{category: :advanced, name: "optimize_anything", tokens: ["optimize_anything"]},
    %{
      category: :advanced,
      name: "Recursive Language Models paper",
      tokens: ["RLM paper", "de-m7aa"]
    }
  ]

  @doc false
  def surfaces, do: @surfaces

  @doc false
  def report(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    corpus = read_corpus(root)

    surfaces =
      Enum.map(@surfaces, fn surface ->
        matches = Enum.filter(surface.tokens, &contains_token?(corpus, &1))
        status = if matches == [], do: :unmapped, else: :mapped

        surface
        |> Map.put(:status, status)
        |> Map.put(:matches, matches)
      end)

    unmapped = Enum.filter(surfaces, &(&1.status == :unmapped))

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      source_anchors: @source_anchors,
      summary: %{
        total: length(surfaces),
        mapped: length(surfaces) - length(unmapped),
        unmapped: length(unmapped),
        passing: unmapped == []
      },
      surfaces: surfaces
    }
  end

  defp read_corpus(root) do
    patterns = [
      "README.md",
      "docs/**/*.md",
      "lib/**/*.ex",
      "test/**/*.exs",
      "livebooks/**/*.livemd",
      ".tickets/*.md"
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.uniq()
    |> Enum.map_join("\n", fn path ->
      case File.read(path) do
        {:ok, text} -> text
        {:error, _reason} -> ""
      end
    end)
  end

  defp contains_token?(corpus, token), do: String.contains?(corpus, token)
end
