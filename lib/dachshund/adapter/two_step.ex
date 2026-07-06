defmodule Dachshund.Adapter.TwoStep do
  @moduledoc "Two-step adapter that asks the model to plan, then answer."

  @behaviour Dachshund.Adapter

  @impl true
  def format(signature, inputs, opts) do
    plan_signature =
      Dachshund.Signature.prepend_output(signature, %{
        name: :plan,
        desc: "Short plan before final answer"
      })

    plan_signature = %{
      plan_signature
      | instructions:
          plan_signature.instructions <>
            "\nFirst produce a brief plan, then the final fields."
    }

    Dachshund.Adapter.Chat.format(plan_signature, inputs, opts)
  end

  @impl true
  def parse(signature, raw, opts), do: Dachshund.Adapter.Chat.parse(signature, raw, opts)
end

defmodule Dachshund.Adapter.BAML do
  @moduledoc "BAML-style structured adapter alias over the JSON adapter."

  @behaviour Dachshund.Adapter

  @impl true
  def format(signature, inputs, opts), do: Dachshund.Adapter.JSON.format(signature, inputs, opts)

  @impl true
  def parse(signature, raw, opts), do: Dachshund.Adapter.JSON.parse(signature, raw, opts)
end
