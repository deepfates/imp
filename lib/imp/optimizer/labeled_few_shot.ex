defmodule Imp.Optimizer.LabeledFewShot do
  @behaviour Imp.Optimizer
  @moduledoc """
  Compile a program by attaching labeled examples as demonstrations.

  This optimizer does not call the language model or score candidates. It is the
  deterministic few-shot baseline: select up to `k` examples from the trainset
  for every exposed predictor and attach them as demonstrations. Its report
  therefore has `best_score: nil`; scores used to admit the compiled program
  belong to the surrounding evaluation or `Imp.Experiment.Result`.

  `k` applies independently to each predictor. Report `candidate_count` and
  `metadata.selected_assignment_count` count predictor-example assignments, so
  a two-predictor program with `k: 1` can report two selected assignments. The
  `selected_by_predictor` map gives the corresponding per-predictor counts.

  A trainset example may contain the union of fields needed by a composed
  program. Each predictor's adapter renders only the input and output fields in
  that predictor's own signature; unrelated fields are ignored.

  ## Selection behavior and determinism

  Like DSPy 3.2.1, the defaults are `k: 16`, `sample: true`, and seed zero.
  Repeated compiles therefore select the same no-replacement sample. Set
  `sample: false` for DSPy's ordered first-`k` path. Multi-predictor programs
  receive separate draws from one advancing RNG stream, matching the upstream
  predictor traversal contract.

  Imp exposes `seed:` as a BEAM-native extension and uses its explicit,
  serializable optimizer RNG instead of Python's process-local `random.Random`.
  This preserves deterministic sampling semantics and checkpoint-friendly state,
  but it does not promise Python's incidental exact subset ordering for the same
  integer seed.
  """

  defstruct k: 16, sample: true, seed: 0

  @option_schema [
    k: [type: :non_neg_integer, default: 16],
    sample: [type: :boolean, default: true],
    seed: [type: :integer, default: 0]
  ]

  @doc """
  Builds the optimizer.

  Options:

    * `:k` — maximum demonstrations per predictor (default `16`)
    * `:sample` — sample without replacement when true; take first `k` when
      false (default `true`)
    * `:seed` — deterministic BEAM optimizer seed (default `0`)
  """
  def new(opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.LabeledFewShot.new/1")
    %__MODULE__{k: opts[:k], sample: opts[:sample], seed: opts[:seed]}
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :unsupported},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok, compile(optimizer, program, Imp.Optimizer.fetch_dataset!(opts, :trainset))}
    end
  end

  @doc false
  def compile(%__MODULE__{} = optimizer, program, trainset) do
    {trainset, errors} = materialize_trainset(trainset)

    {compiled, selections} =
      if errors == [] do
        attach_predictor_demos(program, trainset, optimizer)
      else
        {program, []}
      end

    candidates =
      selections
      |> Enum.flat_map(fn %{predictor: predictor, demos: demos} ->
        Enum.map(demos, &%{predictor: predictor, example: &1})
      end)
      |> Enum.with_index()
      |> Enum.map(fn {%{predictor: predictor, example: example}, index} ->
        %{index: index, predictor: predictor, example: example, selected?: true}
      end)

    compiled
    |> Imp.Optimizer.Report.attach(
      Imp.Optimizer.Report.new(%{
        optimizer: :labeled_few_shot,
        candidate_count: length(candidates),
        candidates: candidates,
        errors: errors,
        metadata: %{
          k_per_predictor: optimizer.k,
          sample: optimizer.sample,
          seed: optimizer.seed,
          predictor_count: length(selections),
          selected_assignment_count: length(candidates),
          selected_by_predictor: Map.new(selections, &{&1.predictor, length(&1.demos)}),
          status: if(errors == [], do: :ok, else: :trainset_error)
        }
      })
    )
  end

  defp materialize_trainset(trainset) do
    {Enum.to_list(trainset), []}
  rescue
    error -> {[], [%{stage: :trainset, reason: error_message(error)}]}
  catch
    kind, reason -> {[], [%{stage: :trainset, reason: error_message({kind, reason})}]}
  end

  defp attach_predictor_demos(program, trainset, optimizer) do
    rng = Imp.Optimizer.Sampling.new(optimizer.seed)

    program
    |> Imp.ProgramParameters.predictors()
    |> Enum.reduce({program, [], rng}, fn %{name: name}, {compiled, selections, rng} ->
      {demos, rng} = select_demos(trainset, optimizer.k, optimizer.sample, rng)
      compiled = Imp.ProgramParameters.put_demos(compiled, name, demos)
      {compiled, [%{predictor: name, demos: demos} | selections], rng}
    end)
    |> then(fn {compiled, selections, _rng} -> {compiled, Enum.reverse(selections)} end)
  end

  defp select_demos(_trainset, 0, _sample, rng), do: {[], rng}
  defp select_demos(trainset, k, false, rng), do: {Enum.take(trainset, k), rng}

  defp select_demos(trainset, k, true, rng) do
    {shuffled, rng} = Imp.Optimizer.Sampling.shuffle(trainset, rng)
    {Enum.take(shuffled, k), rng}
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
