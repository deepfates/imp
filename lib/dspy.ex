defmodule DSPy do
  @moduledoc """
  Elixir-native translation of DSPy's programming model.

  DSPy treats language-model workflows as programs with signatures, modules,
  examples, metrics, and optimizers. This package keeps that philosophy while
  using Elixir's own shapes: structs, behaviours, explicit function calls, OTP
  configuration, immutable data, and composable modules.
  """

  alias DSPy.{Example, Prediction, Settings, Signature}
  alias DSPy.Predict.{ChainOfThought, Predict, ReAct}

  defdelegate configure(opts), to: Settings
  defdelegate settings(), to: Settings, as: :get
  defdelegate context(opts, fun), to: Settings
  defdelegate signature(spec, instructions \\ nil), to: Signature, as: :new
  defdelegate example(fields), to: Example, as: :new
  defdelegate prediction(fields), to: Prediction, as: :new

  def predict(signature, opts \\ []), do: Predict.new(signature, opts)
  def chain_of_thought(signature, opts \\ []), do: ChainOfThought.new(signature, opts)
  def react(signature, tools, opts \\ []), do: ReAct.new(signature, tools, opts)
end
