defmodule DspyElixir do
  @moduledoc """
  Compatibility wrapper for the `DSPy` namespace.
  """

  defdelegate configure(opts), to: DSPy
  defdelegate settings(), to: DSPy
  defdelegate context(opts, fun), to: DSPy
  defdelegate signature(spec, instructions \\ nil), to: DSPy
  defdelegate example(fields), to: DSPy
  defdelegate prediction(fields), to: DSPy
  defdelegate predict(signature, opts \\ []), to: DSPy
  defdelegate chain_of_thought(signature, opts \\ []), to: DSPy
  defdelegate react(signature, tools, opts \\ []), to: DSPy
end
