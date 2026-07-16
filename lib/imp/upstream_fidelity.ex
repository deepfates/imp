defmodule Imp.UpstreamFidelity do
  @moduledoc false

  @source_anchors %{
    dspy: "https://github.com/stanfordnlp/dspy",
    dspy_docs: "https://dspy.ai/",
    dspy_paper: "arXiv:2310.03714",
    dsp_paper: "arXiv:2212.14024",
    assertions_paper: "arXiv:2312.13382",
    mipro_v2_paper: "arXiv:2406.11695",
    gepa_paper: "arXiv:2507.19457",
    rlm_paper: "arXiv:2512.24601",
    optimize_anything_paper: "arXiv:2605.19633",
    fast_slow_paper: "arXiv:2605.12484v2",
    gepa_repo: "https://github.com/gepa-ai/gepa"
  }

  @stable_api_manifest """
                       Adapter
                       Audio
                       Avatar
                       AvatarOptimizer
                       BestOfN
                       BetterTogether
                       BootstrapFewShot
                       BootstrapFewShotWithRandomSearch
                       BootstrapFinetune
                       BootstrapRS
                       COPRO
                       ChainOfThought
                       ChatAdapter
                       Citations
                       Code
                       CodeAct
                       ColBERTv2
                       CompleteAndGrounded
                       Document
                       Embedder
                       Embeddings
                       Ensemble
                       Evaluate
                       EvaluationResult
                       Example
                       GEPA
                       GEPA advanced
                       History
                       Image
                       InferRules
                       InputField
                       JSONAdapter
                       KNN
                       KNNFewShot
                       LM
                       LabeledFewShot
                       MIPROv2
                       Module
                       MultiChainComparison
                       OutputField
                       Parallel
                       Predict
                       Prediction
                       ProgramOfThought
                       PythonInterpreter
                       RLM
                       ReAct
                       Refine
                       SIMBA
                       SemanticF1
                       Signature
                       StatusMessage
                       StatusMessageProvider
                       StreamListener
                       Tool
                       ToolCalls
                       TwoStepAdapter
                       XMLAdapter
                       answer_exact_match
                       answer_passage_match
                       asyncify
                       configure
                       configure_cache
                       context
                       disable_litellm_logging
                       disable_logging
                       enable_litellm_logging
                       enable_logging
                       inspect_history
                       load
                       streamify
                       """
                       |> String.split("\n", trim: true)

  @ledger [
    %{
      id: "programming.contracts",
      category: :programming_model,
      upstream: ["Signature", "InputField", "OutputField", "Example", "Prediction", "History"],
      source: "dspy/signatures; dspy/primitives",
      disposition: :conformant,
      imp: [Imp.Signature, Imp.Example, Imp.Prediction, Imp.History],
      invariants: [
        "signatures declare named typed inputs and outputs",
        "examples distinguish inputs from labels",
        "predictions retain structured fields and metadata",
        "history is signature-shaped and serializable"
      ],
      evidence: %{
        tests: ["test/imp_test.exs", "test/schema_constraints_test.exs", "test/history_test.exs"],
        docs: ["docs/API_GUIDE.md", "livebooks/02_programming_not_prompting.livemd"]
      }
    },
    %{
      id: "programming.modules",
      category: :programming_model,
      upstream: ["Module", "Predict", "ChainOfThought", "MultiChainComparison", "Parallel"],
      source: "dspy/primitives/module.py; dspy/predict",
      disposition: :conformant,
      imp: [
        Imp.Module,
        Imp.Predict.Predict,
        Imp.Predict.ChainOfThought,
        Imp.Predict.MultiChainComparison,
        Imp.Predict.Parallel
      ],
      invariants: [
        "programs are composable callable values",
        "Predict binds a signature to an LM and adapter",
        "ChainOfThought extends the output contract with reasoning",
        "parallel execution preserves input order and failures"
      ],
      evidence: %{
        tests: [
          "test/public_surface_test.exs",
          "test/property_invariants_test.exs",
          "test/live_provider_e2e_test.exs"
        ],
        docs: ["README.md", "docs/API_GUIDE.md"]
      }
    },
    %{
      id: "models.runtime",
      category: :model_runtime,
      upstream: ["BaseLM", "LM", "Embedder", "configure", "context", "Errors"],
      source: "dspy/clients; dspy/dsp/utils/settings.py; dspy/utils/exceptions.py",
      disposition: :elixir_native_equivalent,
      rationale:
        "ReqLLM owns provider transport while Imp owns program semantics; process-local context replaces Python context variables.",
      imp: [Imp.LM, Imp.Clients.ReqLLM, Imp.Embeddings, Imp.Settings],
      invariants: [
        "provider transport is injectable and normalized",
        "request context is isolated across BEAM processes",
        "credentials never enter portable program state",
        "provider errors retain actionable categories"
      ],
      evidence: %{
        tests: [
          "test/req_llm_client_test.exs",
          "test/otp_state_semantics_test.exs",
          "test/live_provider_test.exs"
        ],
        docs: ["docs/ARCHITECTURE.md", "docs/PRODUCTION_OPERATIONS.md"]
      }
    },
    %{
      id: "models.normalized_runtime_prerelease",
      category: :model_runtime,
      upstream: [
        "3.3 BaseLM normalized requests/responses",
        "LMRequest",
        "LMResponse",
        "LMStream"
      ],
      source: "dspy/core/types.py; dspy/clients/base_lm.py @ 3.3.0b1",
      disposition: :tracking,
      release_blocking: false,
      ticket: "de-tt5j",
      imp: [Imp.Core.LMRequest, Imp.Core.LMResponse],
      invariants: ["stable DSPy remains the release baseline until 3.3 is final"],
      evidence: %{
        tests: ["test/req_llm_client_test.exs"],
        docs: ["docs/UPSTREAM_FIDELITY_AUDIT.md"]
      }
    },
    %{
      id: "adapters.structured_io",
      category: :adapters,
      upstream: ["Adapter", "ChatAdapter", "JSONAdapter", "XMLAdapter", "TwoStepAdapter"],
      source: "dspy/adapters",
      disposition: :conformant,
      imp: [
        Imp.Adapter,
        Imp.Adapter.Chat,
        Imp.Adapter.JSON,
        Imp.Adapter.XML,
        Imp.Adapter.TwoStep
      ],
      invariants: [
        "adapters format signature fields and demonstrations",
        "structured parsers validate output contracts and return retry feedback",
        "tool and history messages survive provider normalization"
      ],
      evidence: %{
        tests: ["test/production_adapter_persistence_test.exs", "test/golden_trace_test.exs"],
        docs: ["docs/ADAPTER_FIDELITY.md", "docs/API_GUIDE.md"]
      }
    },
    %{
      id: "primitives.multimodal",
      category: :primitives,
      upstream: ["Image", "Audio", "File", "Code", "Document", "Citations", "Reasoning"],
      source: "dspy/adapters/types; dspy/experimental",
      disposition: :conformant,
      ticket: "de-ezg9",
      imp: [Imp.Adapters.Types],
      invariants: ["encoding support is not evidence of model reasoning quality"],
      evidence: %{
        tests: ["test/multimodal_adapter_test.exs", "test/multimodal_quality_benchmark_test.exs"],
        docs: ["docs/API_GUIDE.md", "docs/MULTIMODAL_FIDELITY.md"],
        missing: ["audio quality remains an unsupported claim rather than an implied capability"]
      }
    },
    %{
      id: "tools.typed_calls",
      category: :tools_agents,
      upstream: ["Tool", "ToolCalls", "ToolCallResults", "MCP"],
      source: "dspy/adapters/types/tool.py; dspy/utils/mcp.py",
      disposition: :conformant,
      imp: [Imp.Tool, Imp.MCP],
      invariants: [
        "tool schemas are validated before execution",
        "provider tool-call ids and results are retained",
        "MCP discovery creates ordinary Imp tools"
      ],
      evidence: %{
        tests: [
          "test/react_contract_test.exs",
          "test/mcp_import_test.exs",
          "test/protocol_mcp/provider_mcp_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "livebooks/04_tools_agents_mcp_rlm.livemd"]
      }
    },
    %{
      id: "agents.react_family",
      category: :tools_agents,
      upstream: ["ReAct", "ReActV2", "CodeAct", "ProgramOfThought", "PythonInterpreter"],
      source: "dspy/predict/react.py; react_v2.py; code_act.py; program_of_thought.py",
      disposition: :elixir_native_equivalent,
      rationale:
        "Imp ReAct uses provider-native function calls with a reserved submit tool and fails fast on unknown tools, denied calls, malformed calls, and execution errors; upstream ReAct uses action fields, a finish control tool, and observation-based continuation. ReActV2 and code execution retain their separately documented Imp contracts.",
      imp: [
        Imp.Predict.ReAct,
        Imp.Predict.ReActV2,
        Imp.Predict.CodeAct,
        Imp.Predict.ProgramOfThought,
        Imp.Sandbox
      ],
      invariants: [
        "ReAct exposes provider-native function tools and terminates through a reserved submit tool",
        "ReAct fails fast on invalid or failed tool calls instead of claiming upstream observation-and-continue semantics",
        "ReActV2 native history/tool-call semantics are either implemented or explicitly excluded",
        "code execution uses a documented Elixir security boundary"
      ],
      evidence: %{
        tests: [
          "test/react_v2_test.exs",
          "test/react_contract_test.exs",
          "test/completion_surface_test.exs",
          "test/live_provider_e2e_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "docs/REACT_V2_FIDELITY.md"]
      }
    },
    %{
      id: "agents.rlm",
      category: :tools_agents,
      upstream: ["RLM", "SandboxSerializable", "Recursive Language Models paper"],
      source: "dspy/predict/rlm.py; arXiv:2512.24601",
      disposition: :elixir_native_equivalent,
      rationale:
        "Imp implements the recursive controller as a bounded BEAM-native effect interpreter with supervised subcalls, shared budgets, transactional replay, and no Python runtime dependency; paper-scale effectiveness remains a separately gated research claim.",
      release_blocking: false,
      ticket: "de-c7ui",
      imp: [Imp.Predict.RLM, Imp.Predict.RLM.SandboxSerializable],
      invariants: [
        "large inputs remain external to the controller prompt",
        "the controller can inspect, compute, subquery, batch, recurse, and submit",
        "resource budgets are enforced and observable",
        "paper-scale effectiveness is compared with upstream"
      ],
      evidence: %{
        tests: [
          "test/rlm_test.exs",
          "test/rlm_interpreter_test.exs",
          "test/rlm_budget_test.exs",
          "test/live_provider_e2e_test.exs"
        ],
        docs: [
          "docs/API_GUIDE.md",
          "docs/ARCHITECTURE.md",
          "docs/RLM_FIDELITY.md",
          "livebooks/04_tools_agents_mcp_rlm.livemd"
        ],
        missing: [
          "paper-scale reproduction"
        ]
      }
    },
    %{
      id: "composition.refinement",
      category: :programming_model,
      upstream: ["BestOfN", "Refine", "Assertions"],
      source:
        "dspy/predict/best_of_n.py; dspy/predict/refine.py; tests/predict/test_refine.py @ 3.3.0b1 b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f",
      disposition: :conformant,
      imp: [Imp.Predict.BestOfN, Imp.Predict.Refine, Imp.Predict.Assertions],
      invariants: [
        "metrics select or refine predictions",
        "below-threshold attempts ask the wrapped LM for redacted advice",
        "advice is propagated as hint_ and explicit feedback callbacks remain compatible",
        "fail_count bounds provider failures per invocation",
        "threshold stopping is inclusive and the best successful prediction is retained",
        "portable state retains callbacks, threshold, and fail_count with an old-artifact default",
        "strict assertions fail explicitly"
      ],
      evidence: %{
        tests: [
          "test/refine_feedback_test.exs",
          "test/saving_best_of_n_refine_test.exs",
          "test/assertions_test.exs",
          "test/live_provider_e2e_test.exs"
        ],
        docs: ["docs/API_GUIDE.md"],
        missing: [
          "matched-model advice quality and token-cost evidence"
        ]
      }
    },
    %{
      id: "evaluation.metrics",
      category: :evaluation,
      upstream: [
        "Evaluate",
        "EvaluationResult",
        "answer_exact_match",
        "answer_passage_match",
        "SemanticF1",
        "CompleteAndGrounded"
      ],
      source: "dspy/evaluate",
      disposition: :conformant,
      imp: [
        Imp.Evaluate,
        Imp.Metrics,
        Imp.Evaluate.SemanticF1,
        Imp.Evaluate.CompleteAndGrounded
      ],
      invariants: [
        "boolean, numeric, and feedback-bearing metrics normalize consistently",
        "evaluation retains per-row outputs, failures, scores, and traces",
        "concurrency does not reorder rows or lose process context"
      ],
      evidence: %{
        tests: [
          "test/metric_contract_test.exs",
          "test/imp_test.exs",
          "test/property_invariants_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "livebooks/03_evaluate_and_optimize.livemd"]
      }
    },
    %{
      id: "optimization.few_shot",
      category: :optimization,
      upstream: [
        "LabeledFewShot",
        "BootstrapFewShot",
        "BootstrapFewShotWithRandomSearch",
        "BootstrapRS",
        "KNN",
        "KNNFewShot"
      ],
      source: "dspy/teleprompt/bootstrap.py; random_search.py; knn_fewshot.py",
      disposition: :conformant,
      imp: [
        Imp.Optimizer.LabeledFewShot,
        Imp.Optimizer.BootstrapFewShot,
        Imp.Optimizer.BootstrapFewShotWithRandomSearch,
        Imp.Optimizer.BootstrapRS,
        Imp.Optimizer.RandomSearch,
        Imp.Optimizer.KNNFewShot
      ],
      invariants: [
        "successful traces become module-specific demonstrations",
        "teacher and student programs remain distinct",
        "candidate selection uses held-out evaluation"
      ],
      evidence: %{
        tests: [
          "test/optimizer_behavioral_corpus_test.exs",
          "test/optimizer_lift_artifact_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "docs/BENCHMARK_TRUTH.md"]
      }
    },
    %{
      id: "optimization.instructions",
      category: :optimization,
      upstream: ["COPRO", "MIPROv2", "SIMBA", "InferRules", "SignatureOptimizer"],
      source:
        "dspy/teleprompt/copro_optimizer.py; mipro_optimizer_v2.py; simba.py; infer_rules.py",
      disposition: :gap,
      release_blocking: false,
      ticket: "de-9x31",
      imp: [
        Imp.Optimizer.COPRO,
        Imp.Optimizer.MIPROv2,
        Imp.Optimizer.SIMBA,
        Imp.Optimizer.InferRules,
        Imp.Optimizer.SignatureOptimizer
      ],
      invariants: [
        "public names preserve the upstream optimization mechanism",
        "proposal, bootstrapping, search, and selection stages are independently observable",
        "optimization demonstrates held-out lift under matched budgets"
      ],
      evidence: %{
        tests: ["test/optimizer_behavioral_corpus_test.exs"],
        docs: ["docs/API_GUIDE.md"],
        missing: [
          "matched DSPy 3.3.0b1 MIPROv2 differential artifact",
          "matched DSPy 3.3.0b1 SIMBA differential artifact",
          "paper-scale lift evidence"
        ]
      }
    },
    %{
      id: "optimization.gepa",
      category: :optimization,
      upstream: ["GEPA", "GEPA advanced", "GEPA 0.1.1 result contract"],
      source: "dspy/teleprompt/gepa; github.com/gepa-ai/gepa; arXiv:2507.19457",
      disposition: :conformant,
      ticket: "de-izej",
      imp: [Imp.Optimizer.GEPA, Imp.Optimize.Anything],
      invariants: [
        "reflective mutation uses per-example feedback and trajectories",
        "candidate lineage and Pareto state are retained",
        "result shape is source-versioned",
        "paper families reproduce under matched budgets"
      ],
      evidence: %{
        tests: [
          "test/optimize_anything_runner_test.exs",
          "test/gepa_engine_test.exs",
          "test/gepa_contract_artifact_test.exs",
          "test/gepa_replication_artifact_test.exs"
        ],
        docs: ["docs/ADVANCED.md", "docs/RESEARCH_LANDSCAPE.md"],
        missing: [
          "the six-family matched campaign remains required for paper-replication and dominance claims"
        ]
      }
    },
    %{
      id: "optimization.weights",
      category: :optimization,
      upstream: [
        "Avatar",
        "AvatarOptimizer",
        "BootstrapFinetune",
        "GRPO",
        "BetterTogether",
        "Ensemble"
      ],
      source:
        "dspy/predict/avatar; dspy/teleprompt/avatar_optimizer.py; bootstrap_finetune.py; grpo.py; bettertogether.py; ensemble.py",
      disposition: :elixir_native_equivalent,
      rationale:
        "BEAM-native optimizer contracts separate program compilation, asynchronous training jobs, completed rebound programs, and composed workflows while keeping provider execution behind explicit trainer boundaries.",
      ticket: "de-9x31",
      imp: [
        Imp.Predict.Avatar,
        Imp.Optimizer.Avatar,
        Imp.Optimizer.BootstrapFinetune,
        Imp.Optimizer.GRPO,
        Imp.Optimizer.BetterTogether,
        Imp.Optimizer.Ensemble
      ],
      invariants: [
        "Avatar runs a bounded typed-action loop with recoverable tool observations and a reserved Finish action",
        "AvatarOptimizer contrasts positive and negative trajectories, rewrites actor instructions, and retains only improving candidates",
        "BetterTogether composes arbitrary named and repeated optimizer steps in strategy order",
        "BetterTogether evaluates the baseline and every successful prefix, selects the best validated prefix with earlier ties winning, and otherwise returns the latest successful prefix",
        "BetterTogether stops at the first failed optimizer step and returns the best candidate found so far",
        "provider-backed weight steps complete training and rebind trained model state portably"
      ],
      evidence: %{
        tests: [
          "test/avatar_test.exs",
          "test/avatar_optimizer_test.exs",
          "test/better_together_test.exs",
          "test/optimizer_contract_test.exs",
          "test/provider_training_lifecycle_test.exs",
          "test/protocol_training/provider_training_lifecycle_test.exs",
          "test/public_surface_test.exs"
        ],
        docs: [
          "docs/ADVANCED.md",
          "docs/COVERAGE_MATRIX.md",
          "docs/UPSTREAM_FIDELITY_AUDIT.md"
        ],
        artifacts: ["benchmarks/results/local-mlx/local-mlx-922a85e-20260714.json"],
        missing: [
          "paid-provider weight-training execution evidence",
          "BetterTogether paid-provider lifecycle completion",
          "matched Avatar and AvatarOptimizer effectiveness",
          "matched BetterTogether and GRPO effectiveness"
        ]
      }
    },
    %{
      id: "optimization.fast_slow",
      category: :optimization,
      upstream: [
        "Learning, Fast and Slow Algorithm 1",
        "GEPA fast adaptation",
        "CISPO slow updates"
      ],
      source: "arXiv:2605.12484v2; official GEPA Fast-Slow project article",
      disposition: :elixir_native_equivalent,
      release_blocking: false,
      ticket: "de-4bkz",
      rationale:
        "No first-party implementation accompanied the paper; Imp provides a BEAM-native, provider-neutral Algorithm 1 orchestrator with durable effect intents, exact advantage-group accounting, and fail-closed recovery. External CISPO execution and paper-scale effectiveness remain separately gated claims.",
      imp: [
        Imp.Training.FastSlow.Runner,
        Imp.Training.FastSlow.Backend,
        Imp.Training.FastSlow.Checkpoint
      ],
      invariants: [
        "each cycle prefetches exactly T slow-learning minibatches under the current policy",
        "GEPA selects a K-member per-instance Pareto prompt population before slow learning",
        "each question uses one shared G-rollout advantage group with G / K rollouts per prompt",
        "the prompt population remains fixed through exactly T token-aligned slow updates",
        "ambiguous external outcomes are not replayed without provider idempotency proof"
      ],
      evidence: %{
        tests: [
          "test/fast_slow_state_test.exs",
          "test/fast_slow_checkpoint_test.exs",
          "test/fast_slow_runner_test.exs",
          "test/fast_slow_campaign_test.exs"
        ],
        docs: ["docs/RESEARCH_LANDSCAPE.md", "docs/API_GUIDE.md"],
        missing: [
          "external-provider CISPO execution and model-artifact evidence",
          "matched prompt-only, slow-only, and combined provider effectiveness",
          "paper-scale performance and concurrent rollout throughput"
        ]
      }
    },
    %{
      id: "optimization.anything",
      category: :optimization,
      upstream: ["optimize_anything", "arbitrary text artifacts"],
      source: "arXiv:2605.19633; gepa-ai optimize-anything",
      disposition: :tracking,
      ticket: "de-16fo",
      imp: [
        Imp.Optimize.Anything,
        Imp.Optimize.Anything.Config,
        Imp.Optimize.Anything.Result
      ],
      invariants: [
        "artifacts are not limited to prompts",
        "feedback is per-task and per-metric",
        "search retains lineage and Pareto trade-offs",
        "paper tasks reproduce at meaningful scale"
      ],
      evidence: %{
        tests: [
          "test/optimize_anything_runner_test.exs",
          "test/optimize_anything_campaign_test.exs",
          "test/optimize_anything_code_artifact_test.exs",
          "test/optimize_anything_agent_config_test.exs",
          "test/optimize_anything_scheduling_heuristic_test.exs",
          "test/optimize_anything_refiner_test.exs",
          "test/optimize_anything_multimodal_test.exs",
          "test/optimize_anything_tracking_test.exs",
          "test/gepa_module_selector_test.exs",
          "test/gepa_evaluation_cache_backend_test.exs"
        ],
        docs: ["docs/ADVANCED.md", "docs/BENCHMARK_TRUTH.md"],
        missing: ["paper-scale upstream comparison"]
      }
    },
    %{
      id: "retrieval.data",
      category: :retrieval,
      upstream: [
        "Retrieve",
        "Embeddings",
        "ColBERTv2",
        "WeaviateRM",
        "DatabricksRM",
        "built-in datasets",
        "DataLoader"
      ],
      source: "dspy/retrievers; dspy/datasets",
      disposition: :elixir_native_equivalent,
      rationale:
        "Imp owns retrieval protocols and composition while production indexes remain replaceable services; embedded ColBERT is intentionally omitted.",
      imp: [Imp.Retrieve, Imp.Embeddings, Imp.Retrievers.HTTP, Imp.Datasets],
      invariants: [
        "retrievers return ranked normalized documents",
        "external protocols are contract tested",
        "dataset splits and provenance are explicit"
      ],
      evidence: %{
        tests: [
          "test/external_retriever_test.exs",
          "test/datasets_contract_test.exs",
          "test/integration/local_service_e2e_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "docs/ARCHITECTURE.md"]
      }
    },
    %{
      id: "runtime.async_stream_cache",
      category: :runtime,
      upstream: [
        "asyncify",
        "syncify",
        "ParallelExecutor",
        "streamify",
        "StreamListener",
        "configure_cache",
        "track_usage"
      ],
      source: "dspy/utils; dspy/streaming; dspy/clients/cache.py",
      disposition: :conformant,
      ticket: "de-tt5j",
      imp: [Imp.Tasks, Imp.Streaming, Imp.Cache],
      invariants: [
        "work is supervised and cancellable",
        "stream events preserve final results and errors",
        "cache policy and usage accounting are configurable",
        "provider-free overhead is measured against upstream"
      ],
      evidence: %{
        tests: [
          "test/runtime_async_stream_cache_test.exs",
          "test/task_supervision_test.exs",
          "test/production_hardening_test.exs"
        ],
        docs: ["docs/ARCHITECTURE.md", "docs/PARITY_VALIDATION_PROGRAM.md"]
      }
    },
    %{
      id: "runtime.observability",
      category: :runtime,
      upstream: [
        "inspect_history",
        "StatusMessage",
        "StatusMessageProvider",
        "disable_litellm_logging",
        "disable_logging",
        "enable_litellm_logging",
        "enable_logging",
        "optimizer tracking"
      ],
      source: "dspy/utils/inspect_history.py; dspy/utils/callback.py; observability docs",
      disposition: :conformant,
      imp: [Imp.Observability, Imp.Telemetry, Imp.Streaming.Messages],
      invariants: [
        "developers can inspect model, tool, optimizer, and RLM traces",
        "progress is observable without parsing internal structs",
        "all emitted data is redacted"
      ],
      evidence: %{
        tests: [
          "test/observability_test.exs",
          "test/support/telemetry_helpers.ex",
          "test/history_test.exs"
        ],
        docs: ["docs/PRODUCTION_OPERATIONS.md"]
      }
    },
    %{
      id: "state.persistence_deployment",
      category: :operations,
      upstream: ["Module.save", "Module.load", "load", "dump_state", "load_state", "deployment"],
      source: "dspy/primitives/base_module.py; dspy/utils/saving.py; deployment docs",
      disposition: :conformant,
      imp: [Imp.Saving, Imp.Saving.Registry],
      invariants: [
        "portable state round-trips transactionally",
        "credentials are excluded",
        "compiled optimizer state remains executable",
        "deployment from a clean package is documented and tested"
      ],
      evidence: %{
        tests: [
          "test/production_adapter_persistence_test.exs",
          "test/deployment_reference_test.exs",
          "test/package_contract_test.exs"
        ],
        docs: ["docs/PRODUCTION_OPERATIONS.md", "examples/deployment/README.md"]
      }
    },
    %{
      id: "product.learning_path",
      category: :product,
      upstream: [
        "getting started",
        "tutorials",
        "real-world examples",
        "API reference",
        "production guide"
      ],
      source: "dspy/docs/docs",
      disposition: :conformant,
      ticket: "de-2ia5",
      imp: [Imp],
      invariants: [
        "one progressive path teaches the complete product",
        "examples use canonical public APIs",
        "credential-gated cells prove provider-relevant behavior",
        "documentation never outruns evidence"
      ],
      evidence: %{
        tests: [
          "test/learning_path_contract_test.exs",
          "test/livebook_contract_test.exs",
          "test/documentation_contract_test.exs"
        ],
        docs: [
          "README.md",
          "docs/LEARNING_PATH.md",
          "docs/README.md",
          "livebooks/01_real_lm_front_door.livemd"
        ]
      }
    },
    %{
      id: "product.release",
      category: :product,
      upstream: [
        "installable package",
        "versioned release",
        "security policy",
        "CI",
        "clean-room consumer"
      ],
      source: "Hex package and canonical GitHub repository",
      disposition: :conformant,
      ticket: "de-p29x",
      imp: [Imp],
      invariants: [
        "documented installation resolves",
        "license and release metadata ship",
        "security and quality gates pass",
        "a clean project consumes the exact artifact"
      ],
      evidence: %{
        tests: [
          "test/package_contract_test.exs",
          "test/gate_contract_test.exs",
          "test/production_hardening_test.exs",
          "test/deployment_reference_test.exs"
        ],
        docs: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE",
          "SECURITY.md",
          "docs/maintainers/RELEASE.md"
        ]
      }
    }
  ]

  @doc false
  def baseline, do: baseline(Imp.UpstreamAuthorityRegistry.load!())

  @doc false
  def prerelease_tracking, do: prerelease_tracking(Imp.UpstreamAuthorityRegistry.load!())

  @doc false
  def stable_api_manifest, do: @stable_api_manifest

  @doc false
  def surfaces, do: @ledger

  @doc false
  def report(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    registry =
      Imp.UpstreamAuthorityRegistry.load!(
        Keyword.get(opts, :registry_path, Imp.UpstreamAuthorityRegistry.path())
      )

    stable_baseline = baseline(registry)
    prerelease_tracking = prerelease_tracking(registry)
    rows = Enum.map(@ledger, &evaluate_row(&1, root))
    blocking = Enum.filter(rows, &release_blocking_gap?/1)
    {manifest_missing, manifest_duplicates} = manifest_errors(rows)

    manifest_blockers =
      Enum.map(manifest_missing, &"upstream.manifest.missing:#{&1}") ++
        Enum.map(manifest_duplicates, &"upstream.manifest.duplicate:#{&1}")

    %{
      schema_version: 3,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      baseline: stable_baseline,
      prerelease_tracking: prerelease_tracking,
      upstream_authority_registry: registry,
      source_anchors: @source_anchors,
      summary: %{
        total: length(rows),
        conformant: Enum.count(rows, &(&1.status == :conformant)),
        elixir_native_equivalent: Enum.count(rows, &(&1.status == :elixir_native_equivalent)),
        tracking: Enum.count(rows, &(&1.status == :tracking)),
        gaps: Enum.count(rows, &(&1.status == :gap)),
        invalid_evidence: Enum.count(rows, &(&1.status == :invalid_evidence)),
        manifest_missing: length(manifest_missing),
        manifest_duplicates: length(manifest_duplicates),
        release_blockers: length(blocking) + length(manifest_blockers),
        non_blocking_gaps:
          Enum.count(rows, &(&1.status in [:gap, :invalid_evidence] and not &1.release_blocking)),
        passing: blocking == [] and manifest_blockers == []
      },
      manifest: %{
        expected: @stable_api_manifest,
        missing: manifest_missing,
        duplicates: manifest_duplicates
      },
      blocking_ids: Enum.map(blocking, & &1.id) ++ manifest_blockers,
      surfaces: rows
    }
  end

  defp baseline(registry) do
    authority =
      Imp.UpstreamAuthorityRegistry.authority!(registry, "dspy_stable_upstream_fidelity")

    metadata = Map.fetch!(authority, "metadata")
    source_hashes = Map.fetch!(authority, "source_hashes")

    %{
      project: Map.fetch!(authority, "project"),
      version: Map.fetch!(authority, "version"),
      git_ref: Map.fetch!(authority, "git_ref"),
      tag_object_sha: Map.fetch!(authority, "tag_object_sha"),
      git_sha: Map.fetch!(authority, "commit"),
      released_on: Map.fetch!(metadata, "released_on"),
      api_index: Map.fetch!(metadata, "api_index"),
      api_manifest_sha256: Map.fetch!(source_hashes, "api_manifest")
    }
  end

  defp prerelease_tracking(registry) do
    authority =
      Imp.UpstreamAuthorityRegistry.authority!(
        registry,
        "t1_instruction_optimizer_differential_contract"
      )

    metadata = Map.fetch!(authority, "metadata")

    %{
      project: Map.fetch!(authority, "project"),
      version: Map.fetch!(authority, "version"),
      git_ref: Map.fetch!(authority, "git_ref"),
      tag_object_sha: Map.fetch!(authority, "tag_object_sha"),
      git_sha: Map.fetch!(authority, "commit"),
      release_blocking: Map.fetch!(metadata, "release_blocking"),
      tracked_surfaces: Map.fetch!(metadata, "tracked_surfaces")
    }
  end

  defp manifest_errors(rows) do
    ownership_counts =
      rows
      |> Enum.reject(&(&1.disposition == :tracking))
      |> Enum.flat_map(& &1.upstream)
      |> Enum.frequencies()

    missing = Enum.reject(@stable_api_manifest, &Map.has_key?(ownership_counts, &1))
    duplicates = Enum.filter(@stable_api_manifest, &(Map.get(ownership_counts, &1, 0) > 1))
    {missing, duplicates}
  end

  defp evaluate_row(row, root) do
    evidence = Map.fetch!(row, :evidence)
    missing_files = missing_files(evidence, root)
    missing_modules = Enum.reject(Map.get(row, :imp, []), &module_available?/1)
    contract_errors = contract_errors(row)

    evidence_errors =
      file_errors(missing_files) ++ module_errors(missing_modules) ++ contract_errors

    status =
      cond do
        evidence_errors != [] -> :invalid_evidence
        row.disposition == :gap -> :gap
        true -> row.disposition
      end

    release_blocking = Map.get(row, :release_blocking, row.disposition != :tracking)

    row
    |> Map.put(:release_blocking, release_blocking)
    |> Map.put(:status, status)
    |> Map.put(:evidence_errors, evidence_errors)
  end

  defp missing_files(evidence, root) do
    [:tests, :docs, :artifacts]
    |> Enum.flat_map(&Map.get(evidence, &1, []))
    |> Enum.reject(&File.exists?(Path.join(root, &1)))
  end

  defp module_available?(module) when is_atom(module), do: Code.ensure_loaded?(module)

  defp contract_errors(%{disposition: :gap} = row) do
    if present?(Map.get(row, :ticket)), do: [], else: ["gap rows require an owner ticket"]
  end

  defp contract_errors(%{disposition: :elixir_native_equivalent} = row) do
    if present?(Map.get(row, :rationale)),
      do: [],
      else: ["Elixir-native equivalents require a rationale"]
  end

  defp contract_errors(row) do
    []
    |> require_nonempty(row, :upstream)
    |> require_nonempty(row, :invariants)
    |> require_nonempty(Map.fetch!(row, :evidence), :tests)
    |> require_nonempty(Map.fetch!(row, :evidence), :docs)
  end

  defp require_nonempty(errors, map, key) do
    if Map.get(map, key, []) == [], do: errors ++ ["#{key} must not be empty"], else: errors
  end

  defp file_errors([]), do: []
  defp file_errors(paths), do: Enum.map(paths, &"missing evidence file: #{&1}")
  defp module_errors(modules), do: Enum.map(modules, &"missing Imp module: #{inspect(&1)}")
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp release_blocking_gap?(row),
    do: row.release_blocking and row.status in [:gap, :invalid_evidence]
end
