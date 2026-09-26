defmodule Imp do
  @moduledoc """
  Declarative self-improving language-model programs for Elixir.

  Imp programs are ordinary Elixir structs with explicit signatures,
  injectable model clients, measurable behavior, and optimizer-driven
  improvement loops.

  Most application code should start here. The deeper `Imp.*` modules are
  available when you need direct control, but the facade gives the normal flow:
  configure an LM, declare a signature, build a program, call it, evaluate it,
  and improve it.

  ## A tiny deterministic program

      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

      Imp.configure(lm: lm, adapter: Imp.Adapter.Chat)

      program =
        "question -> answer: short_span"
        |> Imp.signature("Answer with the shortest correct span.")
        |> Imp.predict()

      {:ok, prediction} =
        Imp.call(program, %{question: "What city is the Eiffel Tower in?"})

      Imp.get(prediction, :answer)

  ## Production provider boundary

  Swap the LM dependency without changing the task:

      lm =
        Imp.req_llm("openai:" <> System.fetch_env!("OPENAI_MODEL"),
          api_key: System.fetch_env!("OPENAI_API_KEY"),
          temperature: 0
        )

      Imp.configure(lm: lm, adapter: Imp.Adapter.Chat)

  Imp owns the programming layer: signatures, adapters, examples, metrics,
  optimizers, traces, persistence, and telemetry. Provider transport and model
  details belong to ReqLLM.
  """

  alias Imp.{Example, Prediction, Settings, Signature, Tool}

  alias Imp.Predict

  alias Imp.Predict.{
    Assertions,
    Avatar,
    BestOfN,
    ChainOfThought,
    CodeAct,
    KNN,
    MultiChainComparison,
    Parallel,
    ProgramOfThought,
    RAG,
    ReActV2,
    Refine
  }

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
  test, task, or Livebook cell without mutating global defaults. Keys of the
  caller's own, such as a request id, are carried too; Imp's own settings are
  type-checked as in `configure/1`. See `Imp.Settings.context/2`.
  """
  defdelegate context(opts, fun), to: Settings

  @doc """
  Builds a declarative input/output contract.

      Imp.signature("question -> answer: short_span")

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

  @doc "Builds signature-shaped conversation history for history-aware programs."
  defdelegate history(messages \\ []), to: Imp.History, as: :new

  @doc "Appends a signature-shaped turn to conversation history."
  defdelegate append_history(history, turn), to: Imp.History, as: :append

  @doc "Renders recent history turns with secret redaction enabled by default."
  defdelegate inspect_history(history, opts \\ []), to: Imp.Observability

  @doc "Runs a function while collecting selected redacted Imp telemetry events."
  defdelegate trace(fun, opts \\ []), to: Imp.Observability

  @doc "Subscribes the current process to normalized optimizer progress events."
  defdelegate subscribe_optimizer_progress(opts \\ []),
    to: Imp.Observability,
    as: :subscribe_optimizer

  @doc "Detaches an optimizer progress subscription."
  defdelegate unsubscribe_optimizer_progress(subscription),
    to: Imp.Observability,
    as: :unsubscribe_optimizer

  @doc "Enables Imp-scoped logging."
  defdelegate enable_logging(), to: Imp.Observability

  @doc "Disables Imp-scoped logging."
  defdelegate disable_logging(), to: Imp.Observability

  @doc "Converts a prediction or example to its field map."
  def to_map(container)

  def to_map(%Prediction{} = prediction), do: Prediction.to_map(prediction)
  def to_map(%Example{} = example), do: Example.to_map(example)

  def to_map(container) do
    raise ArgumentError,
          "Imp.to_map/1 expects an Imp.Prediction or Imp.Example; got: #{inspect(container)}"
  end

  @doc "Reads a field from a prediction or example."
  def get(container, key, default \\ nil)

  def get(%Prediction{} = prediction, key, default),
    do: Prediction.get(prediction, key, default)

  def get(%Example{} = example, key, default),
    do: Example.get(example, key, default)

  def get(container, _key, _default) do
    raise ArgumentError,
          "Imp.get/3 expects an Imp.Prediction or Imp.Example; got: #{inspect(container)}"
  end

  @doc "Returns the majority value across predictions."
  defdelegate majority(predictions, opts \\ []), to: Imp.Predict.Aggregation

  @doc """
  Creates a basic signature-to-prediction program.

  `Predict` is the first program shape to reach for: one call maps named inputs
  to named outputs. Add demos, metrics, and optimizers before reaching for
  agents or recursive controllers.
  """
  def predict(signature, opts \\ []), do: Predict.new(signature, opts)

  @doc "Executes a program with immutable active playbook guidance."
  def with_playbook(program, %Imp.Playbook{} = playbook),
    do: Imp.Playbook.WithContext.new(program, playbook)

  @doc "Attaches demonstrations to a demo-bearing Imp program or example."
  def with_demos(program_or_example, demos)

  def with_demos(%Example{} = example, demos), do: Example.with_demos(example, demos)

  def with_demos(program, demos), do: Imp.ProgramAccess.put_demos(program, demos)

  @doc "Creates a program that asks for reasoning before final outputs."
  def chain_of_thought(signature, opts \\ []), do: ChainOfThought.new(signature, opts)

  @doc "Creates a self-consistency comparison program over candidate completions."
  def multi_chain_comparison(signature, opts \\ []), do: MultiChainComparison.new(signature, opts)

  @doc "Creates a wrapper that runs a program repeatedly and keeps the best scored prediction."
  def best_of_n(program, metric, opts \\ []), do: BestOfN.new(program, metric, opts)

  @doc "Creates a wrapper that retries a program with feedback until a metric passes."
  def refine(program, metric, opts \\ []), do: Refine.new(program, metric, opts)

  @doc "Builds a named runtime assertion for assertion-guided refinement."
  def assertion(name, predicate, opts \\ []), do: Imp.Assertion.new(name, predicate, opts)

  @doc "Wraps a program with assertion-guided self-refinement."
  def assert(program, assertions, opts \\ []), do: Assertions.new(program, assertions, opts)

  @doc "Runs heterogeneous `{program, inputs}` pairs through one supervised task pool."
  def parallel(exec_pairs) when is_list(exec_pairs), do: Parallel.run(exec_pairs)

  def parallel(exec_pairs, opts) when is_list(exec_pairs) and is_list(opts),
    do: Parallel.run(exec_pairs, opts)

  @doc "Runs one program over a batch of inputs through Imp's supervised task boundary."
  def parallel(program, inputs), do: Parallel.map(program, inputs)

  def parallel(program, inputs, opts), do: Parallel.map(program, inputs, opts)

  @doc """
  Builds a callable embedding-based KNN predictor over an example trainset
  (DSPy `KNN` port). Requires `:vectorizer` — an `Imp.Embeddings` provider.
  """
  def knn(k, trainset, opts \\ []), do: KNN.new(k, trainset, opts)

  @doc "Retrieves nearest examples from an Imp KNN predictor for one input map."
  def nearest(%KNN{} = knn, inputs), do: KNN.call(knn, inputs)

  def nearest(knn, _inputs) do
    raise ArgumentError,
          "Imp.nearest/2 expects an Imp KNN predictor from Imp.knn/3; got: #{inspect(knn)}"
  end

  @doc "Wraps a program with retrieval-augmented context injection."
  def rag(program, retriever, opts \\ []), do: RAG.new(program, retriever, opts)

  @doc "Builds a deterministic in-memory retriever for local RAG workflows."
  def memory(docs, opts \\ []), do: Imp.Retrieve.Memory.new(docs, opts)

  @doc "Calls any Imp retriever and normalizes returned documents."
  defdelegate retrieve(retriever, query, opts \\ []), to: Imp.Retrieve

  @doc """
  Creates a tool-using agent: an `Imp.Predict.ReActV2` program.

  The model calls `tools` natively, one step per request, and the turn ends
  when it answers in text or, for a signature a text answer cannot fill, calls
  `submit`. See `Imp.Predict.ReActV2.new/3` for the options.
  `Imp.Predict.ReAct` is the earlier loop, kept for its byte-faithful
  `mode: :dspy` port of DSPy's `dspy.ReAct`.
  """
  def react(signature, tools, opts \\ []), do: ReActV2.new(signature, tools, opts)

  @doc "Creates a bounded action-history Avatar actor with a reserved Finish action."
  def avatar(signature, tools, opts \\ []), do: Avatar.new(signature, tools, opts)

  @doc "Creates a named tool for ReAct programs and agents."
  def tool(name, description, run, opts \\ []), do: Tool.new(name, description, run, opts)

  @doc "Creates a program-of-thought module backed by the BEAM-safe sandbox."
  def program_of_thought(signature, opts \\ []),
    do: ProgramOfThought.new(signature, opts)

  @doc "Creates a CodeAct-style module backed by the BEAM-safe sandbox."
  def code_act(signature, tools \\ [], opts \\ []),
    do: CodeAct.new(signature, tools, opts)

  @doc "Creates a recursive controller loop for large-context exploration."
  def rlm(signature, opts \\ []), do: Imp.Predict.RLM.new(signature, opts)

  @doc "Creates a lazy RLM input that can be loaded with a controller `load` action."
  def rlm_serializable(name, loader, opts \\ []),
    do: Imp.Predict.RLM.sandbox_serializable(name, loader, opts)

  @doc "Calls any Imp program struct."
  defdelegate call(program, inputs), to: Imp.Module

  @doc """
  Starts an addressable program run with ordered semantic events and cancellation.

  Pass `authorize: fun` to require a protocol-neutral decision before each
  validated external ReActV2 or RLM tool effect. The function receives an
  `Imp.Execution.Authorization` and must return `:allow`, `{:deny, reason}`, or
  `{:cancel, reason}`. A crash, timeout, malformed response, or vanished run
  owner denies the effect. Programs that do not support explicit execution
  capabilities fail closed when `:authorize` is present.

  `event_sink: fun` receives redacted events serially from a run-owned delivery
  process. A slow sink delays its own later events and delivery barriers, but it
  cannot delay `cancel_run/3` or owner-death cleanup. Event sinks should normally
  forward events to their host mailbox and return promptly.

  Pass `admission: {pool, limit}` to count the run in a pool the host names,
  with its own limit; a full pool returns `{:error, :busy}` at once. See
  `Imp.Run.start/3`.
  """
  defdelegate start_run(program, inputs, opts \\ []), to: Imp.Run, as: :start

  @doc "Cooperatively cancels an addressable program run and its supervised task."
  defdelegate cancel_run(run, reason \\ :cancelled, timeout \\ 5_000),
    to: Imp.Run,
    as: :cancel

  @doc """
  Streams one program call as an Enumerable of chunks.

  Pass `provider_stream: true` to execute the real program while yielding
  provider chunks from its named predictors. Supply `stream_listeners:` to
  select fields from intermediate predictors. A final typed `Imp.Prediction`
  is yielded by default after the composed program finishes. Without provider
  streaming, the program runs once and its result is chunked locally.
  """
  defdelegate stream(program, inputs, opts \\ []), to: Imp.Streaming

  @doc """
  Streams one program call and joins the chunks into a string.

  If any chunk fails, collection stops and returns `{:error, reason}` rather
  than partial output.
  """
  defdelegate collect(program, inputs, opts \\ []), to: Imp.Streaming

  @doc """
  Returns a copy of an Imp program pinned to `lm`.

  This is the public rebinding path for programs loaded from portable artifacts.
  Saved provider programs retain non-secret provider configuration, but never
  credentials, so bind a newly configured LM before calling them:

      loaded
      |> Imp.with_lm(Imp.req_llm(System.fetch_env!("IMP_MODEL"), api_key: api_key))
      |> Imp.call(%{question: "What changed?"})

  Core predictors, callback wrappers, evaluators, and optimizer-produced KNN
  few-shot and ensemble graphs are supported. Rebinding traverses the complete
  executable graph and pins every nested predictor to the supplied LM.
  """
  def with_lm(program, lm) do
    case Imp.LM.validate_lm(lm) do
      {:ok, nil} -> raise ArgumentError, "Imp.with_lm/2 requires a configured LM"
      {:ok, validated} -> Imp.ProgramAccess.put_lm(program, validated)
      {:error, message} -> raise ArgumentError, "invalid LM for Imp.with_lm/2: #{message}"
    end
  end

  @doc """
  Evaluates a program against examples with a metric.

  This is the facade form of:

      devset
      |> Imp.Evaluate.new(metric, opts)
      |> Imp.Evaluate.run(program)
  """
  def evaluate(program, devset, metric, opts \\ []) do
    devset
    |> Imp.Evaluate.new(metric, opts)
    |> Imp.Evaluate.run(program)
  end

  @doc "Builds a metric that compares one prediction field to the same example field."
  defdelegate exact_match(field \\ :answer), to: Imp.Metrics

  @doc "Returns a structured extractive-QA metric result for one prediction/answer pair."
  defdelegate extractive_qa(prediction, answer, opts \\ []), to: Imp.Metrics

  @doc "Returns a structured classification metric result for one prediction/label pair."
  defdelegate classification(prediction, label, opts \\ []), to: Imp.Metrics

  @doc "Summarizes classification rows into precision, recall, F1, and accuracy."
  defdelegate classification_report(rows, opts \\ []), to: Imp.Metrics

  @doc """
  Compiles a program with an optimizer.

  Returns `{:ok, compiled_program}` or `{:error, reason}`, mirroring
  `Imp.train/4`. Use `Imp.optimize!/3` when you want the compiled program
  directly and a raise on failure.

  Optimizer modules declare their dataset requirements through the
  `Imp.Optimizer` behaviour. Use `Imp.optimize/4` for optimizers that need a
  validation set and `Imp.optimize/3` for trainset-only optimizers. A non-empty
  keyword list in the fourth position supplies invocation options to a
  trainset-only optimizer; invocation options alongside a validation set belong
  in `Imp.optimize/5`. Operational route, cost, budget, transport, and explicit
  cancellation guards remain raised even through this non-bang facade; they are
  not ordinary candidate failures.
  """
  def optimize(program, optimizer, trainset),
    do: run_optimizer(program, optimizer, [trainset: trainset], :program)

  def optimize(program, optimizer, trainset, [_ | _] = validation_or_opts) do
    if Keyword.keyword?(validation_or_opts) do
      run_optimizer(
        program,
        optimizer,
        Keyword.put(validation_or_opts, :trainset, trainset),
        :program
      )
    else
      run_optimizer(
        program,
        optimizer,
        [trainset: trainset, validation: validation_or_opts],
        :program
      )
    end
  end

  def optimize(program, optimizer, trainset, validation),
    do: run_optimizer(program, optimizer, [trainset: trainset, validation: validation], :program)

  def optimize(program, optimizer, trainset, validation, opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.optimize/5 expects keyword invocation options")

    run_optimizer(
      program,
      optimizer,
      Keyword.merge(opts, trainset: trainset, validation: validation),
      :program
    )
  end

  def optimize(_program, _optimizer, _trainset, _validation, _opts),
    do: raise(ArgumentError, "Imp.optimize/5 expects keyword invocation options")

  @doc """
  Compiles a program with an optimizer, raising on failure.

  Same contract as `optimize/3`, `optimize/4`, and `optimize/5`, but returns
  the compiled program directly. A call that could never run (not an
  optimizer, a training optimizer, a missing validation set, options the
  optimizer refused) raises `ArgumentError`; an optimization that failed
  raises `Imp.Error` whose `:reason` is the term `optimize` would have
  returned.
  """
  def optimize!(program, optimizer, trainset),
    do: run_optimizer!(program, optimizer, [trainset: trainset], :program, "Imp.optimize!/3")

  def optimize!(program, optimizer, trainset, [_ | _] = validation_or_opts) do
    opts =
      if Keyword.keyword?(validation_or_opts),
        do: Keyword.put(validation_or_opts, :trainset, trainset),
        else: [trainset: trainset, validation: validation_or_opts]

    run_optimizer!(program, optimizer, opts, :program, "Imp.optimize!/4")
  end

  def optimize!(program, optimizer, trainset, validation),
    do:
      run_optimizer!(
        program,
        optimizer,
        [trainset: trainset, validation: validation],
        :program,
        "Imp.optimize!/4"
      )

  def optimize!(program, optimizer, trainset, validation, opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.optimize!/5 expects keyword invocation options")

    run_optimizer!(
      program,
      optimizer,
      Keyword.merge(opts, trainset: trainset, validation: validation),
      :program,
      "Imp.optimize!/5"
    )
  end

  def optimize!(_program, _optimizer, _trainset, _validation, _opts),
    do: raise(ArgumentError, "Imp.optimize!/5 expects keyword invocation options")

  @doc """
  Executes a training optimizer through the explicit training lifecycle.

  The result is tagged and contains a `Imp.Optimizer.TrainingResult`. SFT
  returns `status: :job_created`; synchronous reinforcement training
  returns `status: :completed` with the rebound program. When a training
  optimizer owns multiple independent provider jobs, `TrainingResult.jobs` is
  exhaustive and the singular `TrainingResult.job` is `nil`.
  """
  def train(program, optimizer, trainset, opts \\ [])

  def train(program, optimizer, trainset, opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.train/4 expects keyword invocation options")

    case run_optimizer(program, optimizer, Keyword.put(opts, :trainset, trainset), :training) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def train(_program, _optimizer, _trainset, _opts),
    do: raise(ArgumentError, "Imp.train/4 expects keyword invocation options")

  @doc "Returns the explicit execution capabilities declared by an optimizer."
  defdelegate optimizer_capabilities(optimizer), to: Imp.Optimizer, as: :capabilities

  defp run_optimizer!(program, optimizer, opts, kind, api) do
    case run_optimizer(program, optimizer, opts, kind) do
      {:ok, result} ->
        result

      {:error, reason} ->
        case optimizer_error(api, optimizer, reason) do
          nil -> raise Imp.Error, message: "#{api} failed: #{inspect(reason)}", reason: reason
          %ArgumentError{} = error -> raise error
          message -> raise ArgumentError, message
        end
    end
  end

  defp run_optimizer(program, optimizer, opts, kind) do
    with {:ok, result} <- Imp.Optimizer.run(optimizer, program, opts, kind) do
      {:ok, result}
    end
  end

  defp optimizer_error(api, optimizer, {:not_an_optimizer, _value}),
    do:
      "#{api} expects an optimizer struct implementing Imp.Optimizer; got: #{inspect(optimizer)}"

  defp optimizer_error(api, _optimizer, {:optimizer_kind_mismatch, :program, :training}),
    do: "#{api} received a training optimizer; use Imp.train/4"

  defp optimizer_error(api, _optimizer, {:optimizer_kind_mismatch, :program, kind}),
    do: "#{api} cannot execute an optimizer of kind #{inspect(kind)} through program optimization"

  defp optimizer_error(api, _optimizer, {:missing_dataset, :validation}),
    do: "#{api} requires a validation set; use Imp.optimize/4 or Imp.optimize/5"

  # An optimizer that refused its configuration raised `ArgumentError`; that
  # is a call that could never run, so it is raised again as it was.
  defp optimizer_error(_api, _optimizer, {:optimizer_failed, _module, %ArgumentError{} = error}),
    do: error

  defp optimizer_error(api, _optimizer, {:optimizer_capabilities_failed, module, reason}) do
    "#{api} could not read the capabilities of #{inspect(module)}: " <>
      if(is_exception(reason), do: Exception.message(reason), else: inspect(reason))
  end

  defp optimizer_error(_api, _optimizer, _reason), do: nil

  @doc "Returns a JSON-safe portable representation of an Imp program."
  defdelegate dump(program), to: Imp.Saving
  defdelegate dump(program, opts), to: Imp.Saving

  @doc """
  Loads a program from the portable map `dump/1` returns.

  Returns `{:ok, program}` or `{:error, %ArgumentError{}}`; see
  `Imp.Saving.load/2`.
  """
  defdelegate load(state, opts \\ []), to: Imp.Saving

  @doc "Loads a program from the portable map `dump/1` returns, raising on failure."
  defdelegate load!(state, opts \\ []), to: Imp.Saving

  @doc "Writes an Imp program artifact to disk as JSON."
  defdelegate save!(program, path), to: Imp.Saving
  defdelegate save!(program, path, opts), to: Imp.Saving

  @doc "Reads a program artifact `save!/2` wrote to disk; see `Imp.Saving.read!/2`."
  defdelegate read!(path, opts \\ []), to: Imp.Saving

  @doc "Creates a ReqLLM-backed multi-provider LM client."
  def req_llm(model_spec, opts \\ []), do: Imp.Clients.ReqLLM.new(model_spec, opts)

  @doc """
  Starts a prospective request, token, and USD ledger for live optimization.

  Supply `:limits`, `:pricing`, and `:default_max_output_tokens`. A prior
  `Imp.Optimizer.Budget.snapshot/1` may be passed as `:initial`; unresolved
  reservations are then conservatively charged once instead of restoring spend
  capacity after a crash.

  Wrap every task and proposal LM with `budgeted_lm/3`; the wrapper records
  ReqLLM provider usage for each call and releases its reservation afterward.
  """
  def start_optimizer_budget(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Imp.start_optimizer_budget/1 expects a keyword list"
    end

    Imp.Optimizer.Budget.start_link(opts)
  end

  def start_optimizer_budget(_opts),
    do: raise(ArgumentError, "Imp.start_optimizer_budget/1 expects a keyword list")

  @doc """
  Wraps an LM with prospective request/token/USD admission.

  The wrapper caps output, disables cache and hidden retries, and rejects calls
  before transport when their worst-case reservation would exceed the ledger.
  """
  def budgeted_lm(lm, budget, opts \\ [])

  def budgeted_lm(lm, budget, opts) when is_pid(budget) and is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Imp.budgeted_lm/3 expects keyword options"
    end

    unknown = Keyword.keys(opts) -- [:max_output_tokens]

    if unknown != [] do
      raise ArgumentError, "Imp.budgeted_lm/3 received unknown options: #{inspect(unknown)}"
    end

    max_output_tokens =
      case Keyword.fetch(opts, :max_output_tokens) do
        {:ok, value} -> value
        :error -> raise ArgumentError, "Imp.budgeted_lm/3 requires :max_output_tokens"
      end

    unless is_integer(max_output_tokens) and max_output_tokens > 0 do
      raise ArgumentError, ":max_output_tokens must be a positive integer"
    end

    case Imp.LM.validate_lm(lm) do
      {:ok, lm} ->
        %Imp.LM.Budgeted{
          inner: lm,
          budget: budget,
          max_output_tokens: max_output_tokens
        }

      {:error, reason} ->
        raise ArgumentError, "invalid LM for Imp.budgeted_lm/3: #{reason}"
    end
  end

  def budgeted_lm(_lm, _budget, _opts),
    do: raise(ArgumentError, "Imp.budgeted_lm/3 expects an LM, budget pid, and keyword options")
end
