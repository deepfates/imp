# API Guide

Imp gives language-model code the same basic shape as the rest of an Elixir
application: declared inputs and outputs, callable modules, explicit data,
measured behavior, and values you can persist and supervise.

This guide explains the public concepts and the path most applications use.
The generated module reference is the exhaustive list of functions and
options. Advanced provider jobs, resumable batches, and protocol details live
in [Operations Reference](OPERATIONS_REFERENCE.md).

## A program turns named inputs into a typed prediction

Four values make up the center of Imp:

- A **signature** declares the task's inputs, outputs, types, and instructions.
- A **program** is an Elixir value that knows how to perform that task.
- A **prediction** is the validated result of one call.
- An **example** is labeled data used to measure or improve the program.

Start by connecting a model and building a program:

```elixir
lm = Imp.req_llm(
  "openai:gpt-5.4-mini",
  api_key: System.fetch_env!("OPENAI_API_KEY"),
  temperature: 0
)

signature =
  Imp.signature(
    "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]",
    "Assign the support ticket to the team that owns it."
  )

program = Imp.predict(signature, lm: lm, adapter: Imp.Adapter.JSON)

{:ok, prediction} =
  Imp.call(program, %{ticket: "Our checkout API has been down for an hour."})

Imp.get(prediction, :team)
#=> "infrastructure"
```

The signature is more than prompt text. The adapter uses it to render the
request and validate the response. An output outside the declared enum is an
error, not a string your application discovers later.

Most applications call programs, not language models directly. Internally each
call crosses the provider-neutral `Imp.Core.LMRequest` / `Imp.Core.LMResponse`
boundary before ReqLLM transport. `Imp.LM.request/2` exposes that normalized
envelope when an integration needs usage or response metadata; the established
`Imp.LM.generate/3` API continues to return the raw model value.

### Signature type DSL

Each field is `name`, `name: type`, or `name: type "description"`. An untyped
field is a string. The string DSL accepts these types:

| Type | Aliases | Validation |
| --- | --- | --- |
| `string` | `str` | Elixir binary |
| `integer` | `int` | integer only |
| `float` | — | integer or float |
| `number` | — | any number |
| `boolean` | `bool` | `true` or `false` |
| `datetime` | — | ISO 8601 on the wire; parsed to `DateTime` or `NaiveDateTime` |
| `object` | `map`, `dict` | map |
| `array` | — | list with unconstrained items |
| `array[type]` | — | list whose items recursively satisfy `type`, including nested arrays |
| `enum[a,b]` | `class[a,b]`; `|` may replace `,` | one of the listed strings |
| `yes_no` | — | string normalized to exactly `yes` or `no` |
| `short_span` | — | non-empty string of at most 12 normalized tokens, with no newline or semicolon |
| `numeric_span` | — | numeric answer string, optionally signed, comma-grouped, decimal, currency-prefixed, or percent-suffixed |

Imp spells DSPy's Python `list[type]` form as `array[type]`; the parser points
mistyped `list[...]` signatures at that spelling. Unknown types and duplicate
names across the input/output arrow fail when the signature is built. The map
form below additionally supports `type: :code` with an optional `language:`
and `type: :reasoning` for the native-capable reasoning value;
custom Pydantic-style model and tuple types are not part of Imp's string DSL.

### Required, nullable, and default fields

Fields are required unless their structured declaration says otherwise. Use
`optional: true` for a nullable field; if the model omits it, the prediction
contains the field with value `nil`. Use `default:` when omission should produce
a concrete fallback. Defaults work for both inputs and outputs and are preserved
through `Imp.Signature.dump/1` and `load/1`.

```elixir
signature =
  Imp.signature(%{
    inputs: [%{name: :question, type: :string, default: "Summarize this."}],
    outputs: [
      %{name: :answer, type: :string},
      %{name: :note, type: :string, default: "No note"},
      %{name: :citation, type: :string, optional: true}
    ]
  })
```

