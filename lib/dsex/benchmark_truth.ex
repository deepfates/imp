defmodule DSEx.BenchmarkTruth do
  @moduledoc """
  Reproducible benchmark-truth tooling for canonical DSPy-style tasks.

  These helpers are intentionally separate from `DSEx.Benchmarks`, which holds
  deterministic production-gate fixtures. Benchmark truth works with real
  dataset rows, manifests, and result artifacts so claims can be audited.
  """

  alias DSEx.BenchmarkTruth.{Fetcher, Runner}

  defdelegate fetch(specs, opts \\ []), to: Fetcher
  defdelegate run(opts \\ []), to: Runner
end
