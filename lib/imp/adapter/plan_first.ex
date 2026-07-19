defmodule Imp.Adapter.PlanFirst do
  @moduledoc """
  Imp extension adapter that asks the model to plan, then answer.

  This is NOT a DSPy adapter. It prepends a `:plan` output field to the
  signature and delegates rendering and parsing to `Imp.Adapter.Chat`, so the
  model produces a short plan before the final fields. It was previously named
  `Imp.Adapter.TwoStep`; that name now belongs to the faithful port of DSPy
  3.2.1 `TwoStepAdapter` (dee-qt5r), and this extension keeps its behavior
  under an honest Imp name.
  """

  @behaviour Imp.Adapter

  @impl true
  def format(signature, inputs, opts) do
    plan_signature =
      Imp.Signature.prepend_output(signature, %{
        name: :plan,
        desc: "Short plan before final answer"
      })

    plan_signature = %{
      plan_signature
      | instructions:
          plan_signature.instructions <>
            "\nFirst produce a brief plan, then the final fields."
    }

    Imp.Adapter.Chat.format(plan_signature, inputs, opts)
  end

  @impl true
  def parse(signature, raw, opts), do: Imp.Adapter.Chat.parse(signature, raw, opts)
end
