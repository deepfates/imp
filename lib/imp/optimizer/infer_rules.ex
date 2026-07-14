defmodule Imp.Optimizer.InferRules do
  @behaviour Imp.Optimizer
  @moduledoc """
  Upstream-name adapter for signature-level instruction rule induction.

  DSPy exposes `InferRules` as an instruction/rule optimizer. Imp keeps the
  implementation in `Imp.Optimizer.SignatureOptimizer`; this module preserves
  the upstream-oriented name while annotating optimizer reports with the
  adapter entry point.
  """

  defstruct [:signature_optimizer]

  def new(metric, opts \\ []) do
    %__MODULE__{signature_optimizer: Imp.Optimizer.SignatureOptimizer.new(metric, opts)}
  end

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

  def compile(%__MODULE__{signature_optimizer: optimizer}, program, trainset, devset) do
    compiled = Imp.Optimizer.SignatureOptimizer.compile(optimizer, program, trainset, devset)

    case Imp.Optimizer.Report.fetch(compiled) do
      nil ->
        compiled

      report ->
        Imp.Optimizer.Report.attach(compiled, %{
          report
          | optimizer: :infer_rules,
            metadata:
              report.metadata
              |> Map.put(:adapter, __MODULE__)
              |> Map.put(:implementation, Imp.Optimizer.SignatureOptimizer)
        })
    end
  end
end
