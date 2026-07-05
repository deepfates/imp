defmodule DspyElixir do
  @moduledoc """
  Historical package wrapper.

  Prefer `DSPEx` in new code.
  """

  defdelegate configure(opts), to: DSPEx
  defdelegate settings(), to: DSPEx
  defdelegate context(opts, fun), to: DSPEx
  defdelegate signature(spec, instructions \\ nil), to: DSPEx
  defdelegate example(fields), to: DSPEx
  defdelegate prediction(fields), to: DSPEx
  defdelegate get(container, key, default \\ nil), to: DSPEx
  defdelegate majority(predictions, opts \\ []), to: DSPEx
  defdelegate predict(signature, opts \\ []), to: DSPEx
  defdelegate chain_of_thought(signature, opts \\ []), to: DSPEx
  defdelegate react(signature, tools, opts \\ []), to: DSPEx
  defdelegate program_of_thought(signature, opts \\ []), to: DSPEx
  defdelegate code_act(signature, tools \\ [], opts \\ []), to: DSPEx
  defdelegate react_v2(signature, tools, opts \\ []), to: DSPEx
  defdelegate rlm(signature, opts \\ []), to: DSPEx
  defdelegate call(program, inputs), to: DSPEx
  defdelegate openai(model, opts \\ []), to: DSPEx
  defdelegate litellm(model, opts \\ []), to: DSPEx
  defdelegate local_lm(model, opts \\ []), to: DSPEx
  defdelegate databricks(model, opts \\ []), to: DSPEx
end
