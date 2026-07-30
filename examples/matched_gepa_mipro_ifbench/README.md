# Matched GEPA and MIPROv2 on IFBench

This directory owns the three-seed, three-arm comparison of Imp and
pinned DSPy 3.2.1 on the source-disjoint IFBench task. It intentionally does
not reuse or expand the earlier seven-arm design draft.

Both runtimes execute the same two-stage program, frozen 16/32/64 splits,
task and optimizer routes, seeds, task messages, executable constraint metric,
and family-specific semantic opportunities. Every selected program is sealed
before either runtime may decode held-out rows. The paired coordinator grants
provider authority only after both no-model preflights pass, and stops both
peers if either runtime crosses an identity, privacy, transport, parsing,
budget, or artifact guard.

The result may be negative. It is evidence only for this task, these models,
and GEPA/MIPROv2 under the sealed budgets; it cannot establish general
instruction-optimizer effectiveness, paper-family replication, or BEAM
superiority.

Run the fail-closed preflight from the repository root:

```sh
python3 examples/matched_gepa_mipro_ifbench/run_paired.py --preflight-only
```

After the live preflight is retained and the manifest is sealed, the same
command without `--preflight-only` is the only authorized live entry.
