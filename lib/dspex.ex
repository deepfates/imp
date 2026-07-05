defmodule DSPEx do
  @moduledoc """
  Declarative Self-improving Programs for Elixir.

  `DSPEx` is the Elixir-native public facade for building language-model
  systems as ordinary, testable BEAM programs. The compatibility namespace
  `DSPy` remains available because this project tracks upstream DSPy concepts
  and parity, but new teaching material should start here.

  The core cycle is:

  1. Declare a `signature/2`.
  2. Build a program such as `predict/2`, `chain_of_thought/2`, `react_v2/3`,
     or `rlm/2`.
  3. `call/2` the program with inputs.
  4. Evaluate with metrics and optimize when the metric is meaningful.
  """

  alias DSPy.{Example, Prediction, Settings, Signature}
  alias DSPy.Predict.{ChainOfThought, Predict, ReAct}

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
  defdelegate majority(predictions, opts \\ []), to: DSPy.Predict.Aggregation

  @doc "Creates a basic signature-to-prediction program."
  def predict(signature, opts \\ []), do: Predict.new(signature, opts)

  @doc "Creates a program that asks for reasoning before final outputs."
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

  @doc "Creates a recursive controller loop for large-context exploration."
  def rlm(signature, opts \\ []), do: DSPy.Predict.RLM.new(signature, opts)

  @doc "Calls any DSPEx/DSPy program module."
  def call(%module{} = program, inputs) do
    if function_exported?(module, :call, 2) do
      module.call(program, inputs)
    else
      {:error, {:not_callable, module}}
    end
  end

  def call(other, _inputs), do: {:error, {:not_callable, other}}

  @doc "Creates an OpenAI-compatible LM client."
  def openai(model, opts \\ []), do: DSPy.Clients.OpenAI.new(model, opts)

  @doc "Creates a LiteLLM-compatible LM client."
  def litellm(model, opts \\ []), do: DSPy.Clients.LiteLLM.new(model, opts)

  @doc "Creates a local OpenAI-compatible LM client."
  def local_lm(model, opts \\ []), do: DSPy.Clients.Local.new(model, opts)

  @doc "Creates a Databricks OpenAI-compatible LM client."
  def databricks(model, opts \\ []), do: DSPy.Clients.Databricks.new(model, opts)
end
