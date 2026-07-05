# DSPy Elixir Parity Matrix

Upstream reference: `stanfordnlp/dspy` commit `80fce4c`.

This matrix tracks public DSPy exports and their Elixir operational equivalent.
Statuses:

- `operational`: implemented with executable tests.
- `equivalent`: implemented as an Elixir-native equivalent with executable tests.
- `compat`: public compatibility wrapper/alias over another implementation.
- `intentional`: Python-specific runtime detail replaced by a BEAM-safe design.

## Root API

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `configure`, `context`, `settings` | `DSPy.configure/1`, `DSPy.context/2`, `DSPy.settings/0` | operational | `dspy_elixir_test.exs` |
| `load`, save/load state | `DSPy.Saving` | operational | `completion_surface_test.exs` |
| `track_usage`, `inspect_history` | traces in `DSPy.Prediction.metadata` | equivalent | `dspy_elixir_test.exs` |
| `streamify` | `DSPy.Streaming` | operational | `completion_surface_test.exs` |
| `cache`, `configure_cache` | `DSPy.Cache` | operational | `parity_surface_test.exs` |
| `asyncify`, `syncify` | native Elixir tasks are used directly (`Task`, `Task.async_stream`) | intentional | `parity_surface_test.exs` |
| `configure_dspy_loggers`, `enable_logging`, `disable_logging` | standard `Logger`/OTP application logging | intentional | compile gate |
| `ColBERTv2` | retriever behaviour implementation point | equivalent | `dspy_elixir_test.exs` |

## Signatures And Primitives

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Signature`, `ensure_signature`, `make_signature` | `DSPy.Signature` | operational | `dspy_elixir_test.exs` |
| `InputField`, `OutputField`, legacy fields | `DSPy.Signature.Field` with `:input`/`:output` | equivalent | `dspy_elixir_test.exs` |
| `OldField`, `OldInputField`, `OldOutputField` | `DSPy.Signature.Field` compatibility mode | compat | `dspy_elixir_test.exs` |
| `SignatureMeta` | struct construction and explicit functions instead of Python metaclass | intentional | `dspy_elixir_test.exs` |
| `infer_prefix` | `DSPy.Signature.Field` prefix inference | operational | `dspy_elixir_test.exs` |
| `Example` | `DSPy.Example` | operational | `dspy_elixir_test.exs` |
| `Prediction`, `Completions` | `DSPy.Prediction` | operational | `dspy_elixir_test.exs` |
| `Module`, `BaseModule`, `Parameter` | `DSPy.Module` behaviour and structs | equivalent | `parity_surface_test.exs` |
| `PythonInterpreter`, `CodeInterpreter`, `SandboxSerializable` | `DSPy.Sandbox` | intentional | `completion_surface_test.exs`, `parity_surface_test.exs` |
| `CodeInterpreterError` | `DSPy.Error` / tagged sandbox errors | equivalent | `completion_surface_test.exs` |
| `FinalOutput` | regular tagged values / predictions | equivalent | `parity_surface_test.exs` |

## Adapters And Types

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Adapter` | `DSPy.Adapter` behaviour | operational | `dspy_elixir_test.exs` |
| `ChatAdapter` | `DSPy.Adapter.Chat` | operational | `dspy_elixir_test.exs` |
| `JSONAdapter` | `DSPy.Adapter.JSON` | operational | `completion_surface_test.exs` |
| `XMLAdapter` | `DSPy.Adapter.XML` | operational | `dspy_elixir_test.exs` |
| `TwoStepAdapter` | `DSPy.Adapter.TwoStep` | operational | `completion_surface_test.exs` |
| `BAMLAdapter` | `DSPy.Adapter.BAML` | compat | `completion_surface_test.exs` |
| `Image`, `Audio`, `File`, `Document`, `Code`, `Reasoning`, `History`, `Type` | `DSPy.Adapters.Types.*` | operational | `parity_surface_test.exs` |
| `Tool`, `ToolCalls`, `ToolCallResults` | `DSPy.Tool`, `DSPy.Adapters.Types.ToolCalls`, `ToolCallResults` | operational | `dspy_elixir_test.exs`, `parity_surface_test.exs` |
| citations | `DSPy.Adapters.Types.Citation` | operational | `parity_surface_test.exs` |