Fallbacks apply only when a key is absent: `false`, `0`, `""`, `[]`, and an
explicit nullable `nil` are retained. Elixir values are immutable, so a literal
`default: []` or `default: %{}` already has the fresh-value safety for which
Python commonly needs `default_factory`. Imp therefore keeps defaults as plain,
portable signature data instead of persisting executable factories.

ReActV2 final submission is intentionally stricter: the `submit` tool requires
every output key, including nullable or defaulted fields, and validates the
submitted values. This matches the current DSPy contract and makes the final
tool call explicit rather than silently repairing it.

The structured map form also supports unions when a field genuinely admits
more than one wire shape:

```elixir
choice = %{
  name: :choice,
  type: :union,
  constraints: %{
    any_of: [
      %{type: :object, properties: %{count: %{type: :integer}}},
      %{
        type: :object,
        properties: %{
          labels: %{type: :array, constraints: %{items: %{type: :string}}}
        }
      }
    ]
  }
}
```

`Imp.Adapter.JSON` exports this as JSON Schema `anyOf`.
`Imp.Adapter.XML` renders and parses the corresponding recursive XML for typed
objects, arrays, mappings, and unions, while still accepting legacy JSON inside
an outer XML output tag. XML declarations, doctypes, and custom entities are
rejected; model output cannot use XML parsing to load a local or remote resource.

### Images, audio, and files are inert values

Multimodal values never read the filesystem or fetch the network merely because
an adapter formats them. Use an explicit factory when your application intends
that effect; the returned value contains the bytes and can then cross retries,
artifact persistence, or a process restart without retaining hidden access to
the original path.

```elixir
alias Imp.Adapter.Types.{Audio, File, Image}

image = Image.from_path("priv/chart.png")
audio = Audio.from_path("priv/question.wav")
report = File.from_path("priv/report.pdf", filename: "quarterly-report.pdf")
uploaded = File.from_file_id("file_abc123", filename: "reference.pdf")
```

`Image.from_url/2` and `Audio.from_url/2` are explicit eager downloads. They
require HTTP(S) and a finite timeout (30 seconds by default), but deliberately
do not guess an application-specific SSRF policy: validate an untrusted host
against your allowlist before calling them. Constructing `%File{path: path}`
directly is rejected at formatting time; use
`Imp.Adapter.Types.File.from_path/2` so the read is visible at the caller-owned
boundary. `Imp.Adapter.Types.File.from_bytes/2` accepts raw bytes, while
`Imp.Adapter.Types.File.from_file_id/2` carries an already uploaded provider
reference.

### Adapter wire-format wording

When `Imp.Adapter.Chat` or `Imp.Adapter.JSON` renders a non-string output, the
model may see wording such as “formatted as a valid Python `Literal`,” `list`,
or `dict`. That wording deliberately matches the pinned DSPy 3.2.1 adapter
contract so the same provider sees equivalent format guidance on both
runtimes. Imp parses the returned wire value into the declared Elixir field
type; it neither evaluates Python nor exposes a Python value to application
code.

Use the map form for a language-aware code field. Code inputs are rendered as
plain source text; fenced or plain outputs are returned as a validated typed
code value:

```elixir
signature =
  Imp.signature(
    %{
      inputs: [:task],
      outputs: [%{name: :code, type: :code, language: "elixir"}]
    },
    "Write the requested Elixir function."
  )

program = Imp.predict(signature, lm: lm)
{:ok, prediction} = Imp.call(program, %{task: "Define double/1 for integers."})

%Imp.Adapter.Types.Code{code: source, language: "elixir"} = Imp.get(prediction, :code)
```

This type validates and transports source code; it does not execute it. Keep
execution behind an application-owned sandbox or trusted evaluator.
Imp's native structured-output schema represents this field as a JSON string,
matching the adapter prompt and returned wire value. This is a deliberate
flat-wire adaptation rather than DSPy's pydantic wrapper-object schema.

Use `Imp.chain_of_thought/2` when a declared reasoning field helps the task:

