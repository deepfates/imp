defmodule Imp.Test.FunLM do
  @moduledoc false

  # An LM that is one function of `(messages, opts)`, called once per request,
  # returning `{:ok, output}` or `{:error, reason}` as a provider client does.
  # Tests that script a whole response, `n` completions included, use it.

  @behaviour Imp.LM

  defstruct [:fun]

  def new(fun) when is_function(fun, 2), do: %__MODULE__{fun: fun}

  @impl true
  def generate(%__MODULE__{fun: fun}, messages, opts), do: fun.(messages, opts)
end
