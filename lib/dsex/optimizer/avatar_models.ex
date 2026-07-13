defmodule DSEx.Optimizer.Avatar.EvalResult do
  @moduledoc "A scored Avatar input and its action trajectory."

  @enforce_keys [:example, :score]
  defstruct [:example, :score, actions: []]

  @type t :: %__MODULE__{example: map(), score: number(), actions: list()}
end
