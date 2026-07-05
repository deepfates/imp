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

  @doc "Configures process/global DSPy settings such as `:lm` and `:adapter`."
  defdelegate configure(opts), to: Settings

  @doc "Returns the effective DSPy settings for the current process."
  defdelegate settings(), to: Settings, as: :get

  @doc "Runs `fun` with temporary process-local DSPy settings."
  defdelegate context(opts, fun), to: Settings

  @doc "Builds a `DSPy.Signature` from a string or structured map."
  defdelegate signature(spec, instructions \\ nil), to: Signature, as: :new

  @doc "Builds a `DSPy.Example` row for train/dev/test data."
  defdelegate example(fields), to: Example, as: :new

  @doc "Builds a `DSPy.Prediction` from output fields."
  defdelegate prediction(fields), to: Prediction, as: :new

  @doc "Returns the majority value across prediction fields."
  defdelegate majority(predictions, opts \\ []), to: DSPy.Predict.Aggregation

  @doc "Creates a basic signature-to-prediction program."
  def predict(signature, opts \\ []), do: Predict.new(signature, opts)

  @doc "Creates a program that asks for a `reasoning` field before final outputs."
  def chain_of_thought(signature, opts \\ []), do: ChainOfThought.new(signature, opts)

  @doc "Creates a simple ReAct-style program with tools."
  def react(signature, tools, opts \\ []), do: ReAct.new(signature, tools, opts)

  @doc "Creates a program-of-thought module backed by the BEAM-safe sandbox."
  def program_of_thought(signature, opts \\ []),
    do: DSPy.Predict.ProgramOfThought.new(signature, opts)

  @doc "Creates a CodeAct-style module backed by the BEAM-safe sandbox."
  def code_act(signature, tools \\ [], opts \\ []),
    do: DSPy.Predict.CodeAct.new(signature, tools, opts)

  @doc "Creates an iterative provider-tool-call ReAct module with reserved submit."
  def react_v2(signature, tools, opts \\ []), do: DSPy.Predict.ReActV2.new(signature, tools, opts)

  @doc "Creates a Recursive Language Model controller loop for large-context exploration."
  def rlm(signature, opts \\ []), do: DSPy.Predict.RLM.new(signature, opts)

  @doc "Creates an OpenAI-compatible LM client."
  def openai(model, opts \\ []), do: DSPy.Clients.OpenAI.new(model, opts)

  @doc "Creates a LiteLLM-compatible LM client."
  def litellm(model, opts \\ []), do: DSPy.Clients.LiteLLM.new(model, opts)

  @doc "Creates a local OpenAI-compatible LM client."
  def local_lm(model, opts \\ []), do: DSPy.Clients.Local.new(model, opts)

  @doc "Creates a Databricks OpenAI-compatible LM client."
  def databricks(model, opts \\ []), do: DSPy.Clients.Databricks.new(model, opts)
end
