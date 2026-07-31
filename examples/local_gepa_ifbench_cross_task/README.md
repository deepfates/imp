# Source-disjoint GEPA on IFBench

This bounded example asks a release-relevant question left open by the matched
TREC result: does Imp GEPA retain useful behavior on a different task family?
It uses the pinned GEPA paper artifact's real IFBench data and two-predictor
program, exact executable instruction checks, source-exact reflective feedback,
and three predeclared optimizer seeds.

The frozen slice follows upstream split ownership: 16 rows from paper-train,
24 distinct rows from paper-validation, and 48 rows from the independent test
file. The test file is not decoded until GEPA has returned its selected program.
The task and reflection model is the same local LM Studio
`qwen/qwen3.6-35b-a3b@4bit` artifact, loaded under the exact identifier recorded
in `contract.json`. This run has zero provider spend.

The preregistered outcome is deliberately narrow. Success requires positive
mean test lift over the paired baseline and improvement in all three seeds;
otherwise this condition is neutral or negative. Either result is retained.
Even a success is C3-style source-disjoint evidence only: it is not the full
IFBench paper protocol, matched DSPy evidence, C4 replication, C5 comparative
advantage, or general GEPA effectiveness.

Build and verify the frozen rows without a model:

```sh
python3 scripts/build_gepa_ifbench_cross_task.py \
  --gepa-root tmp/gepa-artifact \
  --out examples/local_gepa_ifbench_cross_task/data
mix test test/local_gepa_ifbench_cross_task_example_test.exs
```

V1's original sealed envelope remains in `contract-v1.json`. Its immutable
stopped result is `exercised-result.json`.

The separately named V2 in `contract.json` keeps the data, seeds, optimizer,
metric, temperatures, output ceilings, and go rule unchanged. It explicitly
disables reasoning after a one-call synthetic typed-format canary returned a
valid final field with zero reasoning tokens, and binds the context length to
LM Studio's actual loaded-process value. Once V2 is sealed to an exact clean
predecessor, run it once with:

```sh
IMP_GEPA_ROOT="$PWD/tmp/gepa-artifact" \
IMP_GEPA_PYTHON="$PWD/tmp/ifbench-parity-venv/bin/python" \
python3 examples/local_gepa_ifbench_cross_task/run_local.py
```

The coordinator starts only the exact local model identity, verifies that LM
Studio's loaded-process list contains that identity alone, and requires the
OpenAI-compatible global model catalog to route that custom identity exactly
once before it proceeds. It then always unloads the process. Its retained
result is written atomically beside this README.

The sealed V1 run is permanently stopped and incomplete. Its first train
baseline was `0.0`: the local model exhausted the task envelope in
`reasoning_content` and returned no parseable final content. While the first dev
batch was in flight, an omitted post-load context guard found that LM Studio
reported `262144` rather than the sealed `32768`; execution stopped before any
candidate, selection, or test access. `exercised-result.json` retains that
boundary. It is a model-format/launch measurement, not a GEPA outcome, and V1
must not be resumed or rerun.

V2 proved the reasoning-disabled envelope was measurable: its complete 16-row
train and 24-row selection baselines both scored `0.4375`. It was then stopped
before its first optimizer candidate when independent release review required
canonical release-profile reconciliation and a cross-family condition instead
of more GEPA-only execution. The test file remained unopened. The retained
`exercised-result-v2.json` is baseline/format evidence only and V2 must not be
resumed.

The retained `0.4375` values were produced before Imp required pinned
non-English language detection at the scorer boundary. They are therefore
unverified as exact IFBench scores. The format, call completion, stop location,
and unopened-test facts remain valid; the retained files are unchanged.
