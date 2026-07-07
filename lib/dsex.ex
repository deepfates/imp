defmodule DSEx do
  @moduledoc """
  Declarative self-improving language-model programs for Elixir.

  DSEx programs are ordinary Elixir structs with explicit signatures,
  injectable model clients, measurable behavior, and optimizer-driven
  improvement loops.
  """

  alias DSEx.{Example, Prediction, Settings, Signature, Tool}
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

  @doc "Marks which fields of an example are inputs."
  defdelegate with_inputs(example, keys), to: Example

  @doc "Returns the input fields for an example."
  defdelegate inputs(example), to: Example

  @doc "Returns the label/output fields for an example."
  defdelegate labels(example), to: Example

  @doc "Builds a structured prediction."
  defdelegate prediction(fields), to: Prediction, as: :new

  @doc "Converts a prediction or example to its field map."
  def to_map(container)

  def to_map(%Prediction{} = prediction), do: Prediction.to_map(prediction)
  def to_map(%Example{} = example), do: Example.to_map(example)

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

  @doc "Attaches demonstrations to a prediction program or example."
  def with_demos(program_or_example, demos)

  def with_demos(%Predict{} = predict, demos), do: Predict.with_demos(predict, demos)
  def with_demos(%Example{} = example, demos), do: Example.with_demos(example, demos)

  @doc "Creates a program that asks for reasoning before final outputs."
  def chain_of_thought(signature, opts \\ []), do: ChainOfThought.new(signature, opts)

  @doc "Creates an iterative provider-tool-call ReAct program with reserved submit."
  def react(signature, tools, opts \\ []), do: ReAct.new(signature, tools, opts)

  @doc "Creates a named tool for ReAct programs and agents."
  def tool(name, description, run, opts \\ []), do: Tool.new(name, description, run, opts)

  @doc "Creates a program-of-thought module backed by the BEAM-safe sandbox."
  def program_of_thought(signature, opts \\ []),
    do: DSEx.Predict.ProgramOfThought.new(signature, opts)

  @doc "Creates a CodeAct-style module backed by the BEAM-safe sandbox."
  def code_act(signature, tools \\ [], opts \\ []),
    do: DSEx.Predict.CodeAct.new(signature, tools, opts)

  @doc "Creates a recursive controller loop for large-context exploration."
  def rlm(signature, opts \\ []), do: DSEx.Predict.RLM.new(signature, opts)

  @doc "Calls any DSEx program struct."
  defdelegate call(program, inputs), to: DSEx.Module

  @doc "Creates a ReqLLM-backed multi-provider LM client."
  def req_llm(model_spec, opts \\ []), do: DSEx.Clients.ReqLLM.new(model_spec, opts)
end
