defmodule Imp.FunctionContract do
  @moduledoc false

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
