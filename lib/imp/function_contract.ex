defmodule Imp.FunctionContract do
  @moduledoc """
  Internal. Checks that a user-supplied callback (a metric, reward, or similar
  function) has one of the expected arities, raising an `ArgumentError` that
  names the calling context when it does not. Optimizers and predict programs
  use this to fail loudly at construction time instead of mid-run.
  """

  def validate!(fun, arities, context, noun) when is_list(arities) do
    if Enum.any?(arities, &is_function(fun, &1)) do
      :ok
    else
      raise ArgumentError,
            "#{context} expects #{article(noun)} #{noun} function with arity #{format_arities(arities)}; got: #{inspect(fun)}"
    end
  end

  def validate!(fun, arity, context, noun) when is_integer(arity),
    do: validate!(fun, [arity], context, noun)

  defp article(noun) do
    if noun in ["metric", "reward"], do: "a", else: "an"
  end

  defp format_arities([arity]), do: to_string(arity)

  defp format_arities(arities) do
    arities
    |> Enum.map(&to_string/1)
    |> case do
      [first, second] -> "#{first} or #{second}"
      values -> Enum.join(values, ", ")
    end
  end
end
