defmodule DSPy.Adapter do
  @moduledoc "Adapter behaviour for rendering prompts and parsing LM outputs."

  @callback format(DSPy.Signature.t(), map(), keyword()) :: list(map())
  @callback parse(DSPy.Signature.t(), term(), keyword()) ::
              {:ok, DSPy.Prediction.t()} | {:error, term()}

  def format(adapter, signature, inputs, opts \\ []), do: adapter.format(signature, inputs, opts)
  def parse(adapter, signature, raw, opts \\ []), do: adapter.parse(signature, raw, opts)
end