```elixir
program = Imp.chain_of_thought("question -> answer: short_span", lm: lm)
{:ok, prediction} = Imp.call(program, %{question: "What city is the Eiffel Tower in?"})

Imp.get(prediction, :answer)
#=> "Paris"

Imp.get(prediction, :reasoning)
#=> "..."
```

Like DSPy 3.3.1, `ChainOfThought` keeps a plain string rationale by default. To
use one typed contract across native-reasoning and ordinary models, opt in:

```elixir
program =
  Imp.chain_of_thought("question -> answer: short_span",
    lm: lm,
    rationale_field_type: :reasoning
  )
```

When the LM advertises native reasoning, Imp requests it (defaulting to low
effort), omits the synthetic field from the provider-facing schema, and restores
the returned thinking as `%Imp.Adapter.Types.Reasoning{}`. Otherwise—or when
`reasoning_effort: nil` explicitly disables native mode—the adapter asks for
reasoning as ordinary text and coerces it to that same type. Provider metadata
remains available on the prediction for transport-level inspection.

## Settings let the application choose when dependencies are fixed

Pass `lm:` or `adapter:` while constructing a program when that dependency is
part of the program's configuration. Omit it when the application should bind
the dependency later.

`Imp.configure/1` sets supervised node defaults. `Imp.context/2` provides a
process-local override and restores the previous settings afterward:

```elixir
program = Imp.predict("question -> answer")

test_lm =
  Imp.LM.Static.new(
    handler: fn _messages, _opts -> %{answer: "Paris"} end
  )

answer =
  Imp.context([lm: test_lm], fn ->
    {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    Imp.get(prediction, :answer)
  end)

answer
#=> "Paris"
```

This is the normal way to test a dynamically configured program without a
provider. `Imp.with_lm/2` is different: it explicitly rewrites a program graph
to use a particular LM.

## Failures remain visible at the application boundary

Calls return `{:ok, prediction}` or `{:error, reason}`. Match both branches
where a model call enters your application:

```elixir
case Imp.call(program, %{question: "Capital of France?"}) do
  {:ok, prediction} ->
    {:ok, Imp.get(prediction, :answer)}

  {:error, reason} ->
    Logger.warning("Imp call failed", reason: inspect(reason))
    {:error, :language_model_unavailable}
end
```

Missing inputs, transport failures, malformed model responses, validation
errors, and exhausted retries are returned explicitly. Invalid constructor
options raise because they are local programming errors that should fail
before traffic reaches the program.

## Examples and metrics turn an impression into a measurement

An example contains inputs and expected outputs. `Imp.with_inputs/2` tells Imp
which fields are given to the program; the remaining fields are labels:

```elixir
devset = [
  Imp.example(
    ticket: "The API is unavailable in every region.",
    team: "infrastructure",
    urgency: "high"
  )
  |> Imp.with_inputs(:ticket),
  Imp.example(
    ticket: "How do I export a report?",
    team: "product",
    urgency: "normal"
  )
  |> Imp.with_inputs(:ticket)
]

metric = fn example, prediction ->
  Imp.get(example, :team) == Imp.get(prediction, :team) and
    Imp.get(example, :urgency) == Imp.get(prediction, :urgency)
end

report = Imp.evaluate(program, devset, metric,
  max_concurrency: 4,
  max_errors: 2,
  failure_score: 0.0
)

{report.score, report.rows, report.errors}
```

The score summarizes the run. The rows and errors explain it. Use a finite
`max_errors` when repeated failures indicate that the job is broken; Imp keeps
the stage and redacted row identity in the cancellation error.

Built-in metrics include `Imp.exact_match/1`, `Imp.extractive_qa/3`, and
`Imp.classification/3`. A useful metric should distinguish behavior you would
actually deploy, not merely reward a convenient output shape.

Return `true`/`false` for exact acceptance and a number for graded credit. Use
`%Imp.Metrics.Result{score: ..., feedback: ..., metadata: ...}` (or the
equivalent map) when reflective optimizers or row diagnostics need actionable
feedback; Imp normalizes every accepted shape before aggregation.

