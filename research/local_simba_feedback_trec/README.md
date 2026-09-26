# Local SIMBA semantic-feedback TREC front door

This example freezes a provider-free ordinary SIMBA workflow before any model
call. It asks one already-local `llama3.2:3b` model to route real TREC fine-label
questions to two opaque services, lets SIMBA propose instruction-only rules
from semantic metric feedback, selects on a separate validation split, and only
then evaluates the persisted selection on untouched held-out rows. The selected
parameter artifact is applied to a freshly loaded ordinary program in a new OS
BEAM process.

The source is the pinned `CogComp/trec` material already retained in
`benchmarks/data/confidence-calibration-trec-fine.jsonl`. The frozen split is
balanced by route: 20 train rows (10 each), 6 validation rows (3 each), and 40
held-out rows (20 each). Every `source_id` used here is disjoint from both the
earlier SIMBA TREC task and the source-guided GRPO TREC task. The route meanings
are:

- `K11`: question asking for a description, definition, reason, or manner
- `K47`: question asking for an entity such as an animal, product, substance,
  or other thing

Those meanings are deliberately absent from the source program instruction.
Only a train-row metric result may tell reflection what the expected and
predicted codes mean. Validation returns a scalar score without feedback, and
held-out labels do not enter compilation or selection.

The frozen optimizer uses `bsize: 5`, two candidates, four steps, zero demos,
one concurrency slot, cache disabled, and transport retry disabled. Its hard
envelope is 130 optimization transports plus 40 transports each for baseline,
selected, and fresh-process held-out evaluation: 250 total. It uses the existing
local model inventory and requires no download or provider. Budget for roughly
the already-installed 2 GB model plus up to 6 GB working memory; requests are
sequential and each has a 120-second timeout.

Run the no-model contract tests from the repository root:

```sh
mix test test/local_simba_feedback_trec_example_test.exs
```

After explicit execution is chosen, the ordinary front door is:

```sh
cd research/local_simba_feedback_trec
mix deps.get
mix run run.exs
```

The run is allowed to select the baseline when every mutation is neutral or
worse. It must not count any of these cheaper substitutes as success: returning
a valid enum without semantic accuracy, reflecting validation/test labels,
reusing predecessor source rows, creating a mutation that is never rendered by
the task program, writing an artifact that does not reproduce the selected
parameters, hitting cache instead of transport, or loading a different model or
parameter snapshot in the fresh process. A completed result is evidence about
this one task/model only, not general SIMBA effectiveness or DSPy parity.

## Retained execution

The frozen run stopped before selection or held-out evaluation. It completed
four SIMBA steps and 52 one-attempt local transports, including six reflection
calls and one reflection containing semantic metric feedback. The exact 3B
model nevertheless returned labeled or malformed values such as `route\nK47`
under the strict single-field contract. Sixteen task parses failed, no mutation
candidate was admitted, and the runner failed closed. The immutable summary is
[`exercised-stopped-result.json`](exercised-stopped-result.json).

This is a model/typed-format measurement failure, not a SIMBA loss. Held-out
labels remained unopened, and no selected artifact or fresh-process behavior
was claimed.

The current separately named condition is
`local-simba-feedback-trec-structured-v2`. Imp now exposes ReqLLM's native
Ollama JSON-schema capability and `SingleField` uses an exact one-field schema
when choice scoring is unavailable. This changes only the provider transport
constraint: the same task contract and digest, local model and digest, split
rows, opaque route meanings, prompts, metric feedback, validation boundary,
SIMBA seed/configuration, budgets, and strict typed parser remain frozen. It
does not strip or normalize any predecessor output. The v1 stopped result
remains immutable, and v2 may still produce no mutation or no held-out lift.

The v2 execution is retained in
`exercised-structured-v2-stopped-result.json`. Ollama honored the schema and
returned exact one-field JSON objects, but the then-current `SingleField`
parser treated those JSON strings as bare enum values. All 46 task transports
therefore failed before reflection, selection, or held-out access. Imp now
decodes only an exact one-field schema object—extra fields, arrays, quoted
scalars, labels, and prose still fail—without changing the frozen task.

The current condition is separately identified as
`local-simba-feedback-trec-schema-decode-v3`. Its sole change from v2 is that
source-correct exact-envelope decode repair; task/model/splits/prompts/metric,
optimizer configuration, seed, budgets, and one-attempt policy remain
unchanged. V1 and v2 remain stopped and immutable. V3 will execute once and may
honestly retain baseline or show no held-out lift.

The v3 execution is retained in
`exercised-schema-decode-v3-stopped-result.json`. All 46 task outputs parsed,
the baseline scored `0.50`, all four search steps completed without a runtime
error, and semantic feedback reached each of six reflection calls. No
reflection yielded a predictor instruction change that SIMBA could admit, so
the runner stopped before selection and held-out access. The exact reflection
response text was not retained; empty, irrelevant, and instruction-identical
advice therefore remain unresolved rather than inferred. This is a real
reflection/no-mutation result for one task/model, not optimizer ineffectiveness.

## Frozen Phi-4 reflection condition

The separately named current treatment is
`local-simba-feedback-trec-phi4-reflection-v4`, frozen in
`usefulness-v4-treatment.json`. It preserves the exact V3 task contract, source
rows and 20/6/40 split, `llama3.2:3b` task model, task and reflection prompts,
semantic metric, strict schema, SIMBA `bsize`, candidate/step/demo budgets,
seed, one-attempt policy, and cache-disabled runtime. Its only treatment change
is the already-local `phi4:latest` reflection model at manifest digest
`ac896e5b8b34a1f4efa7b14d7520725140d5512484457fab45d2a4ea14c69dba`.

V4 atomically retains every exact reflection output and its `module_advice`
keys. A candidate counts only when nonblank advice for the named `main`
predictor is appended and rendered into real task messages. Validation alone
selects the winner, with baseline retained on ties; held-out rows remain closed
until the selected artifact is written. Positive, neutral, negative, or
baseline selection are all valid outcomes. Even a positive result would remain
specific to this task and exact local model pair rather than proving general
SIMBA effectiveness or DSPy parity.

The immutable V4 execution is retained in
`exercised-phi4-reflection-v4-stopped-result.json`. It completed four search
steps and 53 one-attempt local transports: 46 task calls and seven reflection
calls. Every exact Phi-4 response used the correct `main` key and discussed the
semantic route distinction, but every `module_advice.main` value was a nested
object instead of the string instruction required by DSPy's
`dict[str, str]` contract. Imp did not stringify or otherwise normalize those
objects, admitted no candidate, persisted the completed optimization stage,
kept held-out rows closed, and unloaded both models successfully.

This exposes a source-level boundary gap: Imp's reflection signature currently
describes `module_advice` only as a generic map, so its JSON schema does not
constrain each advice value to a string. The stopped run is therefore an
incomplete usefulness measurement, not a SIMBA loss or a conclusion about
Phi-4. No V4 held-out or fresh-process result exists.
