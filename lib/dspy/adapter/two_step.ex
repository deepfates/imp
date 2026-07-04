defmodule DSPy.Adapter.TwoStep do
  @moduledoc "Two-step adapter that asks the model to plan, then answer."

  @behaviour DSPy.Adapter

  @impl true
  def format(signature, inputs, opts) do
    plan_signature =
      DSPy.Signature.prepend_output(signature, %{
        name: :plan,
        desc: "Short plan before final answer"
      })

    plan_signature = %{
      plan_signature
      | instructions:
          plan_signature.instructions <>
            "\nFirst produce a brief plan, then the final fields."
    }

    DSPy.Adapter.Chat.format(plan_signature, inputs, opts)
  end

  @impl true
  def parse(signature, raw, opts), do: DSPy.Adapter.Chat.parse(signature, raw, opts)
end

defmodule DSPy.Adapter.BAML do
  @moduledoc "BAML-compatible structured adapter alias over the JSON adapter."

  @behaviour DSPy.Adapter

  @impl true
  def format(signature, inputs, opts), do: DSPy.Adapter.JSON.format(signature, inputs, opts)

  @impl true
  def parse(signature, raw, opts), do: DSPy.Adapter.JSON.parse(signature, raw, opts)
end
