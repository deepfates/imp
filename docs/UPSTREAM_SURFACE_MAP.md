# DSEx Upstream Fidelity

Total: 120
Implemented: 114
Needs work: 5
Intentional omissions: 1
Unmapped: 0
Passing: true

| Category | Surface | Status | Matches |
| --- | --- | --- | --- |
| deepwiki | Overview | implemented | Overview |
| deepwiki | Introduction & Core Concepts | implemented | Core Programming Model |
| deepwiki | Use Cases & Applications | implemented | Tutorial and real-world example parity |
| deepwiki | Installation & Quick Start | implemented | Getting Started, Learning Path |
| deepwiki | Community & Resources | implemented | Prior Art |
| deepwiki | Core Architecture | implemented | Architecture |
| deepwiki | Package Structure & Public API | implemented | Public facade |
| deepwiki | Language Model Integration | implemented | ReqLLM, DSEx.LM |
| deepwiki | Signatures & Task Definition | implemented | DSEx.Signature |
| deepwiki | Adapter System | implemented | Adapter fidelity audit |
| deepwiki | Module System & Base Classes | implemented | DSEx.Module |
| deepwiki | Example & Data Primitives | implemented | DSEx.Example |
| deepwiki | Building DSPy Programs | implemented | Build With DSEx |
| deepwiki | Predict Module | implemented | Predict |
| deepwiki | Reasoning Strategies | implemented | ChainOfThought, ProgramOfThought |
| deepwiki | Tool Integration & Function Calling | implemented | ToolCalls, ReAct |
| deepwiki | Custom Types & Multimodal Support | implemented | Multimodal primitives |
| deepwiki | Module Composition & Refinement | implemented | Refine, BestOfN |
| deepwiki | History & Conversation Management | implemented | History |
| deepwiki | Program Optimization | implemented | Optimization |
| deepwiki | Optimization Overview | implemented | Optimizers |
| deepwiki | Evaluation Framework | implemented | Evaluation |
| deepwiki | Few-Shot Optimizers | implemented | FewShot |
| deepwiki | MIPROv2: Instruction & Parameter Optimization | implemented | MIPROv2 |
| deepwiki | GEPA & SIMBA: Reflective and Stochastic Optimization | implemented | GEPA, SIMBA |
| deepwiki | Fine-tuning & Weight Optimization | implemented | BootstrapFinetune, GRPO |
| deepwiki | Advanced Features | implemented | Advanced DSEx |
| deepwiki | Caching & Performance Optimization | implemented | Cache, performance |
| deepwiki | Parallel & Async Execution | implemented | Parallel, async |
| deepwiki | Streaming Output | implemented | Streaming |
| deepwiki | State Management & Serialization | implemented | save/load, serialization |
| deepwiki | Assertions & Output Validation | implemented | Assertions |
| deepwiki | Code Execution & Sandboxing | implemented | DSEx.Sandbox |
| deepwiki | Configuration & Integration | implemented | configure, integration |
| deepwiki | Settings & Configuration Management | implemented | DSEx.Settings |
| deepwiki | Model Providers & LiteLLM Integration | implemented | ReqLLM |
| deepwiki | Vector Databases & Retrieval | implemented | Retrieval and vector database parity |
| deepwiki | Observability & Monitoring | implemented | observability |
| deepwiki | External Framework Integration | implemented | MCP, ReqLLM |
| deepwiki | Model Context Protocol (MCP) | implemented | MCP |
| deepwiki | Development & Contributing | implemented | release gates |
| deepwiki | Build System & CI/CD | implemented | production.check |
| deepwiki | Testing Framework | implemented | test/ |
| deepwiki | Documentation System | implemented | docs, Livebooks |
| deepwiki | Package Metadata & Release Process | implemented | package.check |
| deepwiki | Glossary | implemented | Glossary |
| adapters | Adapter | implemented | DSEx.Adapter |
| adapters | ChatAdapter | implemented | DSEx.Adapter.Chat |
| adapters | JSONAdapter | implemented | DSEx.Adapter.JSON |
| adapters | XMLAdapter | implemented | DSEx.Adapter.XML |
| adapters | TwoStepAdapter | implemented | DSEx.Adapter.TwoStep |
| evaluation | CompleteAndGrounded | implemented | CompleteAndGrounded |
| evaluation | Evaluate | implemented | DSEx.Evaluate |
| evaluation | EvaluationResult | implemented | EvaluationResult, Report |
| evaluation | SemanticF1 | implemented | SemanticF1 |
| evaluation | answer_exact_match | implemented | exact_match |
| evaluation | answer_passage_match | implemented | extractive_qa |
| experimental | Citations | implemented | Citation |
| experimental | Document | implemented | Document |
| models | BaseLM | implemented | BaseLM, typed LM |
| models | Embedder | implemented | Embeddings, Embedder |
| models | LM | implemented | DSEx.LM, ReqLLM |
| modules | BestOfN | implemented | BestOfN |
| modules | ChainOfThought | implemented | ChainOfThought |
| modules | CodeAct | implemented | CodeAct |
| modules | Module | implemented | DSEx.Module |
| modules | MultiChainComparison | implemented | MultiChainComparison |
| modules | Parallel | implemented | Parallel |
| modules | Predict | implemented | Predict |
| modules | ProgramOfThought | implemented | ProgramOfThought |
| modules | ReAct | implemented | ReAct |
| modules | ReActV2 | needs_work | ReActV2, de-3uxx |
| modules | Refine | implemented | Refine |
| modules | RLM | implemented | RLM |
| optimizers | BetterTogether | implemented | BetterTogether |
| optimizers | BootstrapFewShot | implemented | BootstrapFewShot |
| optimizers | BootstrapFewShotWithRandomSearch | implemented | BootstrapFewShotWithRandomSearch, RandomSearch |
| optimizers | BootstrapFinetune | implemented | BootstrapFinetune |
| optimizers | BootstrapRS | implemented | BootstrapRS, RandomSearch |
| optimizers | COPRO | implemented | COPRO |
| optimizers | Ensemble | implemented | Ensemble |
| optimizers | GEPA | implemented | GEPA |
| optimizers | InferRules | needs_work | InferRules, de-9x31 |
| optimizers | KNN | implemented | KNN |
| optimizers | KNNFewShot | implemented | KNNFewShot |
| optimizers | LabeledFewShot | implemented | LabeledFewShot |
| optimizers | MIPROv2 | implemented | MIPROv2 |
| optimizers | SIMBA | implemented | SIMBA |
| primitives | Audio | implemented | Audio |
| primitives | Code | implemented | Code |
| primitives | Example | implemented | DSEx.Example |
| primitives | History | implemented | History |
| primitives | Image | implemented | Image |
| primitives | Prediction | implemented | DSEx.Prediction |
| primitives | Tool | implemented | DSEx.Tool |
| primitives | ToolCalls | implemented | ToolCalls |
| signatures | InputField | implemented | InputField, Signature.Field |
| signatures | OutputField | implemented | OutputField, Signature.Field |
| signatures | Signature | implemented | DSEx.Signature |
| tools | ColBERTv2 | intentional_omission | ColBERTv2, de-c2we |
| tools | Embeddings | implemented | Embeddings |
| tools | PythonInterpreter | implemented | PythonInterpreter, DSEx.Sandbox |
| utils | Errors | implemented | Errors, Exceptions |
| utils | configure | implemented | configure |
| utils | context | implemented | context |
| utils | StatusMessage | needs_work | StatusMessage, de-xt9k |
| utils | StatusMessageProvider | needs_work | StatusMessageProvider, de-xt9k |
| utils | StreamListener | implemented | StreamListener, Streaming |
| utils | asyncify | implemented | async, Parallel |
| utils | configure_cache | implemented | Cache |
| utils | inspect_history | needs_work | inspect_history, de-xt9k |
| utils | load | implemented | load |
| utils | streamify | implemented | stream, Streaming |
| advanced | Assertions | implemented | Assertions, de-b79l |
| advanced | MCP | implemented | MCP |
| advanced | Saving and loading | implemented | save/load, Saving |
| advanced | Deployment | implemented | Deployment |
| advanced | Debugging and observability | implemented | observability |
| advanced | optimize_anything | implemented | optimize_anything |
| advanced | Recursive Language Models paper | implemented | RLM paper, de-m7aa |
