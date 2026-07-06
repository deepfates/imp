defmodule DSEx.Adapter do
  @moduledoc "Adapter behaviour for rendering prompts and parsing LM outputs."

  @callback format(DSEx.Signature.t(), map(), keyword()) :: list(map())
  @callback parse(DSEx.Signature.t(), term(), keyword()) ::
              {:ok, DSEx.Prediction.t()} | {:error, term()}

  def format(adapter, signature, inputs, opts \\ []), do: adapter.format(signature, inputs, opts)
  def parse(adapter, signature, raw, opts \\ []), do: adapter.parse(signature, raw, opts)
end
