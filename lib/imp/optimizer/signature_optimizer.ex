defmodule Imp.Optimizer.SignatureOptimizer do
  @behaviour Imp.Optimizer
  @moduledoc """
  Optimizes one program signature instruction while leaving demonstrations unchanged.

  A program with multiple named predictors must select one explicitly with
  `predictor:`. The proposal sees the complete program structure, but candidate
  application changes only that predictor. This keeps the search opportunity
  explicit instead of silently rewriting every stage with one instruction.

  Pass `proposer_lm:` for task-aware proposals grounded in the program and
  training examples. Pass `candidates:` for explicit manual search. Supplying
  both is rejected rather than silently ignoring one source. With neither,
  the optimizer remains provider-free and reports that it used the native
  fallback proposal set.

  Candidate selection is performed only on the required validation set. The
  original program is always evaluated and wins equal-score ties.

  `proposal_response_format: :required` binds each proposer call to an exact
  one-instruction JSON Schema envelope. `:auto` uses that envelope when the LM
  advertises schema support; `:off` retains the pinned text-compatible parser.
  Invalid structured responses become explicit proposal fallbacks rather than
  executable explanatory prose. Ordinary proposer failures are likewise
  retained as fallbacks, while operational route, cost, budget, transport, and
  cancellation guards abort before candidate evaluation.
  """

  defstruct [
    :metric,
    :proposer_lm,
    :predictor,
    candidates: [],
    num_candidates: 5,
    seed: 0,
    temperature: 1.0,
    view_data_batch_size: 10,
    proposal_response_format: :off,
    extra_instructions: []
  ]

  @option_schema [
    candidates: [type: {:list, :string}, default: []],
    proposer_lm: [type: {:custom, Imp.LM, :validate_lm, []}, default: nil],
    predictor: [type: {:custom, __MODULE__, :validate_predictor, []}, default: nil],
    num_candidates: [type: :pos_integer, default: 5],
    seed: [type: :integer, default: 0],
    temperature: [
      type: {:custom, __MODULE__, :validate_temperature, []},
      default: 1.0
    ],
    view_data_batch_size: [type: :non_neg_integer, default: 10],
    proposal_response_format: [
      type: {:in, [:off, :auto, :required]},
      default: :off
    ],
    extra_instructions: [type: {:list, :string}, default: []]
  ]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(
      metric,
      [2, 3],
      "Imp.Optimizer.SignatureOptimizer.new/2",
      "metric"
    )

    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.SignatureOptimizer.new/2")

    if opts[:candidates] != [] and not is_nil(opts[:proposer_lm]) do
      raise ArgumentError,
            "SignatureOptimizer accepts either explicit :candidates or :proposer_lm, not both"
    end

    struct!(__MODULE__, Map.new(opts) |> Map.put(:metric, metric))
  end

  @doc false
  def validate_temperature(value) when is_number(value) and value >= 0, do: {:ok, value}
  def validate_temperature(_value), do: {:error, "expected a non-negative number"}

  @doc false
  def validate_predictor(nil), do: {:ok, nil}
  def validate_predictor(value) when is_atom(value) or is_binary(value), do: {:ok, value}
  def validate_predictor(_value), do: {:error, "expected nil, an atom, or a string"}

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :required},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok,
       compile(
         optimizer,
         program,
         Imp.Optimizer.fetch_dataset!(opts, :trainset),
         Imp.Optimizer.fetch_dataset!(opts, :validation)
       )}
    end
  end

  @doc false
  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    predictor = selected_predictor!(program, optimizer.predictor)
    {candidates, proposal} = proposals(optimizer, program, trainset, predictor)

    compiled =
      Imp.Optimizer.InstructionSearch.compile(
        program,
        optimizer.metric,
        trainset,
        devset,
        candidates,
        predictor: predictor
      )

    search = Imp.Optimizer.Report.fetch(compiled)

    errors =
      Enum.map(proposal.errors, &%{stage: :proposal, reason: inspect(&1)}) ++ search.errors

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :signature_optimizer,
        best_score: search.best_score,
        candidate_count: search.candidate_count,
        candidates: search.candidates,
        errors: errors,
        metadata: %{
          proposal_mode: proposal.mode,
          proposal_status: proposal.status,
          proposal_calls: proposal.calls,
          proposal_errors: proposal.errors,
          proposal_response_format: optimizer.proposal_response_format,
          requested_candidates: length(candidates),
          baseline_score: search.metadata[:baseline_score],
          predictor: predictor,
          selected_instruction:
            Imp.Optimizer.InstructionSearch.current_instruction(compiled, predictor),
          search: %{
            optimizer: search.optimizer,
            status: search.metadata[:status],
            successful_candidates: search.metadata[:successful_candidates]
          }
        }
      })

    Imp.Optimizer.Report.attach(compiled, report)
  end

  defp proposals(
         %__MODULE__{candidates: [_ | _] = candidates},
         _program,
         _trainset,
         _predictor
       ) do
    {candidates, %{mode: :manual, status: :ok, calls: 0, errors: []}}
  end

  defp proposals(%__MODULE__{} = optimizer, program, trainset, predictor) do
    opts = [
      lm: optimizer.proposer_lm,
      count: optimizer.num_candidates,
      seed: optimizer.seed,
      temperature: optimizer.temperature,
      view_data_batch_size: optimizer.view_data_batch_size,
      proposal_response_format: optimizer.proposal_response_format,
      extra_instructions: optimizer.extra_instructions,
      instruction_target: predictor,
      predictor_name: predictor,
      preserve_slots: true
    ]

    {candidates, proposal} =
      Imp.Optimizer.InstructionProposer.propose_with_report(program, trainset, opts)

    mode = if optimizer.proposer_lm, do: :language_model, else: :native_fallback
    {candidates, Map.put(proposal, :mode, mode)}
  end

  defp selected_predictor!(program, requested) do
    predictors = Imp.ProgramParameters.predictors(program)

    case {requested, predictors} do
      {nil, [%{name: name}]} ->
        name

      {nil, []} ->
        raise ArgumentError,
              "SignatureOptimizer requires a program with at least one optimizer predictor"

      {nil, predictors} ->
        names = Enum.map(predictors, & &1.name)

        raise ArgumentError,
              "SignatureOptimizer requires :predictor for a multi-predictor program; available predictors: #{inspect(names)}"

      {name, predictors} ->
        if Enum.any?(predictors, &(&1.name == name)) do
          name
        else
          names = Enum.map(predictors, & &1.name)

          raise ArgumentError,
                "SignatureOptimizer predictor #{inspect(name)} is not exposed by the program; available predictors: #{inspect(names)}"
        end
    end
  end
end