## Keep training, selection, and test data separate

Optimization needs at least two roles for data:

- **Training data** is information the optimizer may use to construct a
  candidate.
- **Selection data** chooses between the original and candidate programs.
- **Test data** measures the selected program after that choice is complete.

`Imp.Experiment.Data` checks that example identities do not overlap across
those splits. `Imp.Experiment.check/5` owns the complete lifecycle:

```elixir
trainset = [
  Imp.example(ticket: "Duplicate invoice charge", team: "billing", urgency: "normal")
  |> Imp.with_inputs(:ticket)
]

selection_set = [
  Imp.example(ticket: "Refund the annual invoice", team: "billing", urgency: "normal")
  |> Imp.with_inputs(:ticket)
]

testset = [
  Imp.example(ticket: "Explain this subscription charge", team: "billing", urgency: "normal")
  |> Imp.with_inputs(:ticket)
]

data =
  Imp.Experiment.Data.new(
    train: trainset,
    selection: selection_set,
    test: testset
  )

optimizer = Imp.Optimizer.LabeledFewShot.new(k: 1, sample: false)

{:ok, result} =
  Imp.Experiment.check(program, optimizer, data, metric,
    artifact_id: "support-router",
    evaluation_options: [max_concurrency: 4, max_errors: 2]
  )

{result.baseline_selection.score, result.optimized_selection.score, result.test.score}
```

Imp evaluates the original and optimized programs on selection data, keeps the
original on a tie, builds and reapplies the selected artifact, and only then
reads the test split. If optimization, evaluation, artifact construction, or
artifact application fails, the function returns the failed stage instead of
a partial success.

Language-model outputs can be noisy even when the program and rows are
unchanged. When one lucky or unlucky pass could decide selection, predeclare a
fixed repeat count:

```elixir
{:ok, result} =
  Imp.Experiment.check(program, optimizer, data, metric,
    evaluation_options: [repetitions: 3, aggregation: :mean]
  )

result.repetition_summary.paired_deltas.selection
```

Imp runs every outer selection and test stage three times over the same ordered
row identities, selects by the arithmetic mean, and records each run plus the
paired candidate-minus-baseline deltas. Calls and row-evaluation opportunity
multiply by the repeat count. The default remains one pass and keeps the
ordinary compact result shape; repeated checks add a redacted repetition
summary, with detailed rows still opt-in.

When the admission decision needs more replication than the final test
estimate, declare both counts explicitly:

```elixir
evaluation_options = [
  repetitions: [selection: 3, test: 1],
  aggregation: :mean
]
```

Both baseline and optimized selection evaluations use the selection count. The
selected-program test evaluation—and the baseline test evaluation when
requested—use the test count. Unequal counts persist their per-stage counts,
runs, paired deltas, and exact row-evaluation opportunity. The integer form
remains the uniform shorthand.

This policy does not repeat or otherwise change an optimizer's internal search
objective. It improves the final Experiment admission decision; it does not
retroactively change earlier results or turn a noisy negative benchmark into a
positive one.

This is the best default for an application or a bounded experiment. Use
`Imp.optimize/3..5` directly when you deliberately need an optimizer's native
return value or lifecycle.

### Bound live optimizer spend before the first request

A live optimizer can call task and proposal models many times. Put every LM in
the workflow behind one shared `Imp.Optimizer.Budget` so request, input-token,
output-token, and dollar limits are prospective rather than post-hoc warnings:

