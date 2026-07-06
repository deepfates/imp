# Advanced DSEx

This guide covers DSEx's advanced program-building tools: arbitrary artifact
optimization, Pareto-guided reflection, agent runtimes, MCP-style tool
catalogs, schema constraints, and deterministic benchmark fixtures.

## Gates

Advanced DSEx behavior is part of the production gate. These commands must pass
before release:

```sh
mix production.check
mix integration.check
LIVE_PROVIDER=1 mix live.check
```

`mix production.check` enforces warnings-as-errors compilation, formatting,
documentation generation, public surface checks, and deterministic benchmark
tests. The benchmark suite includes positive controls that must reach threshold
and negative controls that must remain below threshold.

## Optimize Anything

```elixir
artifact = DSEx.Optimize.Anything.new_artifact(:config, "mode=slow")

report =
  DSEx.Optimize.Anything.optimize(
    artifact,
    fn artifact, _examples ->
      if artifact.text =~ "mode=fast", do: 1.0, else: 0.0
    end,
    trials: 1,
    mutation_fn: fn _artifact, _trial, _seed -> "mode=fast" end
  )

report.best.score
#=> 1.0
```

Reports preserve baseline candidates, lineage, diagnostics, evaluator errors,
named artifact parameters, and JSON-safe save/load via
`save_report!/2` and `load_report!/1`.

## Pareto/ASI GEPA

```elixir
artifact = DSEx.Optimize.Anything.new_artifact(:prompt, "Base")

report =
  DSEx.Optimize.GEPA.optimize(
    artifact,
    fn artifact, examples ->
      %{
        per_example_scores:
          Enum.map(examples, &if(String.contains?(artifact.text, &1), do: 1.0, else: 0.0)),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end,
    examples: ["Paris", "concise"],
    generations: 2,
    mutation_fn: fn _artifact, asi, _generation -> Enum.join(asi, "\n") end
  )

report.best.aggregate_score
#=> 1.0
```

GEPA tracks per-example scores, Pareto frontier membership, ASI diagnostics,
candidate lineage, replacement branches, and system-aware merges.

## Agents And MCP

```elixir
tool = DSEx.Tool.new(:double, "double a number", fn %{x: x} -> %{y: x * 2} end)

agent =
  DSEx.Agent.new(:doubler, fn agent, %{x: x}, runtime ->
    DSEx.Agent.call_tool(agent, :double, %{x: x}, runtime)
  end, tools: [tool])

{:ok, %{y: 8}, runtime} = DSEx.Agent.run(agent, %{x: 4})
runtime.traces
```

MCP-style catalogs import external schemas into ordinary `DSEx.Tool` structs:

```elixir
catalog =
  DSEx.MCP.Catalog.new([
    %{name: :lookup, description: "lookup", input_schema: %{required: [:key]}, run: & &1}
  ])

[tool] = DSEx.MCP.import_tools(catalog)
```

Runtime sessions support memory, large context references, tool failures, child
agents, tool policies, final-output streams, incremental trace-event streams,
and trace capture.

## Schema Constraints

```elixir
signature =
  DSEx.Signature.new(%{
    inputs: [:question],
    outputs: [
      %{name: :answer, type: :string, constraints: %{enum: ["yes", "no"]}},
      %{name: :confidence, type: :number, constraints: %{min: 0.0, max: 1.0}}
    ]
  })

DSEx.Signature.json_schema(signature)
```

Supported constraints include enum, numeric bounds, string length, regex
patterns, arrays, nested objects, and optional fields. JSON adapter parse errors
return retry feedback suitable for another model attempt.

## Benchmarks

```elixir
DSEx.Benchmarks.assert_pass!()
```

The current deterministic benchmark fixture covers:

- Ax-style structured extraction with schema constraints.
- Agent/tool execution with trace evidence.
- GEPA prompt optimization.
- Program optimization with a reward fixture where the baseline fails and the
  compiled program passes.
- Arbitrary config optimization.

## Production Boundaries

Advanced DSEx APIs are part of the same release contract as the core facade:
they must pass deterministic tests, compile with warnings as errors, preserve
JSON-safe persistence where applicable, and keep provider credentials out of
saved artifacts.

MCP support covers catalog import plus JSON-RPC HTTP, stdio, and Streamable HTTP
clients. The benchmark fixtures are deterministic regression fixtures for
DSEx behavior, not public leaderboard claims. Provider-native schema APIs and
streaming are explicit provider responsibilities layered over the shared DSEx
contracts and tested through injectable transports.

For real dataset benchmark evidence, use `DSEx.BenchmarkTruth` and
`BENCHMARK_TRUTH.md`. That lane fetches canonical GSM8K/HotPotQA rows, writes
manifests and result artifacts, and keeps research evidence separate from
deterministic production-gate fixtures.
