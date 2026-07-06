defmodule Dachshund.Adapter do
  @moduledoc "Adapter behaviour for rendering prompts and parsing LM outputs."

  @callback format(Dachshund.Signature.t(), map(), keyword()) :: list(map())
  @callback parse(Dachshund.Signature.t(), term(), keyword()) ::
              {:ok, Dachshund.Prediction.t()} | {:error, term()}

  def format(adapter, signature, inputs, opts \\ []), do: adapter.format(signature, inputs, opts)
  def parse(adapter, signature, raw, opts \\ []), do: adapter.parse(signature, raw, opts)
end