```elixir
{:ok, budget} =
  Imp.start_optimizer_budget(
    limits: %{
      requests: 100,
      input_tokens: 500_000,
      output_tokens: 50_000,
      usd: 5.00
    },
    pricing: %{
      "input_per_million" => 0.75,
      "output_per_million" => 4.50,
      "source_url" => "https://developers.openai.com/api/docs/pricing"
    },
    default_max_output_tokens: 1_000
  )

task_lm =
  "openai:" <> System.fetch_env!("OPENAI_MODEL")
  |> Imp.req_llm(api_key: System.fetch_env!("OPENAI_API_KEY"))
  |> Imp.budgeted_lm(budget, max_output_tokens: 1_000)

program = Imp.predict(signature, lm: task_lm)

{:ok, result} =
  Imp.Experiment.check(program, optimizer, data, metric,
    budget: budget,
    evaluation_options: [max_concurrency: 4]
  )

result.provenance.optimizer_budget.snapshot
```

The wrapper reserves the worst-case envelope before each call, disables cache
and hidden transport retries, counts actual Req transport attempts, records
provider-reported usage in the calling process, and releases completed
reservations. The selected parameter Artifact retains the ledger through
selection; the Result retains the final ledger after held-out evaluation.
Resume with `initial: Imp.Optimizer.Budget.snapshot(budget)`. Any unresolved
reservation is conservatively charged once, so a crash cannot restore capacity.
Stop the budget process when the owning workflow ends.

## An optimizer changes a program; it does not replace measurement

Public optimizers whose declared kind is `:program` can be called through
`Imp.optimize/3..5`. Constructor, workflow, and training families use their
documented entry points because they return a different kind of result. The
families differ in what they are allowed to change and what information they
need.

| Family | Start here when |
| --- | --- |
| `LabeledFewShot` | You already have good labeled examples and want to attach demonstrations directly. |
| `BootstrapFewShot`, `RandomSearch`, `KNNFewShot` | You want to generate, sample, search, or retrieve demonstrations. |
| `COPRO`, `InferRules`, `SignatureOptimizer` | The instruction or rule attached to a predictor is the likely bottleneck. |
| `MIPROv2`, `SIMBA` | You want a broader search over instructions and demonstrations. |
| `GEPA` | Your metric can provide useful textual feedback for reflective instruction evolution. |
| `Ensemble`, `BetterTogether` | You want to combine programs or compose named prompt and weight steps. |
| `BootstrapFinetune`, `GRPO` | You intend to change model weights through an explicit trainer. |
| `Imp.Optimize.Anything` | The thing being improved is a text or JSON-safe artifact rather than an Imp program. |

All optimizer modules currently remain experimental in Imp's canonical public
API policy. This table helps you choose which mechanism to investigate; it is
not a stability promise.

An optimizer that needs a proposal or reflection model requires one
explicitly. GEPA and COPRO do not fabricate local proposals or silently reuse
the task program's LM. Training optimizers likewise require an explicit
trainer; creating a training-shaped report is not a weight update.

COPRO accepts a validation or development set so it composes with the shared
optimizer interface, but its pinned DSPy 3.2.1 behavior scores and selects
coordinate candidates on the training set. `Imp.Experiment.check/5` can still
compare COPRO's returned program with the baseline on a separate selection
split; that outer comparison does not change COPRO's internal search semantic.

These names describe mechanisms, not guaranteed improvement. GEPA and MIPROv2
have positive matched evidence on one frozen TREC task. COPRO, SIMBA, and
InferRules execute their defining mechanisms through the public API, but do
not yet have comparable positive effectiveness evidence; treat their
effectiveness as experimental on your task.

MIPROv2 has two intentional proposal modes. Its default BEAM-native mode uses
explicit program structure and predictor signatures. Pinned DSPy 3.2.1
fidelity accepts bounded, caller-supplied source text and reproduces DSPy's
program-aware proposal information. Imp does not inspect source by default,
and it does not claim that provider-adapter retry counts match Python.

Optimizer reports describe the candidates, scores, selected parameters,
stopping condition, and failures from that run:

```elixir
compiled = Imp.optimize!(program, optimizer, trainset, selection_set)
report = Imp.Optimizer.Report.fetch(compiled)

{report.best_score, report.metadata}
```

