defmodule DSEx do
  @moduledoc """
  Declarative self-improving language-model programs for Elixir.

  DSEx programs are ordinary Elixir structs with explicit signatures,
  injectable model clients, measurable behavior, and optimizer-driven
  improvement loops.
  """

  alias DSEx.{Example, Prediction, Settings, Signature}
  alias DSEx.Predict.{ChainOfThought, Predict, ReAct}

  @doc "Configures process/global settings such as `:lm` and `:adapter`."
  defdelegate configure(opts), to: Settings

  @doc "Returns the effective settings for the current process."
  defdelegate settings(), to: Settings, as: :get

  @doc "Runs `fun` with temporary process-local settings."
  defdelegate context(opts, fun), to: Settings

  @doc "Builds a declarative input/output contract."
  defdelegate signature(spec, instructions \\ nil), to: Signature, as: :new

  @doc "Builds a train/dev/test example row."
  defdelegate example(fields), to: Example, as: :new

  @doc "Builds a structured prediction."
  defdelegate prediction(fields), to: Prediction, as: :new

  @doc "Reads a field from a prediction or example."
  def get(container, key, default \\ nil)

  def get(%Prediction{} = prediction, key, default),
    do: Prediction.get(prediction, key, default)

  def get(%Example{} = example, key, default),
    do: Example.get(example, key, default)

  @doc "Returns the majority value across predictions."
  defdelegate majority(predictions, opts \\ []), to: DSEx.Predict.Aggregation

  @doc "Creates a basic signature-to-prediction program."
  def predict(signature, opts \\ []), do: Predict.new(signature, opts)

  @doc "Creates a program that asks for reasoning before final outputs."
  def chain_of_thought(signature, opts \\ []), do: ChainOfThought.new(signature, opts)

  @doc "Creates a simple ReAct-style program with tools."
  def react(signature, tools, opts \\ []), do: ReAct.new(signature, tools, opts)

  @doc "Creates a program-of-thought module backed by the BEAM-safe sandbox."
  def program_of_thought(signature, opts \\ []),
    do: DSEx.Predict.ProgramOfThought.new(signature, opts)

  @doc "Creates a CodeAct-style module backed by the BEAM-safe sandbox."
  def code_act(signature, tools \\ [], opts \\ []),
    do: DSEx.Predict.CodeAct.new(signature, tools, opts)

  @doc "Creates an iterative provider-tool-call ReAct module with reserved submit."
  def react_v2(signature, tools, opts \\ []),
    do: DSEx.Predict.ReActV2.new(signature, tools, opts)

  @doc "Creates a recursive controller loop for large-context exploration."
  def rlm(signature, opts \\ []), do: DSEx.Predict.RLM.new(signature, opts)

  @doc "Calls any DSEx program struct."
  def call(%module{} = program, inputs) do
    if function_exported?(module, :call, 2) do
      module.call(program, inputs)
    else
      {:error, {:not_callable, module}}
    end
  end

  def call(other, _inputs), do: {:error, {:not_callable, other}}

  @doc "Creates an OpenAI-compatible LM client."
  def openai(model, opts \\ []), do: DSEx.Clients.OpenAI.new(model, opts)

  @doc "Creates a LiteLLM-compatible LM client."
  def litellm(model, opts \\ []), do: DSEx.Clients.LiteLLM.new(model, opts)

  @doc "Creates a local OpenAI-compatible LM client."
  def local_lm(model, opts \\ []), do: DSEx.Clients.Local.new(model, opts)

  @doc "Creates a Databricks OpenAI-compatible LM client."
  def databricks(model, opts \\ []), do: DSEx.Clients.Databricks.new(model, opts)
end
