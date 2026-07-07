defmodule DSEx.Adapter.TwoStep do
  @moduledoc "Two-step adapter that asks the model to plan, then answer."

  @behaviour DSEx.Adapter

  @impl true
  def format(signature, inputs, opts) do
    plan_signature =
      DSEx.Signature.prepend_output(signature, %{
        name: :plan,
        desc: "Short plan before final answer"
      })

    plan_signature = %{
      plan_signature
      | instructions:
          plan_signature.instructions <>
            "\nFirst produce a brief plan, then the final fields."
    }

    DSEx.Adapter.Chat.format(plan_signature, inputs, opts)
  end

  @impl true
  def parse(signature, raw, opts), do: DSEx.Adapter.Chat.parse(signature, raw, opts)
end
