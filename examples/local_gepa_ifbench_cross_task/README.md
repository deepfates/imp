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

The treatment is sealed to the exact predecessor in `contract.json`. From a
clean checkout with the pinned GEPA artifact and Python environment available,
run it once with:

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