## Clients And Providers

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `BaseLM`, `LM` | `DSPy.LM`, `DSPy.Clients.HTTPLM` | operational | `completion_surface_test.exs` |
| `OpenAIProvider` | `DSPy.Clients.OpenAI` | operational | `live_provider_test.exs` |
| `DatabricksProvider` | `DSPy.Clients.Databricks` | operational contract | `completion_surface_test.exs` |
| `LocalProvider` | `DSPy.Clients.Local` | operational contract | `completion_surface_test.exs` |
| LiteLLM client | `DSPy.Clients.LiteLLM` | operational contract | `completion_surface_test.exs` |
| `TrainingJob`, finetune provider API | `DSPy.Clients.TrainingJob`, `DSPy.Clients.Trainer` | operational | `completion_surface_test.exs` |
| `Provider` | provider modules implementing `DSPy.Clients.Trainer` / `DSPy.LM` | equivalent | `completion_surface_test.exs` |
| `Embedder` | `DSPy.Embeddings` | operational | `completion_surface_test.exs` |
| `enable_litellm_logging`, `disable_litellm_logging` | no-op under Elixir Logger; LiteLLM proxy logging belongs to proxy process | intentional | compile gate |
| `inspect_history` | prediction traces and metadata | equivalent | `dspy_elixir_test.exs` |
| `DSPY_CACHE` | `DSPy.Cache` | operational | `parity_surface_test.exs` |

## Errors

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `DSPyError` | `DSPy.Error` | operational | compile gate |
| `LMError` and provider subclasses | `DSPy.LMError` with reason/retryable fields | equivalent | compile gate |
| `AdapterParseError` | `DSPy.AdapterParseError` | operational | compile gate |
| `ContextWindowExceededError` | `DSPy.ContextWindowExceededError` | operational | compile gate |
| `is_retryable_lm_error` | `DSPy.Errors.retryable?/1` | operational | compile gate |

## Prediction Modules

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Predict` | `DSPy.Predict.Predict` | operational | `dspy_elixir_test.exs` |
| `ChainOfThought` | `DSPy.Predict.ChainOfThought` | operational | `dspy_elixir_test.exs` |
| `ProgramOfThought` | `DSPy.Predict.ProgramOfThought` | operational | `completion_surface_test.exs` |
| `ReAct` | `DSPy.Predict.ReAct` | operational | `dspy_elixir_test.exs` |
| `ReActV2` | `DSPy.Predict.ReActV2` | operational | `parity_surface_test.exs` |
| `CodeAct` | `DSPy.Predict.CodeAct` | intentional safe sandbox | `parity_surface_test.exs` |
| `BestOfN` | `DSPy.Predict.BestOfN` | operational | `completion_surface_test.exs` |
| `Refine` | `DSPy.Predict.Refine` | operational | `completion_surface_test.exs` |
| `Parallel` | `DSPy.Predict.Parallel` | operational | `completion_surface_test.exs` |
| `KNN` | `DSPy.Predict.KNN` | operational | `parity_surface_test.exs` |
| `MultiChainComparison` | `DSPy.Predict.MultiChainComparison` | operational | `parity_surface_test.exs` |
| `RLM` | `DSPy.Predict.RLM` | equivalent | `rlm_parity_test.exs` |
| `majority` | `DSPy.Predict.Aggregation.majority/2` | operational | `parity_surface_test.exs` |
| `Tool` from predict namespace | `DSPy.Tool` | operational | `dspy_elixir_test.exs` |

## Retrieval

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Retrieve` | `DSPy.Retrieve` behaviour | operational | `dspy_elixir_test.exs` |
| `Embeddings`, `EmbeddingsWithScores` | `DSPy.Embeddings`, scored maps from retrievers | equivalent | `completion_surface_test.exs` |
| Databricks/Weaviate retrievers | `DSPy.Retrieve` behaviour plus injectable implementations | equivalent | `dspy_elixir_test.exs` |

