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
        "homogeneous and heterogeneous parallel execution preserves nesting, input order, causal lineage, and local failures"
      ],
      evidence: %{
        tests: [
          "test/public_surface_test.exs",
          "test/parallel_execution_test.exs",
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
      invariants: [
        "ordinary Imp.LM and ReqLLM calls cross the normalized request/response boundary without changing the legacy raw return contract",
        "the richer stable 3.3 multipart and stream-event model remains explicitly tracked rather than inferred from request envelopes"
      ],
      evidence: %{
        tests: ["test/public_surface_test.exs", "test/normalized_lm_runtime_test.exs"],
        docs: ["docs/internal/UPSTREAM_FIDELITY_AUDIT.md"],
        missing: [
          "stable 3.3 typed multipart request and response values",
          "LMStream event model and ordinary streaming execution through that model"
        ]
      }
    },
    %{
      id: "adapters.structured_io",
      category: :adapters,
      upstream: ["Adapter", "ChatAdapter", "JSONAdapter"],
      source: "dspy/adapters",
      disposition: :conformant,
      imp: [
        Imp.Adapter,
        Imp.Adapter.Chat,
        Imp.Adapter.JSON
      ],
      invariants: [
        "adapters format signature fields and demonstrations",
        "structured parsers validate output contracts and return retry feedback",
        "tool and history messages survive provider normalization"
      ],
      evidence: %{
        tests: ["test/production_adapter_persistence_test.exs", "test/golden_trace_test.exs"],
        docs: ["docs/internal/ADAPTER_FIDELITY.md", "docs/API_GUIDE.md"]
      }
    },
    %{
      id: "adapters.xml",
      category: :adapters,
      upstream: ["XMLAdapter"],
      source: "dspy/adapters/xml_adapter.py",
      disposition: :conformant,
      imp: [Imp.Adapter.XML],
      invariants: [
        "Imp.Adapter.XML renders DSPy XMLAdapter's single XML-only dialect: XML-wrapped structure and inputs, no [[ ## ]] markers, no completed sentinel, and the exact XML output-requirements sentence",
        "parse requires every output field present in tags and rejects tag-free prose with a loud missing-output-fields error; a parse failure falls back to a JSONAdapter-format retry exactly like DSPy's inherited ChatAdapter.__call__",
        "byte-parity is measured per call against real DSPy 3.2.1 by the golden-trace differential (xml_* cases: template AND envelope parity)"
      ],
      evidence: %{
        tests: [
          "test/golden_trace_test.exs",
          "test/production_adapter_persistence_test.exs",
          "test/silent_failure_regressions_test.exs"
        ],
        docs: ["docs/internal/ADAPTER_FIDELITY.md"]
      }
    },
    %{
      id: "adapters.two_step",
      category: :adapters,
      upstream: ["TwoStepAdapter"],
      source: "dspy/adapters/two_step_adapter.py",
      disposition: :conformant,
      imp: [Imp.Adapter.TwoStep],
      invariants: [
        "Imp.Adapter.TwoStep is the faithful DSPy TwoStepAdapter port: the MAIN LM receives a persona/natural-language prompt (field-description system message, plain name: value demos and inputs, no [[ ## ]] markers)",
        "parse runs a SECOND extraction LM through the ChatAdapter path over the synthesized text -> outputs signature (original output fields and annotations intact, upstream's exact instructions string), with DSPy's JSONAdapter fallback on extraction failure",
        "the extraction LM threads through settings (two_step_extraction_lm) or parse opts, mapping DSPy's TwoStepAdapter(extraction_model=...) constructor argument; a missing extraction LM is a loud error, never a silent single-step parse",
        "byte-parity is measured per call (BOTH stages) against real DSPy 3.2.1 by the golden-trace differential (two_step_* cases: template AND envelope parity)",
        "the former plan-prepend extension keeps its behavior under the honest name Imp.Adapter.PlanFirst"
      ],
      evidence: %{
        tests: [
          "test/golden_trace_test.exs",
          "test/completion_surface_test.exs"
        ],
        docs: ["docs/internal/ADAPTER_FIDELITY.md"]
      }
    },
    %{
      id: "primitives.multimodal",
      category: :primitives,
      upstream: ["Image", "Audio", "File", "Code", "Document", "Citations", "Reasoning"],
      source: "dspy/adapters/types; dspy/experimental",
      disposition: :gap,
      ticket: "de-ezg9",
      imp: [Imp.Adapter.Types],
      invariants: [
        "Image, Audio, and File values validate and normalize ordinary provider content blocks",
        "Code fields validate language-aware source inputs and outputs across Chat, JSON, and XML while direct Code content values retain their fenced provider-content behavior",
        "Imp's Document, Citation, and Reasoning values are useful native content values but do not claim DSPy's provider-native citation semantics",
        "encoding support is not evidence of model reasoning quality"
      ],
      evidence: %{
        tests: [
          "test/multimodal_adapter_test.exs",
          "test/multimodal_quality_benchmark_test.exs",
          "test/upstream_exam/adapters_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "docs/internal/MULTIMODAL_FIDELITY.md"],
        missing: [
          "citation-enabled Document blocks plus native Citations response extraction and streaming",
          "audio quality remains an unsupported claim rather than an implied capability"
        ]
      }
    },
    %{
      id: "tools.typed_calls",
      category: :tools_agents,
      upstream: ["Tool", "ToolCalls", "ToolCallResults", "MCP"],
      source: "dspy/adapters/types/tool.py; dspy/utils/mcp.py",
      disposition: :elixir_native_equivalent,
      rationale:
        "Imp exposes validated provider-native tool schemas, call identities/results, MCP import, and separately exercised ReActV2 history rather than DSPy's Tool/ToolCalls/ToolCallResults signature-field contract and ChatAdapter use_native_function_calling switch.",
      imp: [Imp.Tool, Imp.MCP],
      invariants: [
        "tool schemas are validated before execution",
        "provider tool-call ids and results are retained",
        "MCP discovery creates ordinary Imp tools",
        "the BEAM-native provider-tool path is not described as a literal DSPy typed signature-field contract"
      ],
      evidence: %{
        tests: [
          "test/react_contract_test.exs",
          "test/mcp_import_test.exs",
          "test/protocol_mcp/provider_mcp_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "livebooks/04_tools_agents_mcp_rlm.livemd"],
        missing: [
          "first-class ToolCalls and ToolCallResults signature-field semantics matching DSPy",
          "ChatAdapter use_native_function_calling compatibility switch"
        ]
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
        docs: ["docs/API_GUIDE.md", "docs/internal/REACT_V2_FIDELITY.md"]
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
          "docs/internal/RLM_FIDELITY.md",
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
        "concurrency does not reorder rows or lose process context",
        "normalize_text matches DSPy's SQuAD pipeline byte-for-byte: NFD, lowercase, punctuation deletion, word-boundary article removal, whitespace collapse",
        "EM/F1/HotPot-F1 equal DSPy-computed scores on the pinned adversarial table",
        "answer_passage_match applies DPR has_answer token-sequence matching per passage, never substring or cross-passage"
      ],
      evidence: %{
        tests: [
          "test/metric_contract_test.exs",
          "test/imp_test.exs",
          "test/property_invariants_test.exs",
          "test/metrics_dspy_parity_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "livebooks/03_evaluate_and_optimize.livemd"],
        missing: []
      }
    },
    %{
      id: "optimization.few_shot",
      category: :optimization,
      upstream: [
        "LabeledFewShot",
        "BootstrapFewShot",
        "BootstrapFewShotWithRandomSearch",
        "BootstrapRS"
      ],
      claim_surfaces: ["RandomSearch"],
      source: "dspy/teleprompt/vanilla.py; bootstrap.py; random_search.py",
      disposition: :elixir_native_equivalent,
      rationale:
        "Imp preserves deterministic no-replacement sampling, ordered first-k selection, and one advancing stream across predictors while using explicit serializable BEAM RNG state instead of Python random.Random. The seed is configurable and checkpoint-friendly; exact Python subset ordering for an equal integer seed is intentionally not part of the native contract.",
      imp: [
        Imp.Optimizer.LabeledFewShot,
        Imp.Optimizer.BootstrapFewShot,
        Imp.Optimizer.BootstrapFewShotWithRandomSearch,
        Imp.Optimizer.BootstrapRS,
        Imp.Optimizer.RandomSearch
      ],
      invariants: [
        "LabeledFewShot defaults to k=16 and deterministic sampled selection, supports the ordered sample=false path, and replaces demos on every exposed predictor",
        "successful traces become module-specific demonstrations",
        "teacher and student programs remain distinct",
        "candidate selection scores candidates on a valset distinct from the trainset (mechanism parity; held-out effectiveness lift remains a separately gated C3 target)"
      ],
      evidence: %{
        tests: [
          "test/labeled_few_shot_selection_test.exs",
          "test/optimizer_behavioral_corpus_test.exs",
          "test/classical_optimizer_differential_test.exs",
          "test/optimizer_lift_artifact_test.exs"
        ],
        docs: ["docs/API_GUIDE.md", "docs/internal/BENCHMARK_TRUTH.md"],
        missing: ["family-specific held-out effectiveness under matched controls"]
      }
    },
    %{
      id: "optimization.knn",
      category: :optimization,
      upstream: ["KNN", "KNNFewShot"],
      source: "dspy/predict/knn.py; dspy/teleprompt/knn_fewshot.py",
      disposition: :conformant,
      imp: [Imp.Predict.KNN, Imp.Optimizer.KNNFewShot],
      invariants: [
        "Imp.Predict.KNN is the faithful upstream KNN: the trainset's INPUT fields embed once at construction through the required Embedder-analog vectorizer, queries embed at call time, and the top-k neighbors return by descending dot product",
        "Imp.Optimizer.KNNFewShot runs a full metric/teacher-driven BootstrapFewShot compilation of the student over the k retrieved neighbors on EVERY forward call (upstream's patched forward), never attaching raw neighbors",
        "selections and metric-gated demo sets are proven equal to real DSPy 3.2.1 by a deterministic-embedder differential (test/knn_dspy_differential_test.exs), and unit tests pin neighbor ranking against a hand-computed dot-product expectation",
        "the former token-overlap retrieval lives on only under the honest non-DSPy name Imp.Retrievers.KNN"
      ],
      evidence: %{
        tests: [
          "test/knn_few_shot_test.exs",
          "test/knn_dspy_differential_test.exs",
          "test/public_surface_test.exs",
          "test/optimizer_lift_artifact_test.exs"
        ],
        docs: ["docs/API_GUIDE.md"]
      }
    },
    %{
      id: "optimization.instructions",
      category: :optimization,
      upstream: ["COPRO", "MIPROv2", "SIMBA", "InferRules", "SignatureOptimizer"],
      source:
        "dspy/teleprompt/copro_optimizer.py; mipro_optimizer_v2.py; simba.py; infer_rules.py",
      disposition: :gap,
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
        "a source-bound T1 differential matches 33 declared DSPy 3.3.0b1 MIPROv2 and SIMBA structural cases while retaining RNG, sampler, and proposer-call-graph deviations",
        "a provider-free exact DSPy 3.2.1 InferRules differential exercises formatting, rule updates, implicit train/validation splitting, multi-predictor traversal, candidate scoring, and the drop-one-example context recovery schedule while exposing upstream mutable signature aliasing and retaining rollout-ID differences",
        "the admitted one-seed live AIME preflight is operational T2 evidence only",
        "on one frozen three-seed strong-model TREC contract, Imp MIPROv2 improved its own baseline by mean 0.1458 held-out accuracy with a positive 95% clustered interval; this is task-specific C3 evidence, not general MIPROv2 or instruction-family effectiveness",
        "two later modeled-MIPRO Banking77 conditions completed ordinary Result, Artifact, and fresh-service lifecycles but missed their preregistered mean-lift bars; the confirmatory condition improved two of three seeds by mean 0.041667 against a 0.05 requirement, so it is a clean task-scoped negative rather than evidence of broad effectiveness"
      ],
      evidence: %{
        tests: [
          "test/optimizer_behavioral_corpus_test.exs",
          "test/instruction_optimizer_contract_artifact_test.exs",
          "test/instruction_optimizer_experiment_test.exs",
          "test/infer_rules_upstream_differential_test.exs"
        ],
        docs: ["docs/API_GUIDE.md"],
        artifacts: [
          "benchmarks/evidence/admitted/instruction_contract/0d032ab3266c2eb8aef9ea021a1a445688cbdc4e208d9bde9d57037b1f302a49.json",
          "benchmarks/evidence/admitted/instruction_live/e2d79f12c6ef7120df8efacd8a43d03027be65963a41aaff5dd1f87a8bcd1c76.json",
          "benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json"
        ],
        missing: [
          "whole-optimizer and held-out effectiveness evidence for InferRules, plus any upstream parity authority for the native SignatureOptimizer extension",
          "C3 multi-seed held-out SIMBA effectiveness and cross-task MIPROv2 generalization under matched controls",
          "paper-scale lift evidence"
        ]
      }
    },
    %{
      id: "optimization.gepa",
      category: :optimization,
      upstream: [
        "GEPA",
        "GEPA advanced",
        "GEPA 0.1.4 standalone API",
        "GEPA 0.1.1 historical result contract"
      ],
      source:
        "gepa-ai/gepa@8b0ce6cd99a234f6b74daf37558a2ac0ce18f975 (standalone v0.1.4 structural authority)",
      disposition: :gap,
      local_conformance: :structural,
      evidence_rung: "C3",
      claim_boundary:
        "pinned structural conformance, one local operational multi-predictor lifecycle, and one matched three-seed held-out TREC result; this is not general effectiveness, superiority, or paper-family reproduction evidence",
      ticket: "imp-yme4",
      imp: [Imp.Optimizer.GEPA, Imp.Optimize.Anything],
      invariants: [
        "the local engine and adapter contracts track pinned standalone GEPA v0.1.4 structure",
        "the admitted provider-free T1 differential matches 15 structural cases against the exact GEPA v0.1.4 checkout and retains its RNG, resume, and release-metadata deviations",
        "reflective mutation uses per-example feedback and trajectories in focused local tests",
        "candidate lineage, Pareto state, and source-versioned results are retained locally",
        "an ordinary local Banking77 workflow optimized two named predictors, retained the better baseline when reflection regressed, persisted the selected parameter artifact, and reproduced it in a fresh OS process",
        "on one frozen strong-model TREC contract, Imp GEPA improved its own baseline by mean 0.4000 held-out accuracy and cleared a preregistered -0.05 noninferiority margin against pinned DSPy GEPA",
        "a later three-seed JSON-GEPA HotPotQA treatment completed all ordinary Artifact and fresh-service lifecycles but produced mean held-out F1 lift -0.015256 with zero positive seeds; its earlier Chat treatment was operationally invalid and is not effectiveness evidence",
        "IFBench remains compatibility-regression evidence only because a task-scorer representation defect invalidated the earlier Imp effectiveness interpretation",
        "the matched TREC result is task-specific C3 evidence; the clean negatives and invalid IFBench treatment bound rather than erase it, and no result establishes general effectiveness, superiority, or paper-family outcomes"
      ],
      evidence: %{
        tests: [
          "test/optimize_anything_runner_test.exs",
          "test/gepa_engine_test.exs",
          "test/gepa_parameter_artifact_lifecycle_test.exs",
          "test/local_gepa_banking77_example_test.exs",
          "test/gepa_contract_artifact_test.exs",
          "test/gepa_replication_artifact_test.exs"
        ],
        docs: [
          "docs/ADVANCED.md",
          "examples/local_gepa_banking77/README.md",
          "docs/internal/RESEARCH_LANDSCAPE.md",
          ".tickets/imp-88sn.md"
        ],
        artifacts: [
          "benchmarks/evidence/admitted/gepa_contract/3f188ccdc6e3ad7cd1b9f00f9096e62c3024097d6de654b90364712477ef8cc7.json",
          "benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json"
        ],
        missing: [
          "cross-task matched effectiveness beyond the frozen TREC contract",
          "C4 full paper-family campaign evidence is a telos research target, not a v0.1 release claim"
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
        "provider-backed weight steps complete training and rebind trained model state portably",
        "a completed local TRL job restarts only through an explicit trusted runtime, loads the verified LoRA tensors, and checks artifact identity on every generation",
        "the same trusted runtime can serve the exact pinned base policy explicitly, so consumers can measure base and trained programs through the same Imp adapter path"
      ],
      evidence: %{
        tests: [
          "test/avatar_test.exs",
          "test/avatar_optimizer_test.exs",
          "test/better_together_test.exs",
          "test/optimizer_contract_test.exs",
          "test/provider_training_lifecycle_test.exs",
          "test/protocol_training/provider_training_lifecycle_test.exs",
          "test/public_surface_test.exs",
          "test/trl_protocol_test.exs",
          "test/trl_protocol_grpo_lifecycle_test.exs",
          "test/local_grpo_opaque_banking77_example_test.exs"
        ],
        docs: [
          "docs/ADVANCED.md",
          "docs/internal/COVERAGE_MATRIX.md",
          "docs/internal/UPSTREAM_FIDELITY_AUDIT.md"
        ],
        artifacts: [
          "benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json"
        ],
        missing: [
          "paid-provider weight-training execution evidence",
          "BetterTogether paid-provider lifecycle completion",
          "general or consistently useful model-sampled GRPO learning; the complete local multi-step TRL/MPS treatments changed trainable tensors and reproduced verified artifacts, but the retained source-disjoint outcomes were neutral or regressed on held-out data",
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
        "GEPA fast-adaptation handoff",
        "external slow-weight optimizer handoff"
      ],
      source: "arXiv:2605.12484v2; official GEPA Fast-Slow project article",
      disposition: :elixir_native_equivalent,
      ticket: "de-4bkz",
      rationale:
        "The official code page still says code coming soon. Imp provides a BEAM-native, provider-neutral implementation of Algorithm 1's orchestration order with durable effect intents, enforced operation budgets, ordered events, exact advantage-group accounting, and fail-closed recovery. The slow-weight callback is an external handoff; Imp does not implement or verify CISPO, a gradient step, or resulting model weights.",
      imp: [
        Imp.Training.FastSlow.Runner,
        Imp.Training.FastSlow.Backend,
        Imp.Training.FastSlow.Checkpoint
      ],
      invariants: [
        "each cycle prefetches exactly T slow-learning minibatches under the current policy",
        "GEPA selects a K-member per-instance Pareto prompt population before slow learning",
        "each question uses one shared G-rollout advantage group with G / K rollouts per prompt",
        "the prompt population remains fixed through exactly T token-aligned slow-update handoffs",
        "ambiguous external outcomes are not replayed without provider idempotency proof"
      ],
      evidence: %{
        tests: [
          "test/fast_slow_state_test.exs",
          "test/fast_slow_checkpoint_test.exs",
          "test/fast_slow_runner_test.exs",
          "test/fast_slow_campaign_test.exs"
        ],
        docs: ["docs/internal/RESEARCH_LANDSCAPE.md", "docs/OPERATIONS_REFERENCE.md"],
        missing: [
          "external-provider CISPO loss, optimizer execution, and content-bound model-artifact evidence",
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
      disposition: :gap,
      ticket: "de-16fo",
      imp: [
        Imp.Optimize.Anything,
        Imp.Optimize.Anything.Config,
        Imp.Optimize.Anything.Result
      ],
      invariants: [
        "artifacts are not limited to prompts",
        "GEPA v0.1.4 text candidates stay distinct from Imp's strict JSON-safe structured-artifact extension",
        "feedback is per-task and per-metric",
        "search retains lineage and Pareto trade-offs",
        "the public lifecycle optimizes, selects, persists, and fresh-loads task-owned text and JSON-safe structured artifacts without implying paper-task reproduction",
        "the live schema-v2 three-class portfolio keeps train, selection, and untouched test cases distinct and satisfies its declared positive-mean and majority-improving policy for executable retry code, agent configuration, and scheduling artifacts"
      ],
      evidence: %{
        tests: [
          "test/optimize_anything_runner_test.exs",
          "test/optimize_anything_structured_artifact_test.exs",
          "test/optimize_anything_campaign_test.exs",
          "test/optimize_anything_code_artifact_test.exs",
          "test/optimize_anything_agent_config_test.exs",
          "test/optimize_anything_scheduling_heuristic_test.exs",
          "test/optimize_anything_refiner_test.exs",
          "test/optimize_anything_multimodal_test.exs",
          "test/optimize_anything_tracking_test.exs",
          "test/gepa_module_selector_test.exs",
          "test/gepa_evaluation_cache_backend_test.exs",
          "test/local_optimize_anything_retry_policy_three_seed_evidence_test.exs"
        ],
        docs: ["docs/ADVANCED.md", "docs/internal/BENCHMARK_TRUTH.md", ".tickets/imp-88sn.md"],
        artifacts: [
          "benchmarks/evidence/archive/optimize_anything/retry-policy-v2/manifest.json",
          "benchmarks/evidence/admitted/optimize_anything/0aa498b5ae3ab30ae53c74ddafb80e65f50604dd9d4766a1cc324f0b9fb2fd25.json"
        ],
        missing: [
          "paper-scale upstream comparison"
        ]
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
        "Imp owns retrieval protocols and composition while production indexes remain replaceable services. Unlike DSPy's convenience dataset helpers, named Imp loaders require explicit local files and never auto-download; embedded ColBERT is intentionally omitted.",
      imp: [Imp.Retrieve, Imp.Embeddings, Imp.Retrievers.HTTP, Imp.Datasets],
      invariants: [
        "retrievers return ranked normalized documents",
        "external protocols are contract tested",
        "dataset splits and provenance are explicit",
        "named dataset loaders require explicit local files and never auto-download"
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
        "provider streaming either reaches a streamable predictor or returns a terminal unsupported-program error",
        "cache policy and usage accounting are configurable",
        "provider-free overhead is measured against upstream"
      ],
      evidence: %{
        tests: [
          "test/runtime_async_stream_cache_test.exs",
          "test/completion_surface_test.exs",
          "test/task_supervision_test.exs",
          "test/production_hardening_test.exs"
        ],
        docs: ["docs/ARCHITECTURE.md", "docs/internal/PARITY_VALIDATION_PROGRAM.md"]
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
      disposition: :elixir_native_equivalent,
      rationale:
        "Supported built-in program graphs round-trip through Imp.Saving; consumer-defined modules use checksummed parameter Artifacts applied into reconstructed trusted code so runtime callbacks and credentials never come from artifact bytes.",
      imp: [Imp.Saving, Imp.Saving.Registry, Imp.Optimizer.Artifact],
      invariants: [
        "portable state round-trips transactionally",
        "credentials are excluded",
        "compiled optimizer state remains executable",
        "deployment from a clean package is documented and tested",
        "consumer-defined modules reconstruct trusted code and apply portable parameters rather than claiming arbitrary whole-program serialization"
      ],
      evidence: %{
        tests: [
          "test/production_adapter_persistence_test.exs",
          "test/current_dspy_state_boundary_test.exs",
          "test/deployment_reference_test.exs",
          "test/package_contract_test.exs"
        ],
        docs: ["docs/PRODUCTION_OPERATIONS.md", "examples/deployment/README.md"],
        missing: [
          "generic whole-program persistence for arbitrary consumer structs; the supported safe substitute is parameter Artifact plus trusted reconstruction"
        ]
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
        "one progressive path teaches the stable center and names experimental gaps",
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
      disposition: :tracking,
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
          "test/production_hardening_test.exs",
          "test/deployment_reference_test.exs"
        ],
        docs: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE",
          "SECURITY.md",
          "docs/maintainers/RELEASE.md"
        ],
        missing: [
          "a published versioned Hex release; owner publication is intentionally frozen pending explicit check-in"
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

    claims =
      opts
      |> Keyword.get(:claims_path, "benchmarks/claims.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("claims")

    reproduction_audit =
      Imp.ReproductionRegistry.audit!(
        Keyword.get(opts, :reproductions_path, "benchmarks/reproductions.json"),
        authority_path:
          Keyword.get(opts, :evidence_authorities_path, "benchmarks/authorities.json"),
        root: Keyword.get(opts, :reproduction_root, File.cwd!())
      )

    registry =
      Imp.UpstreamAuthorityRegistry.load!(
        Keyword.get(opts, :registry_path, Imp.UpstreamAuthorityRegistry.path())
      )

    stable_baseline = baseline(registry)
    prerelease_tracking = prerelease_tracking(registry)
    rows = Enum.map(@ledger, &evaluate_row(&1, root, claims, reproduction_audit))
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
      reproduction_evidence: %{
        valid: reproduction_audit["valid"],
        invalid_features:
          reproduction_audit["features"]
          |> Enum.reject(& &1["evidence_valid"])
          |> Enum.map(&Map.take(&1, ["id", "evidence_errors"]))
      },
      upstream_authority_registry: registry,
      source_anchors: @source_anchors,
      summary: %{
        total: length(rows),
        conformant: Enum.count(rows, &(&1.status == :conformant)),
        local_conformance: Enum.count(rows, &(Map.get(&1, :local_conformance) == :structural)),
        elixir_native_equivalent: Enum.count(rows, &(&1.status == :elixir_native_equivalent)),
        tracking: Enum.count(rows, &(&1.status == :tracking)),
        gaps: Enum.count(rows, &(&1.status == :gap)),
        invalid_evidence:
          Enum.sum(
            Enum.map(
              rows,
              &Enum.count(&1.capabilities, fn c -> c.status == :invalid_evidence end)
            )
          ),
        invalid_rows: Enum.count(rows, &(&1.status == :invalid_evidence)),
        manifest_missing: length(manifest_missing),
        manifest_duplicates: length(manifest_duplicates),
        conformance_blockers: length(blocking) + length(manifest_blockers),
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

  defp evaluate_row(row, root, claims, reproduction_audit) do
    evidence = Map.fetch!(row, :evidence)
    missing_files = missing_files(evidence, root)
    missing_modules = Enum.reject(Map.get(row, :imp, []), &module_available?/1)
    contract_errors = contract_errors(row)
    open_obligations = open_obligations(evidence)

    capabilities = capability_results(row, claims, reproduction_audit)

    evidence_errors =
      file_errors(missing_files) ++ module_errors(missing_modules) ++ contract_errors

    status =
      cond do
        evidence_errors != [] -> :invalid_evidence
        row.disposition == :gap -> :gap
        true -> row.disposition
      end

    release_blocking =
      Enum.any?(capabilities, fn capability ->
        Enum.any?(capability.claims, fn claim ->
          claim.claim_state == "asserted" and claim.gate_policy == "blocking" and
            (claim.evidence_errors != [] or status == :gap or status == :invalid_evidence)
        end)
      end)

    row
    |> Map.put(:release_blocking, release_blocking)
    |> Map.put(:status, status)
    |> Map.put(:open_obligations, open_obligations)
    |> Map.put(:capabilities, capabilities)
    |> Map.put(:evidence_errors, evidence_errors)
  end

  defp capability_results(row, claims, reproduction_audit) do
    (row.upstream ++ Map.get(row, :claim_surfaces, []))
    |> Enum.uniq()
    |> Enum.map(fn surface ->
      matching_claims =
        claims
        |> Enum.filter(fn claim ->
          Enum.any?(claim["surface"], &surface_matches?(&1, surface))
        end)
        |> Enum.map(fn claim ->
          requirement_lanes = Enum.map(claim["requirements"] || [], & &1["lane"])

          evidence_errors =
            reproduction_audit["features"]
            |> Enum.filter(fn feature ->
              Enum.any?(feature["surface_tokens"], &surface_matches?(&1, surface)) and
                Enum.any?(feature["protocol_ids"], &(&1 in requirement_lanes))
            end)
            |> Enum.flat_map(& &1["evidence_errors"])

          %{
            id: claim["id"],
            claim_state: claim["claim_state"],
            target_rung: claim["target_rung"],
            gate_policy: claim["gate_policy"],
            release: claim["release"],
            evidence_errors: evidence_errors
          }
        end)

      receipts =
        reproduction_audit["features"]
        |> Enum.filter(fn feature ->
          Enum.any?(feature["surface_tokens"], &surface_matches?(&1, surface))
        end)
        |> Enum.map(fn feature ->
          %{
            feature_id: feature["id"],
            protocol_ids: feature["protocol_ids"],
            valid: feature["evidence_valid"],
            errors: feature["evidence_errors"]
          }
        end)

      status = if Enum.any?(receipts, &(not &1.valid)), do: :invalid_evidence, else: :valid
      %{surface: surface, status: status, claims: matching_claims, receipts: receipts}
    end)
  end

  defp surface_matches?(left, right) do
    normalize_surface(left) == normalize_surface(right)
  end

  defp normalize_surface(surface) do
    surface
    |> to_string()
    |> String.replace(~r/^Imp\.(Optimizer|Predict)\./, "")
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.downcase()
  end

  defp open_obligations(evidence) do
    evidence
    |> Map.get(:missing, [])
    |> Enum.filter(&present?/1)
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
