defmodule Imp.Optimizer.LabeledFewShot do
  @behaviour Imp.Optimizer
  @moduledoc """
  Compile a predictor by attaching the first labeled examples as demos.

  This optimizer does not call the language model or score candidates. It is the
  deterministic few-shot baseline: take up to `k` examples from the trainset and
  attach them as demonstrations. The compiled program carries an optimizer
  report that records the selected examples.

  ## Selection behavior and determinism

  Selection is `Enum.take(trainset, k)`: the first `min(k, length(trainset))`
  examples in trainset order. No randomness is involved on any path — direct
  `compile/3` and the `Imp.optimize/3` facade run the same selection, and
  compiling the same program and trainset always attaches the same demos.
  When `k` is greater than or equal to the trainset size, the whole trainset
  is attached in order.

  If compiled demos vary between runs, the variation comes from upstream of
  this optimizer — most commonly a shuffled trainset (see the `:seed` option
  of `Imp.Datasets.split/2`). To attach a different demo subset, reorder the
  trainset explicitly before compiling, for example with a seeded
  `Imp.Optimizer.Sampling.shuffle/2`.

  ## Deviation from DSPy

  Upstream `dspy.LabeledFewShot.compile/2` defaults to `sample=True`, which
  draws `k` demos with a fixed-seed RNG (`random.Random(0)`) — deterministic
  per trainset, but not first-`k` — and defaults to `k=16`. Imp implements
  upstream's `sample=False` path (a first-`k` slice) as its only behavior and
  defaults to `k: 4`. There is no sampling option.
  """

  defstruct k: 4

  @option_schema [
    k: [type: :non_neg_integer, default: 4]
  ]

  @doc """
  Builds the optimizer. Accepts `k:` (default `4`), the maximum number of
  demos to attach. Selection is always the deterministic first-`k` slice of
  the trainset; there is no sampling, shuffle, or seed option.
  """
  def new(opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.LabeledFewShot.new/1")
    %__MODULE__{k: opts[:k]}
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

  @doc """
  Attaches the first `min(k, length(trainset))` trainset examples as demos.

  Deterministic: the same program and trainset always produce the same demo
  set, on this path and through `Imp.optimize/3`.
  """
  def compile(%__MODULE__{k: k}, program, trainset) do
    {demos, errors} = take_demos(trainset, k)
    compiled = if errors == [], do: put_demos(program, demos), else: program

    compiled
    |> Imp.Optimizer.Report.attach(
      Imp.Optimizer.Report.new(%{
        optimizer: :labeled_few_shot,
        candidate_count: length(demos),
        candidates:
          demos
          |> Enum.with_index()
          |> Enum.map(fn {example, index} ->
            %{index: index, example: example, selected?: true}
          end),
        errors: errors,
        metadata: %{
          requested_k: k,
          selected_count: length(demos),
          status: if(errors == [], do: :ok, else: :trainset_error)
        }
      })
    )
  end

  defp take_demos(trainset, k) do
    {Enum.take(trainset, k), []}
  rescue
    error -> {[], [%{stage: :trainset, reason: error_message(error)}]}
  catch
    kind, reason -> {[], [%{stage: :trainset, reason: error_message({kind, reason})}]}
  end

  defp put_demos(program, demos) do
    case Imp.ProgramAccess.predict(program) do
      nil -> program
      _predict -> Imp.with_demos(program, demos)
    end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
