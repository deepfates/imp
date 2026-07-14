defmodule Imp.BenchmarkTruth do
  @moduledoc false

  alias Imp.BenchmarkTruth.{Contract, Fetcher, Integrity, Runner}

  defdelegate current_prompt_contract(), to: Contract
  defdelegate fetch(specs, opts \\ []), to: Fetcher
  defdelegate integrity(tasks, opts \\ []), to: Integrity, as: :check
  defdelegate run(opts \\ []), to: Runner
end
