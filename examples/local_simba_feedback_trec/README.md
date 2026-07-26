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
cd examples/local_simba_feedback_trec
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
