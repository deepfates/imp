defmodule Imp.Adapter do
  @moduledoc "Adapter behaviour for rendering prompts and parsing LM outputs."

  @callback format(Imp.Signature.t(), map(), keyword()) :: list(map())
  @callback parse(Imp.Signature.t(), term(), keyword()) ::
              {:ok, Imp.Prediction.t()} | {:error, term()}

  def validate_adapter(nil), do: {:ok, nil}

  def validate_adapter(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :format, 3) and
         function_exported?(module, :parse, 3) do
      {:ok, module}
    else
      {:error, "expected an adapter module exporting format/3 and parse/3"}
    end
  end

  def validate_adapter(_adapter) do
    {:error, "expected nil or an adapter module exporting format/3 and parse/3"}
  end

  def format(adapter, signature, inputs, opts \\ []), do: adapter.format(signature, inputs, opts)
  def parse(adapter, signature, raw, opts \\ []), do: adapter.parse(signature, raw, opts)
end
