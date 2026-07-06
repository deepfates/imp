defmodule DSEx.Sandbox do
  @moduledoc """
  BEAM-safe expression sandbox for Program-of-Thought style arithmetic.

  This is not an arbitrary Elixir evaluator. It accepts arithmetic expressions
  over literals and variables, and rejects function calls, aliases, atoms, and
  remote execution.
  """

  @allowed_ops [:+, :-, :*, :/, :div, :rem]

  def eval(expression, vars \\ %{}) when is_binary(expression) do
    with {:ok, ast} <- Code.string_to_quoted(expression),
         {:ok, value} <- eval_ast(ast, Map.new(vars)) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_expression, other}}
    end
  end

  defp eval_ast(value, _vars) when is_integer(value) or is_float(value), do: {:ok, value}

  defp eval_ast({name, _meta, nil}, vars) when is_atom(name) do
    case Map.fetch(vars, name) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:non_numeric_variable, name}}
      :error -> {:error, {:unknown_variable, name}}
    end
  end

  defp eval_ast({op, _meta, [left, right]}, vars) when op in @allowed_ops do
    with {:ok, left} <- eval_ast(left, vars),
         {:ok, right} <- eval_ast(right, vars) do
      apply_op(op, left, right)
    end
  end

  defp eval_ast({:-, _meta, [value]}, vars) do
    with {:ok, value} <- eval_ast(value, vars), do: {:ok, -value}
  end

  defp eval_ast(other, _vars), do: {:error, {:unsafe_ast, other}}

  defp apply_op(:+, left, right), do: {:ok, left + right}
  defp apply_op(:-, left, right), do: {:ok, left - right}
  defp apply_op(:*, left, right), do: {:ok, left * right}
  defp apply_op(:/, _left, 0), do: {:error, :division_by_zero}
  defp apply_op(:/, left, right), do: {:ok, left / right}
  defp apply_op(:div, _left, 0), do: {:error, :division_by_zero}
  defp apply_op(:div, left, right), do: {:ok, div(left, right)}
  defp apply_op(:rem, _left, 0), do: {:error, :division_by_zero}
  defp apply_op(:rem, left, right), do: {:ok, rem(left, right)}
end