The optimizer modules remain pre-1.0 surfaces. Some have strong task-scoped
effectiveness results; others currently have lifecycle or mechanism evidence
without broad positive results. The source repository's
[evidence guide](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md)
records that distinction separately from this API cookbook.

## Multi-stage programs are normal Elixir modules

Real applications often need more than one model call. Define a struct that
implements `Imp.Module.call/2`. To let optimizers address its predictors, also
implement the paired named-predictor callbacks:

```elixir
defmodule SupportPipeline do
  @behaviour Imp.Module

  defstruct [:analyze, :route]

  def new do
    %__MODULE__{
      analyze: Imp.predict("ticket -> analysis: string"),
      route:
        Imp.predict(
          "ticket, analysis -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
        )
    }
  end

  @impl true
  def optimizer_predictors(program) do
    [analyze: program.analyze, route: program.route]
  end

  @impl true
  def update_optimizer_predictor(program, :analyze, update) do
    %{program | analyze: update.(program.analyze)}
  end

  def update_optimizer_predictor(program, :route, update) do
    %{program | route: update.(program.route)}
  end

  @impl true
  def call(program, %{ticket: ticket}) do
    with {:ok, first} <- Imp.call(program.analyze, %{ticket: ticket}),
         analysis <- Imp.get(first, :analysis),
         {:ok, result} <- Imp.call(program.route, %{ticket: ticket, analysis: analysis}) do
      {:ok, result}
    end
  end
end
```

The application owns the control flow. The optimizer sees two named predictors
and may update only the one it targets. Imp validates that both callbacks agree
before proposal or evaluation work begins.

### Expose other optimizable components without exposing runtime authority

Predictor instructions are not the only useful program state. A composed
program may expose a routing policy, playbook, tool description, or another
JSON-safe value through the paired `optimizer_components/1` and
`update_optimizer_components/2` callbacks:

```elixir
alias Imp.Optimizer.{Component, Parameter}

def optimizer_components(program) do
  parameter = Parameter.new("router/mode", :artifact, program.mode)

  [
    Component.new(parameter,
      description: "Routing strategy",
      constraints: %{"type" => "string", "enum" => ["fast", "careful"]}
    )
  ]
end

def update_optimizer_components(program, %{"router/mode" => mode}),
  do: %{program | mode: mode}
```

The updater receives the complete custom-component batch only after Imp has
validated every digest, value constraint, and dependency graph. It must be a
pure function returning the same program struct. Imp commits no partial result
if validation or application fails.

Descriptions and constraints belong to the freshly constructed trusted
program. Artifacts contain only component IDs, kinds, JSON values, and hash
lineage; they cannot serialize handlers, tools, policies, credentials, or
weaken the rules used when they are applied. Built-in predictor, playbook, and
ReAct tool lenses appear through the same `Imp.ProgramParameters.components/1`
inventory. GEPA instruction candidates also apply through this atomic path
while retaining their existing named-predictor API.

The complete version in the [deployment example](../examples/deployment/README.md)
adds typed intermediate metadata, persistence, hot reload, concurrent service,
and failure containment.

## Artifacts carry selected parameters into trusted code

`Imp.Experiment.check/5` returns an `Imp.Optimizer.Artifact` containing a
champion and challenger parameter state. Persist the result and artifact:

```elixir
result_path = "/secure/support-router-result.json"
artifact_path = "/secure/support-router-parameters.json"

:ok = Imp.Experiment.Result.write!(result, result_path)
:ok = Imp.Optimizer.Artifact.write!(result.artifact, artifact_path)
```

Both writers use private permissions and atomic replacement. Results contain
scores, counts, redacted provenance, and artifact linkage by default—not raw
dataset rows.

In a fresh process, reconstruct the trusted program and live clients, then
apply the selected parameters:

```elixir
artifact = Imp.Optimizer.Artifact.read!(artifact_path)

live_program =
  SupportPipeline.new()
  |> Imp.with_lm(lm)

selected_program = Imp.Optimizer.Artifact.apply(artifact, live_program)
```

