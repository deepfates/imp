defmodule DSEx.BenchmarkCatalog do
  @moduledoc false

  @sources %{
    dspy_repo: "https://github.com/stanfordnlp/dspy",
    dspy_docs: "https://dspy.ai/",
    dspy_optimizers:
      "https://github.com/stanfordnlp/dspy/blob/main/docs/docs/learn/optimization/optimizers.md",
    dspy_paper: "https://arxiv.org/abs/2310.03714",
    mipro_v2: "https://dspy.ai/api/optimizers/MIPROv2/",
    dsp_paper: "https://arxiv.org/abs/2212.14024",
    mipro_paper: "https://arxiv.org/abs/2406.11695",
    gepa_paper: "https://arxiv.org/abs/2507.19457"
  }

  @families [
    %{
      id: "math_gsm8k",
      family: "Math word problems",
      source_lineage: "DSPy paper and docs; GSM8K-style chain-of-thought reasoning.",
      task_shape: "ChainOfThought question -> numeric answer",
      metric: "numeric exact match",
      tiers: ["smoke", "research", "full"],
      status: "implemented",
      commands: [
        "mix benchmark.truth.check",
        "mix benchmark.parity.check",
        "mix benchmark.parity.full"
      ],
      next_step: "Keep as canonical low-cost/full lane."
    },
    %{
      id: "qa_hotpotqa",
      family: "Multi-hop QA",
      source_lineage: "DSPy/DSP lineage; HotPotQA and Baleen-style QA.",
      task_shape: "question + context/retrieval -> short answer",
      metric: "exact match plus F1 diagnostics",
      tiers: ["smoke", "research", "full"],
      status: "provider_free_implemented",
      commands: [
        "mix benchmark.truth.check",
        "mix benchmark.rag_tool_agent.check",
        "mix benchmark.parity.check"
      ],
      next_step:
        "Scale retrieval-indexed HotPotQA/Baleen-style sampled lanes when research-tier model-quality evidence is required."
    },
    %{
      id: "classification_colors",
      family: "Color/classification",
      source_lineage: "DSPy public dataset lineage includes simple Colors-style classification.",
      task_shape: "input -> class label",
      metric: "accuracy or macro F1",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: [
        "mix dsex.benchmark.fetch --tasks colors,iris,iris_typo,heart_disease --full --out benchmarks/data",
        "mix dsex.benchmark.run --colors benchmarks/data/colors-test-0-6.jsonl --iris benchmarks/data/iris-test-0-6.jsonl --iris-typo benchmarks/data/iris_typo-test-0-3.jsonl --heart-disease benchmarks/data/heart_disease-test-0-4.jsonl",
        "mix benchmark.truth.check"
      ],
      next_step:
        "Scale to larger pinned classification/factuality datasets when research-tier evidence is required."
    },
    %{
      id: "rag_retrieval",
      family: "RAG/retrieval",
      source_lineage:
        "DSP and DSPy papers emphasize retrieval + generation for knowledge-intensive QA.",
      task_shape: "query + corpus -> retrieved passages -> answer",
      metric: "retrieval recall plus answer exact/F1",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: ["mix benchmark.rag_tool_agent.check", "mix protocol.retriever.check"],
      next_step:
        "Scale to matched DSEx/DSPy generation over larger retrieval corpora when making research-tier quality claims."
    },
    %{
      id: "tools_react",
      family: "Tool and ReAct agents",
      source_lineage: "DSPy docs present tools and agents as first-class programming workflows.",
      task_shape: "question + tools -> trajectory -> answer",
      metric: "tool success, final answer, and trace status",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: [
        "mix benchmark.trace.check",
        "mix benchmark.rag_tool_agent.check",
        "mix integration.check"
      ],
      next_step: "Add sampled measurable tool-use tasks beyond fixture replay."
    },
    %{
      id: "rlm_recursive_control",
      family: "RLM recursive control",
      source_lineage:
        "DSEx-native recursive controller inspired by DSP-style modular inference, distinct from RAG.",
      task_shape:
        "large/awkward context + controller actions -> sandbox/tool/sub-LM/recurse/submit trace",
      metric: "trace validity, budget adherence, final answer, and redaction invariants",
      tiers: ["smoke", "research"],
      status: "deterministic_implemented",
      commands: [
        "mix test test/rlm_test.exs",
        "mix benchmark.rag_tool_agent.check",
        "mix integration.check"
      ],
      next_step:
        "Add sampled controller tasks that measure action success, budget use, and answer quality across larger contexts."
    },
    %{
      id: "program_composition_orchestration",
      family: "Program composition and orchestration",
      source_lineage:
        "DSPy modules compose predictors, ensembles, comparison, refinement, parallel fan-out, and retrieval-aware variants.",
      task_shape:
        "multiple candidate programs or attempts -> aggregation/refinement/selection -> answer",
      metric:
        "non-regression, selected-answer quality, failure isolation, concurrency safety, and trace shape",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: [
        "mix dsex.benchmark.fetch --tasks composition_orchestration --full --out benchmarks/data",
        "mix dsex.benchmark.run --composition-orchestration benchmarks/data/composition_orchestration-test-0-3.jsonl",
        "mix test test/public_surface_test.exs test/refine_feedback_test.exs",
        "mix benchmark.optimizer_lift.check",
        "LIVE_PROVIDER=1 mix live.check"
      ],
      next_step:
        "Extend sampled orchestration to matched DSEx/DSPy live-provider comparison once cost and model policy are selected."
    },
    %{
      id: "adapter_streaming_structured_io",
      family: "Adapters, streaming, and structured I/O",
      source_lineage:
        "DSPy adapters and Ax-style signatures make output parsing, schema negotiation, retries, and streaming part of the programming contract.",
      task_shape:
        "typed signature + raw/provider output stream -> validated prediction or structured error",
      metric:
        "schema validity, parse recovery, incremental field correctness, stream ordering, and provider option shape",
      tiers: ["smoke", "research"],
      status: "provider_free_and_live_implemented",
      commands: [
        "mix benchmark.operations_stress.check",
        "mix benchmark.trace.check",
        "mix test test/schema_constraints_test.exs test/req_llm_client_test.exs",
        "LIVE_PROVIDER=1 mix live.check"
      ],
      next_step:
        "Extend adversarial structured-output stress to matched live-provider drift checks when release policy requires it."
    },
    %{
      id: "operations_persistence_observability",
      family: "Persistence, cache, telemetry, and OTP operations",
      source_lineage:
        "Production DSP-style systems need save/load, cache behavior, redaction, observability, and supervised concurrency to be trusted outside notebooks.",
      task_shape:
        "program lifecycle and runtime events -> reloadable artifact, redacted traces, stable telemetry, supervised tasks",
      metric:
        "round-trip fidelity, secret absence, event completeness, cache correctness, and failure isolation",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: [
        "mix benchmark.operations_stress.check",
        "mix production.check",
        "mix integration.check",
        "mix benchmark.overhead.check"
      ],
      next_step:
        "Extend lifecycle stress to long-running supervised service soak tests when DSEx ships service templates."
    },
    %{
      id: "multimodal_primitives",
      family: "Multimodal primitives",
      source_lineage:
        "Modern provider surfaces and Ax-style schemas include image, audio, file, document, and code content blocks.",
      task_shape:
        "typed content parts -> provider-compatible message blocks -> decoded DSEx content",
      metric: "round-trip encoding fidelity and provider-shape validity",
      tiers: ["smoke"],
      status: "deterministic_implemented",
      commands: [
        "mix test test/multimodal_adapter_test.exs",
        "mix benchmark.operations_stress.check"
      ],
      next_step:
        "Keep artifact evidence as primitive encoding/decoding proof; add a provider-backed multimodal benchmark only if public docs claim live multimodal reasoning."
    },
    %{
      id: "optimizer_lift",
      family: "Optimizer lift",
      source_lineage:
        "DSPy optimizer docs cover few-shot, instruction/demo search, MIPROv2, GEPA, and finetuning.",
      task_shape: "baseline program + train/dev metric -> compiled program",
      metric: "lift over baseline with trial/cost trace",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: ["mix benchmark.optimizer_lift.check"],
      next_step:
        "Scale natural classification, QA, retrieval, and instruction-following lift lanes to larger sampled datasets when release policy requires model-quality evidence."
    },
    %{
      id: "gepa_paper_replication",
      family: "GEPA paper replication",
      source_lineage:
        "GEPA artifact repo covers AIMEBench, HotpotQABench, hoverBench, IFBench, LiveBenchMathBench, and Papillon with baseline, MIPROv2, GEPA, GEPA-MERGE, ablation, and GRPO rows.",
      task_shape: "paper-family benchmark + model + optimizer budget -> scored optimized program",
      metric:
        "task score plus cost, metric calls, wall-clock, seed variance, and train/dev/test gap",
      tiers: ["research", "full"],
      status: "artifact_contract_implemented",
      commands: ["mix benchmark.gepa_replication.check"],
      next_step:
        "Run fresh paid/source-checkout campaigns to populate real DSEx-vs-DSPy GEPA rows before making dominance claims."
    },
    %{
      id: "factuality_classification",
      family: "Hallucination/factuality classification",
      source_lineage:
        "DSPy optimizer comparison studies use CovidQA, PubMedQA, DROP, FinanceBench, and related tasks.",
      task_shape: "question/context/claim -> label or answer",
      metric: "macro F1, micro F1, weighted F1, exact/F1 where appropriate",
      tiers: ["smoke", "research"],
      status: "missing",
      commands: [],
      next_step: "Add generic classification/QA sampler and F1 metric adapters."
    },
    %{
      id: "mipro_tabular",
      family: "MIPRO tabular classification",
      source_lineage:
        "MIPRO optimizer benchmark includes Iris, Iris-Typo, and Heart Disease tasks.",
      task_shape: "tabular features -> class label",
      metric: "accuracy",
      tiers: ["smoke", "research", "full_tiny"],
      status: "samplers_implemented_optimizer_scale_missing",
      commands: [
        "mix dsex.benchmark.fetch --tasks iris,iris_typo,heart_disease --full --out benchmarks/data",
        "mix dsex.benchmark.run --iris benchmarks/data/iris-test-0-6.jsonl --iris-typo benchmarks/data/iris_typo-test-0-3.jsonl --heart-disease benchmarks/data/heart_disease-test-0-4.jsonl"
      ],
      next_step:
        "Add optimizer-lift runs and larger pinned Iris, Iris-Typo, and Heart Disease slices when making MIPRO tabular claims."
    },
    %{
      id: "mipro_scone",
      family: "ScoNe logical classification",
      source_lineage: "MIPRO optimizer benchmark uses ScoNe for NLI/logical classification.",
      task_shape: "premise/context -> entailment-style label",
      metric: "accuracy",
      tiers: ["smoke", "research"],
      status: "missing",
      commands: [],
      next_step: "Add ScoNe sampler once a stable public dataset source is pinned."
    },
    %{
      id: "hover_verification",
      family: "HoVer claim verification",
      source_lineage: "MIPRO and GEPA benchmark lineage includes HoVer multi-hop verification.",
      task_shape: "claim + corpus/evidence -> supported/refuted label",
      metric: "label accuracy plus retrieval recall where available",
      tiers: ["smoke", "research", "full"],
      status: "gepa_adapter_partial_retrieval_corpus_missing",
      commands: ["mix dsex.benchmark.gepa_dataset", "mix dsex.benchmark.gepa_campaign"],
      next_step:
        "Pin or reproduce the upstream wiki.abstracts.2017 BM25 retriever before claiming source-exact HoVer campaign parity."
    },
    %{
      id: "ifbench_instruction_following",
      family: "IFBench instruction following",
      source_lineage:
        "GEPA benchmark and DSPy GEPA tutorial lineage include verifiable instruction following.",
      task_shape: "instruction + constraints -> answer satisfying verifier",
      metric: "constraint satisfaction score",
      tiers: ["smoke", "research", "full"],
      status: "provider_free_implemented",
      commands: [
        "mix dsex.benchmark.fetch --tasks ifbench_instruction_following --full --out benchmarks/data",
        "mix dsex.benchmark.run --ifbench-instruction-following benchmarks/data/ifbench_instruction_following-test-0-3.jsonl",
        "mix benchmark.truth.check"
      ],
      next_step:
        "Scale from local verifier smoke rows to a pinned IFBench snapshot when research-tier evidence is required."
    },
    %{
      id: "hard_math",
      family: "Hard math/competition reasoning",
      source_lineage:
        "GEPA and modern optimizer work use hard reasoning tasks such as MATH/AIME-style problems.",
      task_shape: "problem -> numeric or symbolic answer",
      metric: "normalized exact match",
      tiers: ["smoke", "research"],
      status: "provider_free_implemented",
      commands: [
        "mix dsex.benchmark.fetch --tasks hard_math --full --out benchmarks/data",
        "mix dsex.benchmark.run --hard-math benchmarks/data/hard_math-test-0-3.jsonl",
        "mix benchmark.truth.check"
      ],
      next_step:
        "Scale from local AIME/MATH-style smoke rows to pinned public snapshots for research-tier evidence."
    },
    %{
      id: "privacy_delegation",
      family: "Privacy-conscious delegation",
      source_lineage: "GEPA/PAPILLON/PUPA lineage evaluates quality while avoiding PII leakage.",
      task_shape: "private query + delegation policy -> useful answer without disallowed leakage",
      metric: "quality score plus privacy/leakage violations",
      tiers: ["synthetic_smoke", "research"],
      status: "missing",
      commands: [],
      next_step: "Start with synthetic PII smoke before adopting any licensed research data."
    },
    %{
      id: "livebench_math",
      family: "LiveBench-Math",
      source_lineage: "GEPA paper uses date-versioned LiveBench-Math.",
      task_shape: "dated math benchmark problem -> final answer",
      metric: "accuracy with dated snapshot provenance",
      tiers: ["research", "full_snapshot"],
      status: "deferred",
      commands: [],
      next_step: "Adopt only with a frozen dated snapshot to avoid moving-target evidence."
    },
    %{
      id: "long_form_writing",
      family: "Long-form writing / STORM-style research",
      source_lineage: "DSPy paper list includes writing Wikipedia-like articles from scratch.",
      task_shape: "research plan + sources -> long-form article",
      metric: "rubric or judge feedback",
      tiers: ["deferred"],
      status: "deferred",
      commands: [],
      next_step: "Do not block production unless DSEx claims long-form writing optimization."
    },
    %{
      id: "finetuning_training",
      family: "Finetuning / BetterTogether / GRPO",
      source_lineage: "DSPy paper list and docs include finetuning plus prompt optimization.",
      task_shape: "training examples -> provider training job -> improved program",
      metric: "provider job lifecycle plus downstream lift",
      tiers: ["protocol", "external_live"],
      status: "protocol_implemented",
      commands: ["mix protocol.training.check", "mix benchmark.optimizer_lift.check"],
      next_step:
        "Add paid external-provider training benchmark only if DSEx claims paid training parity."
    }
  ]

  @spec sources() :: %{atom() => String.t()}
  def sources, do: @sources

  @spec families() :: [map()]
  def families, do: @families

  @spec catalog() :: map()
  def catalog do
    %{
      schema_version: 1,
      purpose: "outside-view DSPy-derived benchmark coverage map",
      sources: @sources,
      families: @families
    }
  end
end
