defmodule DSEx.Optimizer.InferRules do
  @moduledoc """
  Upstream-name adapter for signature-level instruction rule induction.

  DSPy exposes `InferRules` as an instruction/rule optimizer. DSEx keeps the
  implementation in `DSEx.Optimizer.SignatureOptimizer`; this module preserves
  the upstream-oriented name while annotating optimizer reports with the
  adapter entry point.
  """

  defstruct [:signature_optimizer]

  def new(metric, opts \\ []) do
    %__MODULE__{signature_optimizer: DSEx.Optimizer.SignatureOptimizer.new(metric, opts)}
  end

  def compile(%__MODULE__{signature_optimizer: optimizer}, program, trainset, devset) do
    compiled = DSEx.Optimizer.SignatureOptimizer.compile(optimizer, program, trainset, devset)

    case DSEx.Optimizer.Report.fetch(compiled) do
      nil ->
        compiled

      report ->
        DSEx.Optimizer.Report.attach(compiled, %{
          report
          | optimizer: :infer_rules,
            metadata:
              report.metadata
              |> Map.put(:adapter, __MODULE__)
              |> Map.put(:implementation, DSEx.Optimizer.SignatureOptimizer)
        })
    end
  end
end