Use `Imp.save!/3` and `Imp.load!/2` when the entire program is one of Imp's
portable built-in shapes. Use `Imp.Optimizer.Artifact` when application code
owns a custom module and only selected parameters should be serialized.

Predictor-only artifacts retain their compatible signatures, demonstrations,
and configs. Programs exposing playbook, tool, or custom components instead
carry the revisioned parameter set from `Imp.ProgramParameters.snapshot/1`.
Applying either form to fresh code refuses incompatible component identities,
kinds, constraints, or dependency graphs rather than partially installing
state.

Credentials and executable callbacks belong to runtime configuration, never
inside either artifact.

## Choose a program shape for the failure mode you need to control

| Program | Use it when |
| --- | --- |
| `Imp.predict/2` | One model call maps named inputs to named outputs. |
| `Imp.chain_of_thought/2` | A declared reasoning field helps produce the final output. |
| `Imp.best_of_n/3` | You can score several independent attempts and keep the best. |
| `Imp.refine/3` | A failed attempt can improve from metric feedback. |
| `Imp.assert/3` | A named constraint can drive bounded self-repair. |
| `Imp.parallel/1,2,3` | Homogeneous batches or heterogeneous program/input pairs should run concurrently under one bound. |
| `Imp.react/3` | The model should choose tools and submit a validated answer. |
| `Imp.react_v2/3` | Parallel tool calls and truthful call IDs must survive in history. |
| `Imp.avatar/3` | Each typed action needs its own timeout and failure isolation. |
| `Imp.program_of_thought/2`, `Imp.code_act/3` | The model should act through sandboxed Elixir code. |
| `Imp.rlm/2` | A controller needs a bounded recursive sandbox for large inputs. |

These are different program shapes, not an escalation ladder every application
must climb.

## Tools stay typed and policy-controlled

Create a tool from a name, description, function, and input schema:

```elixir
lookup =
  Imp.tool(
    :lookup,
    "Look up a city by country",
    fn %{country: "France"} -> %{city: "Paris"} end,
    schema: %{
      "type" => "object",
      "properties" => %{"country" => %{"type" => "string"}},
      "required" => ["country"]
    }
  )

program = Imp.react("question -> answer", [lookup], lm: lm, tool_policy: [:lookup, :submit])
```

`react/3` is the upstream-shaped fail-fast loop. `react_v2/3` records unknown
and failed tools as observations and preserves parallel call IDs. `avatar/3`
runs one typed action per turn with per-tool timeout isolation.

MCP catalogs import into the same `Imp.Tool` values through
`Imp.MCP.import_tools/1`. Importing a tool does not make it safe; keep
side-effecting tools behind an explicit policy. Transport clients convert MCP
results to text by default. Use `result_mode: :structured` when the application
needs the server's `structuredContent` value; an explicit `nil`, `false`, `0`,
or empty value is data, while an absent field falls back to text.

## Retrieval is a program dependency, not hidden prompt state

Build a retriever and wrap a program explicitly:

```elixir
memory =
  Imp.memory([
    %{id: "billing", text: "Billing owns invoices, charges, and refunds."},
    %{id: "security", text: "Security owns unauthorized access and leaked credentials."}
  ])

program =
  "ticket, context -> team"
  |> Imp.predict(lm: lm)
  |> Imp.rag(memory, query_field: :ticket, context_field: :context, k: 2)
```

The retrieved documents are recorded in prediction metadata. Use
`Imp.retrieve/3` directly when the application—not a wrapper—should decide how
retrieved context enters the task.

`Imp.knn/3` and `Imp.nearest/2` provide local example retrieval. Dataset
loaders and embedding providers live under `Imp.Datasets` and
`Imp.Embeddings`. Loaders such as `Imp.Datasets.gsm8k(path)` read an existing
local JSONL file; unlike DSPy's convenience helpers, they never download a
dataset. A source checkout can fetch canonical benchmark data explicitly
through the repository-only workflow in the
[evidence guide](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md);
fetching is deliberately not an implicit side effect of a runtime loader.
`Imp.Embeddings.BagOfWords` is the deterministic local baseline. A production
semantic embedding provider must return one numeric vector for each input
text.

