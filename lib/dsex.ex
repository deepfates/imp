defmodule DSEx do
  @moduledoc """
  Declarative self-improving language-model programs for Elixir.

  DSEx programs are ordinary Elixir structs with explicit signatures,
  injectable model clients, measurable behavior, and optimizer-driven
  improvement loops.

  Most application code should start here. The deeper `DSEx.*` modules are
  available when you need direct control, but the facade gives the normal flow:
  configure an LM, declare a signature, build a program, call it, evaluate it,
  and improve it.

  ## A tiny deterministic program

      lm = %{
        module: DSEx.LM.Static,
        opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
      }

      DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)

      program =
        "question -> answer: short_span"
        |> DSEx.signature("Answer with the shortest correct span.")
        |> DSEx.predict()

      {:ok, prediction} =
        DSEx.call(program, %{question: "What city is the Eiffel Tower in?"})

      DSEx.get(prediction, :answer)

  ## Production provider boundary

  Swap the LM dependency without changing the task:

      lm =
        DSEx.req_llm("openai:" <> System.fetch_env!("OPENAI_MODEL"),
          api_key: System.fetch_env!("OPENAI_API_KEY"),
          temperature: 0
        )

      DSEx.configure(lm: lm, adapter: DSEx.Adapter.Chat)

  DSEx owns the programming layer: signatures, adapters, examples, metrics,
  optimizers, traces, persistence, and telemetry. Provider transport and model
  details belong to ReqLLM.
  """

  alias DSEx.{Example, Prediction, Settings, Signature, Tool}
  alias DSEx.Predict.{ChainOfThought, CodeAct, Predict, ProgramOfThought, RAG, ReAct}

  @doc """
  Configures global settings such as `:lm` and `:adapter`.

  Prefer passing explicit dependencies to individual programs when a program
  must be self-contained. Use `configure/1` for application defaults and
  `context/2` for request-scoped overrides.
  """
  defdelegate configure(opts), to: Settings

  @doc "Returns the effective settings for the current process."
  defdelegate settings(), to: Settings, as: :get

  @doc """
  Runs `fun` with temporary process-local settings.

  This is the preferred way to override the LM or adapter for one request,
  test, task, or Livebook cell without mutating global defaults.
  """
  defdelegate context(opts, fun), to: Settings

  @doc """
  Builds a declarative input/output contract.

      DSEx.signature("question -> answer: short_span")

  Signatures may also be maps when you need explicit constraints.
  """
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

  def to_map(container) do
    raise ArgumentError,
          "DSEx.to_map/1 expects a DSEx.Prediction or DSEx.Example; got: #{inspect(container)}"
  end

  @doc "Reads a field from a prediction or example."
  def get(container, key, default \\ nil)

  def get(%Prediction{} = prediction, key, default),
    do: Prediction.get(prediction, key, default)

  def get(%Example{} = example, key, default),
    do: Example.get(example, key, default)

  def get(container, _key, _default) do
    raise ArgumentError,
          "DSEx.get/3 expects a DSEx.Prediction or DSEx.Example; got: #{inspect(container)}"
  end

  @doc "Returns the majority value across predictions."
  defdelegate majority(predictions, opts \\ []), to: DSEx.Predict.Aggregation

  @doc """
  Creates a basic signature-to-prediction program.

  `Predict` is the first program shape to reach for: one call maps named inputs
  to named outputs. Add demos, metrics, and optimizers before reaching for
  agents or recursive controllers.
  """
  def predict(signature, opts \\ []), do: Predict.new(signature, opts)

  @doc "Attaches demonstrations to a demo-bearing DSEx program or example."
  def with_demos(program_or_example, demos)

  def with_demos(%Predict{} = predict, demos), do: Predict.with_demos(predict, demos)

  def with_demos(%ChainOfThought{predict: predict} = cot, demos),
    do: %{cot | predict: Predict.with_demos(predict, demos)}

  def with_demos(%ProgramOfThought{predict: predict} = pot, demos),
    do: %{pot | predict: Predict.with_demos(predict, demos)}

  def with_demos(%CodeAct{program_of_thought: pot} = code_act, demos),
    do: %{code_act | program_of_thought: with_demos(pot, demos)}

  def with_demos(%RAG{program: program} = rag, demos),
    do: %{rag | program: with_demos(program, demos)}

  def with_demos(%Example{} = example, demos), do: Example.with_demos(example, demos)

  def with_demos(program_or_example, _demos) do
    raise ArgumentError,
          "DSEx.with_demos/2 supports Predict, ChainOfThought, ProgramOfThought, CodeAct, RAG wrappers, and examples; got: #{inspect(program_or_example)}"
  end

  @doc "Creates a program that asks for reasoning before final outputs."
  def chain_of_thought(signature, opts \\ []), do: ChainOfThought.new(signature, opts)

  @doc "Wraps a program with retrieval-augmented context injection."
  def rag(program, retriever, opts \\ []), do: RAG.new(program, retriever, opts)

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

  @doc """
  Evaluates a program against examples with a metric.

  This is the facade form of:

      devset
      |> DSEx.Evaluate.new(metric, opts)
      |> DSEx.Evaluate.run(program)
  """
  def evaluate(program, devset, metric, opts \\ []) do
    devset
    |> DSEx.Evaluate.new(metric, opts)
    |> DSEx.Evaluate.run(program)
  end

  @doc """
  Compiles a program with an optimizer.

  Use `DSEx.optimize/4` for optimizers that need a dev set, such as
  `RandomSearch`, `COPRO`, `MIPROv2`, `SIMBA`, and `GEPA`. Use
  `DSEx.optimize/3` for trainset-only optimizers such as `LabeledFewShot`.
  """
  def optimize(program, optimizer, trainset)

  def optimize(program, %module{} = optimizer, trainset) do
    if function_exported?(module, :compile, 3) do
      module.compile(optimizer, program, trainset)
    else
      raise ArgumentError,
            "#{inspect(module)} cannot compile through DSEx.optimize/3; pass a devset with DSEx.optimize/4"
    end
  end

  def optimize(_program, optimizer, _trainset) do
    raise ArgumentError,
          "DSEx.optimize/3 expects an optimizer struct with compile/3; got: #{inspect(optimizer)}"
  end

  def optimize(program, optimizer, trainset, devset)

  def optimize(program, %module{} = optimizer, trainset, devset) do
    cond do
      function_exported?(module, :compile, 4) ->
        module.compile(optimizer, program, trainset, devset)

      function_exported?(module, :compile, 3) ->
        module.compile(optimizer, program, trainset)

      true ->
        raise ArgumentError,
              "#{inspect(module)} is not a DSEx optimizer with compile/3 or compile/4"
    end
  end

  def optimize(_program, optimizer, _trainset, _devset) do
    raise ArgumentError,
          "DSEx.optimize/4 expects an optimizer struct with compile/4 or compile/3; got: #{inspect(optimizer)}"
  end

  @doc "Returns a JSON-safe portable representation of a DSEx program."
  defdelegate dump(program), to: DSEx.Saving

  @doc "Loads a DSEx program from a portable saved representation."
  defdelegate load(state), to: DSEx.Saving

  @doc "Writes a DSEx program artifact to disk as JSON."
  defdelegate save!(program, path), to: DSEx.Saving

  @doc "Loads a DSEx program artifact from disk."
  defdelegate load!(path), to: DSEx.Saving

  @doc "Creates a ReqLLM-backed multi-provider LM client."
  def req_llm(model_spec, opts \\ []), do: DSEx.Clients.ReqLLM.new(model_spec, opts)
end
