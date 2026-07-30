# Research Protocols

This document is generated from `benchmarks/research_portfolio.json`. The
registry defines the capability each
research lane must demonstrate before Imp makes an effectiveness or parity
claim. It contains hypotheses and preregistered decision rules, never current
status. `tk` owns work state and the dashboard computes evidence state.

An exact paper reproduction is preferred when its implementation and artifacts
are public. When they are not, the lane must use an actual reference
implementation and a public or ecological benchmark that preserves the claimed
technical capacity. Unavailable artifacts result in a narrower evidence tier,
not an invented result and not an indefinite block.

## Portfolio

<!-- research-portfolio:start -->
| Research lane | Capacity under test | Evidence portfolio | Falsification rule |
| --- | --- | --- | --- |
| Matched declarative inference | Typed declarative programs preserve DSPy-level task quality across classification, reasoning, and multi-hop QA while exposing a production-grade BEAM runtime. | GSM8K matched test (reference_differential)<br>HotPotQA matched test (reference_differential)<br>Banking77 structured classification (adapted_public_protocol) | A complete matched lane places Imp below the quality margin or shows a material structured-output/reliability regression that persists on rerun. |
| Instruction and demonstration optimizer lift | MIPROv2, SIMBA, and related optimizers discover programs that improve held-out quality rather than merely exercising search control flow. | AIME instruction optimization (reference_differential)<br>GSM8K and Banking77 optimizer lift (adapted_public_protocol) | Dev lift exceeds 5 points while test lift is non-positive, random-label lift exceeds 5 points, or an optimizer costs over 2x for less than 1 point of additional test lift. |
| GEPA reflective Pareto search | Language feedback and Pareto selection produce sample-efficient held-out gains across heterogeneous tasks, with resumable and semantically live search. | GEPA six-family campaign (exact_replication)<br>AIME semantic preflight (reference_differential) | Repeated valid campaigns show no held-out gain or materially worse sample efficiency than actual GEPA under matched controls. |
| Arbitrary artifact optimization | The same reflective search interface improves non-prompt textual artifacts with executable domain metrics and explicit acceptance rules. | Paper artifact portfolio (exact_replication)<br>Imp code, agent-config, and scheduling portfolio (imp_native_extension) | Lift appears only on training instances, artifacts violate executable constraints, or upstream materially outperforms Imp across the portfolio. |
| Retrieval, tools, and agents | Imp programs retrieve the right evidence and execute typed tools through multi-step trajectories with quality and failure semantics comparable to DSPy. | HotPotQA retrieval-grounded QA (reference_differential)<br>BFCL-shaped scorer conformance fixture (adapted_public_protocol)<br>Failure-injected agent workflow (reference_differential) | Imp retrieves materially worse evidence, emits materially fewer valid calls, or cannot terminate correctly under the shared fault schedule. |
| Recursive long-context inference | A model can inspect and recursively transform context beyond its direct window, improving answer quality or cost-quality tradeoffs over direct prompting and matched DSPy RLM. | RULER S-NIAH negative control (adapted_public_protocol)<br>OOLONG aggregation and OOLONG-Pairs (adapted_public_protocol)<br>LongBench-v2 code repository QA (adapted_public_protocol)<br>Repository-scale synthesis (ecological_field_benchmark) | RLM does not beat direct prompting in any aggregation regime, or is materially inferior to DSPy while consuming equal or greater aggregate budget; simple-retrieval losses remain scoped negative evidence. |
| Evaluation and inference-time refinement | Metrics, auto-evaluation, Best-of-N, and refinement select or repair outputs in ways that improve independently scored quality without hiding judge bias. | Deterministic evaluation differential (reference_differential)<br>Constraint repair and Best-of-N (adapted_public_protocol) | Apparent judge gains do not transfer to independent checks or refinement regresses quality under matched budgets. |
| BEAM runtime performance and recovery | The BEAM-native substrate provides bounded concurrency, streaming, cancellation, recovery, and observable cost without sacrificing declarative-program correctness. | Provider-free runtime overhead (reference_differential)<br>Live failure-recovery campaign (ecological_field_benchmark)<br>OTP concurrency soak (imp_native_extension) | Capacity leaks, unbounded queues, incorrect terminal states, or reproducible tail-latency/throughput regressions violate the declared bounds. |
<!-- research-portfolio:end -->

## Reading A Lane

The capacity statement is the bet. Benchmark views are independent attempts to
falsify it. Matched controls identify what cannot vary between Imp and its
reference. Metrics include quality, cost, latency, and reliability so an
improvement cannot be purchased invisibly. Confounders name plausible rival
explanations. The go, fail, and inconclusive rules are declared before paid
execution.

Evidence tiers are not a quality ladder. They describe what kind of inference
an artifact supports: exact replication, reference differential, adapted
public protocol, ecological field benchmark, or an Imp-native extension. A
strong adapted benchmark can answer a more useful capacity question than a
weak nominal reproduction, but it cannot be labeled exact parity.

## Execution Policy

1. Start with the user-visible capacity and the smallest observation that could
   disprove it. Do not turn a convenient upstream implementation detail into
   the question unless users depend on it.
2. Use one reusable data-driven runner for a class of experiments. A fixture
   names the program, data split, metric, models, budgets, and expected public
   outputs; the runner owns process startup, transport, cancellation, cost, and
   result shape.
3. Use a coherent reference environment for each comparison. Stock DSPy MIPRO
   and standalone GEPA may require separate reference environments. Do not
   manufacture a hybrid runtime merely to place both names in one process.
4. Run the exact cold public commands against controlled local services before
   paid execution. Shadow and live use one bootstrap; only explicit credentials
   and endpoints may differ.
5. Reject semantically inert campaigns before scaling spend. Treat a provider
   or model change as a new experimental condition.
6. Preserve minimal sufficient provenance and the raw outcome, including
   failures and negative results. Git commits, dependency locks or upstream
   commits, the data digest, experiment fixture, usage/cost, and terminal result
   are the normal record. Do not duplicate identities already covered by those
   sources.
7. Expand a lane only when the existing result leaves a material rival
   explanation unresolved. A second task is a bounded replication, not general
   effectiveness, and a stopped harness is not an optimizer result.

This keeps the research program ambitious without making “the whole ecosystem”
an unbounded collection exercise. New systems enter by stating a useful
capacity, naming the strongest available reference, and earning their claim
through the smallest portfolio that can seriously disprove it.