## Streaming sends partial output without changing the program

`Imp.stream/3` can ask a capable provider for chunks. `Imp.collect/3` consumes
the same path and joins the final text:

```elixir
stream = Imp.stream(program, %{question: "Why is the sky blue?"}, provider_stream: true)

Enum.each(stream, fn chunk ->
  send(self(), {:model_chunk, chunk})
end)
```

Provider-native thinking and tool-call chunks retain their type in metadata.
`provider_stream: true` is strict for program shape: a composed program that
does not expose a streamable predictor returns
`{:error, {:provider_stream_unsupported, module}}` from `Imp.collect/3` rather
than pretending a locally split final response arrived from the provider.
Omit the option when post-call local chunking is the behavior you want.

## Conversation history is task-shaped data

History uses the program's own field names rather than exposing provider chat
objects throughout your application:

```elixir
history =
  Imp.history([
    %{question: "Capital of France?", answer: "Paris"},
    %{question: "Capital of Germany?", answer: "Berlin"}
  ])

program = Imp.predict("question, history -> answer", lm: lm)
{:ok, prediction} = Imp.call(program, %{question: "Capital of Italy?", history: history})
```

`Imp.History.dump/1` and `load/1` cross a JSON boundary.
`Imp.History.redact/1` supports safe inspection.

## Optimize Anything uses the same selection discipline for other artifacts

`Imp.Optimize.Anything.run/3` improves text, named text components, or a
JSON-safe structured map. The evaluator scores the real artifact; after the
run, the application explicitly installs `best_candidate/1`:

```elixir
result =
  Imp.Optimize.Anything.run(
    "mode=slow",
    fn candidate -> if candidate =~ "mode=fast", do: 1.0, else: 0.0 end,
    config: [
      engine: [max_candidate_proposals: 1, parallel: false],
      reflection: [
        custom_candidate_proposer: fn _candidate, _component, _records, _iteration ->
          "mode=fast"
        end
      ]
    ]
  )

selected = Imp.Optimize.Anything.best_candidate(result)
```

The validation set chooses a candidate; it is not an untouched test set. Test
the selected artifact separately. In a real run, replace the explicit proposer
with a reflection model or your own proposal function. A map seed enables
structured mode, which derives an exact schema from the seed and rejects key,
type, list-length, or unselected-component drift.

## Production code binds credentials and owns concurrency

Keep API keys in runtime configuration. Persist parameters or supported
program values without secrets, then bind live clients after loading.

Imp's parallel evaluation and call helpers use bounded supervised tasks and
preserve result order. Your application still owns admission policy, request
timeouts, overload behavior, and the process that serves the current program.
The [deployment example](../examples/deployment/README.md) shows one complete
GenServer boundary.

Use `Imp.parallel(program, inputs, opts)` for one program over a batch. Use
`Imp.parallel([{program_a, inputs_a}, {program_b, inputs_b}], opts)` when a
workflow needs different programs in the same bounded pool. Pair lists may be
nested; the result retains that shape, and one failed call stays local to its
slot.

Wrap calls with `Imp.trace/2` when you need a retained trace, then use
`Imp.inspect_history/2`, optimizer progress subscriptions, and telemetry to
understand failures. Imp does not keep a retroactive global last-call buffer.
Inspection is redacted by default; turn on more detail deliberately where the
data policy permits it.

Continue with:

- [Learning Path](LEARNING_PATH.md) for a guided end-to-end build.
- [Production Operations](PRODUCTION_OPERATIONS.md) for runtime behavior.
- [Operations Reference](OPERATIONS_REFERENCE.md) for durable jobs, resume,
  batches, and external protocols.
- [Imp for DSPy Users](IMP_FOR_DSPY_USERS.md) for the upstream concept map.
