defmodule Imp.Optimizer.BootstrapRS do
  @moduledoc """
  Upstream-name alias for random-search few-shot bootstrapping.

  DSPy exposes `BootstrapRS` / `BootstrapFewShotWithRandomSearch` as the
  random-search variant of bootstrap few-shot optimization. Imp keeps the
  canonical implementation in `Imp.Optimizer.RandomSearch`; this module exists
  so upstream-oriented users and conformance audits can use the familiar name
  without learning a second implementation.
  """

  defdelegate new(metric, opts \\ []), to: Imp.Optimizer.RandomSearch

  def compile(optimizer, program, trainset, devset \\ nil, opts \\ []) do
    Imp.Optimizer.RandomSearch.compile(optimizer, program, trainset, devset, opts)
  end
end

defmodule Imp.Optimizer.BootstrapFewShotWithRandomSearch do
  @moduledoc """
  Descriptive upstream-name alias for `Imp.Optimizer.BootstrapRS`.

  Prefer `Imp.Optimizer.RandomSearch` in new Elixir code. Use this module when
  porting DSPy material that names `BootstrapFewShotWithRandomSearch`.
  """

  defdelegate new(metric, opts \\ []), to: Imp.Optimizer.RandomSearch

  def compile(optimizer, program, trainset, devset \\ nil, opts \\ []) do
    Imp.Optimizer.RandomSearch.compile(optimizer, program, trainset, devset, opts)
  end
end