## Evaluation

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Evaluate`, `EvaluationResult` | `DSPy.Evaluate`, `DSPy.Evaluate.Result` | operational | `dspy_elixir_test.exs` |
| `EM`, `F1`, `normalize_text`, `answer_exact_match`, `answer_passage_match` | `DSPy.Metrics` | operational | `parity_surface_test.exs` |
| `SemanticF1`, `CompleteAndGrounded` | `DSPy.Evaluate.SemanticF1`, `CompleteAndGrounded` | operational | `parity_surface_test.exs` |

## Teleprompt / Optimizers

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Teleprompter` | compile protocol by module convention | equivalent | `parity_surface_test.exs` |
| `LabeledFewShot` | `DSPy.Teleprompt.LabeledFewShot` | operational | `dspy_elixir_test.exs` |
| `BootstrapFewShot` | `DSPy.Teleprompt.BootstrapFewShot` | operational | `dspy_elixir_test.exs` |
| `BootstrapFewShotWithRandomSearch` | `DSPy.Teleprompt.RandomSearch` / alias | operational | `completion_surface_test.exs` |
| `BootstrapFewShotWithOptuna` | alias over random search | compat | `parity_surface_test.exs` |
| `BootstrapFinetune` | `DSPy.Teleprompt.BootstrapFinetune` | operational | `completion_surface_test.exs` |
| `GRPO` | `DSPy.Teleprompt.GRPO` | operational | `completion_surface_test.exs` |
| `COPRO` | `DSPy.Teleprompt.COPRO` | operational | `completion_surface_test.exs` |
| `MIPROv2` | `DSPy.Teleprompt.MIPROv2` | operational | `completion_surface_test.exs` |
| `SIMBA` | `DSPy.Teleprompt.SIMBA` | operational | `completion_surface_test.exs` |
| `GEPA` | `DSPy.Teleprompt.GEPA` | operational | `completion_surface_test.exs` |
| `SignatureOptimizer` | `DSPy.Teleprompt.SignatureOptimizer` | operational | `completion_surface_test.exs` |
| `Ensemble` | `DSPy.Teleprompt.Ensemble` | operational | `parity_surface_test.exs` |
| `KNNFewShot` | `DSPy.Teleprompt.KNNFewShot` | operational | `parity_surface_test.exs` |
| `BetterTogether` | `DSPy.Teleprompt.BetterTogether` | operational | `parity_surface_test.exs` |
| `InferRules` | `DSPy.Teleprompt.InferRules` | operational | `parity_surface_test.exs` |
| `AvatarOptimizer` | `DSPy.Teleprompt.AvatarOptimizer` | compat | `parity_surface_test.exs` |
| `bootstrap_trace_data` | prediction traces in metadata and bootstrap demos | equivalent | `dspy_elixir_test.exs` |

## Streaming

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `StreamResponse`, `StatusMessage`, `StatusMessageProvider`, `StreamListener` | `DSPy.Streaming.Messages.*` | operational | `parity_surface_test.exs` |
| `streamify`, `streaming_response`, `apply_sync_streaming` | `DSPy.Streaming` | operational | `completion_surface_test.exs` |

## Datasets

| Upstream | Elixir | Status | Test |
| --- | --- | --- | --- |
| `Dataset`, `DataLoader` | `DSPy.Datasets.Dataset`, `DataLoader` | operational | `parity_surface_test.exs` |
| `GSM8K`, `HotPotQA`, `MATH`, `Colors` | `DSPy.Datasets.*` | operational | `completion_surface_test.exs`, `parity_surface_test.exs` |
| `AlfWorld` | not bundled; external environment integration should implement `DSPy.Datasets` records | intentional | matrix rationale |
| dataset answer parsing helpers | `DSPy.Datasets.GSM8K.metric/3`, `DSPy.Metrics` | operational | `parity_surface_test.exs` |

## Success Gate

The deterministic suite and live-provider suite are the current success gate:

```sh
mix test
LIVE_PROVIDER=1 mix test --include live test/live_provider_test.exs
mix compile --warnings-as-errors
```
