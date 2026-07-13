defmodule DSEx.Optimizer.BootstrapRS do
  @moduledoc """
  Upstream-name alias for random-search few-shot bootstrapping.

  DSPy exposes `BootstrapRS` / `BootstrapFewShotWithRandomSearch` as the
  random-search variant of bootstrap few-shot optimization. DSEx keeps the
  canonical implementation in `DSEx.Optimizer.RandomSearch`; this module exists
  so upstream-oriented users and conformance audits can use the familiar name
  without learning a second implementation.
  """

  defdelegate new(metric, opts \\ []), to: DSEx.Optimizer.RandomSearch
  defdelegate compile(optimizer, program, trainset, devset), to: DSEx.Optimizer.RandomSearch
end

defmodule DSEx.Optimizer.BootstrapFewShotWithRandomSearch do
  @moduledoc """
  Descriptive upstream-name alias for `DSEx.Optimizer.BootstrapRS`.

  Prefer `DSEx.Optimizer.RandomSearch` in new Elixir code. Use this module when
  porting DSPy material that names `BootstrapFewShotWithRandomSearch`.
  """

  defdelegate new(metric, opts \\ []), to: DSEx.Optimizer.RandomSearch
  defdelegate compile(optimizer, program, trainset, devset), to: DSEx.Optimizer.RandomSearch
end
