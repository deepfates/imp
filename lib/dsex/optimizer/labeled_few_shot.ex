defmodule DSEx.Optimizer.LabeledFewShot do
  @behaviour DSEx.Optimizer
  @moduledoc """
  Compile a predictor by attaching the first labeled examples as demos.

  This optimizer does not call the language model or score candidates. It is the
  deterministic few-shot baseline: take up to `k` examples from the trainset and
  attach them as demonstrations. The compiled program carries an optimizer
  report that records the selected examples.
  """

  defstruct k: 4

  @option_schema [
    k: [type: :non_neg_integer, default: 4]
  ]

  def new(opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.LabeledFewShot.new/1")
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
    with :ok <- DSEx.Optimizer.reject_options(DSEx.Optimizer.invocation_options(opts)) do
      {:ok, compile(optimizer, program, DSEx.Optimizer.fetch_dataset!(opts, :trainset))}
    end
  end

  def compile(%__MODULE__{k: k}, program, trainset) do
    {demos, errors} = take_demos(trainset, k)
    compiled = if errors == [], do: put_demos(program, demos), else: program

    compiled
    |> DSEx.Optimizer.Report.attach(
      DSEx.Optimizer.Report.new(%{
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
    case DSEx.ProgramAccess.predict(program) do
      nil -> program
      _predict -> DSEx.with_demos(program, demos)
    end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
