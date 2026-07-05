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
  defdelegate majority(predictions, opts \\ []), to: DSPy
  defdelegate predict(signature, opts \\ []), to: DSPy
  defdelegate chain_of_thought(signature, opts \\ []), to: DSPy
  defdelegate react(signature, tools, opts \\ []), to: DSPy
  defdelegate program_of_thought(signature, opts \\ []), to: DSPy
  defdelegate code_act(signature, tools \\ [], opts \\ []), to: DSPy
  defdelegate react_v2(signature, tools, opts \\ []), to: DSPy
  defdelegate rlm(signature, retriever, opts \\ []), to: DSPy
  defdelegate openai(model, opts \\ []), to: DSPy
  defdelegate litellm(model, opts \\ []), to: DSPy
  defdelegate local_lm(model, opts \\ []), to: DSPy
  defdelegate databricks(model, opts \\ []), to: DSPy
end
