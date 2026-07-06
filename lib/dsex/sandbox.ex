defmodule DSEx.Sandbox do
  @moduledoc """
  BEAM-safe expression sandbox for Program-of-Thought style code.

  This is not an arbitrary Elixir evaluator. It accepts a small expression
  language over literals and variables, and rejects arbitrary calls, aliases,
  atoms, and remote execution.
  """

  @allowed_ops [:+, :-, :*, :/, :div, :rem, :==, :!=, :<, :<=, :>, :>=, :and, :or, :in, :++]
  @safe_local_functions [:length, :hd, :tl]
  @safe_string_functions [:length, :downcase, :upcase, :trim, :contains?, :split]

  def eval(expression, vars \\ %{}) when is_binary(expression) do
    with {:ok, ast} <- Code.string_to_quoted(expression),
         {:ok, value} <- eval_ast(ast, Map.new(vars)) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_expression, other}}
    end
  end

  defp eval_ast(value, _vars)
       when is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value}

  defp eval_ast(values, vars) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case eval_ast(value, vars) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp eval_ast({name, _meta, nil}, vars) when is_atom(name) do
    case Map.fetch(vars, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_variable, name}}
    end
  end

  defp eval_ast({:if, _meta, [condition, [do: then_ast, else: else_ast]]}, vars) do
    with {:ok, condition} <- eval_ast(condition, vars) do
      eval_ast(if(condition, do: then_ast, else: else_ast), vars)
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

  defp eval_ast({name, _meta, args}, vars)
       when name in @safe_local_functions and is_list(args) do
    call_safe(name, args, vars)
  end

  defp eval_ast({{:., _meta, [{:__aliases__, _, [:String]}, name]}, _call_meta, args}, vars)
       when name in @safe_string_functions and is_list(args) do
    call_safe({String, name}, args, vars)
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
  defp apply_op(:==, left, right), do: {:ok, left == right}
  defp apply_op(:!=, left, right), do: {:ok, left != right}
  defp apply_op(:<, left, right), do: {:ok, left < right}
  defp apply_op(:<=, left, right), do: {:ok, left <= right}
  defp apply_op(:>, left, right), do: {:ok, left > right}
  defp apply_op(:>=, left, right), do: {:ok, left >= right}

  defp apply_op(:and, left, right) when is_boolean(left) and is_boolean(right),
    do: {:ok, left and right}

  defp apply_op(:or, left, right) when is_boolean(left) and is_boolean(right),
    do: {:ok, left or right}

  defp apply_op(:in, left, right) when is_list(right), do: {:ok, left in right}
  defp apply_op(:++, left, right) when is_list(left) and is_list(right), do: {:ok, left ++ right}

  defp apply_op(:++, left, right) when is_binary(left) and is_binary(right),
    do: {:ok, left <> right}

  defp apply_op(op, left, right), do: {:error, {:invalid_operands, op, left, right}}

  defp call_safe(name, args, vars) do
    with {:ok, args} <- eval_ast(args, vars), do: apply_safe(name, args)
  end

  defp apply_safe(:length, [value]) when is_list(value), do: {:ok, length(value)}
  defp apply_safe(:length, [value]) when is_binary(value), do: {:ok, String.length(value)}
  defp apply_safe(:hd, [[head | _tail]]), do: {:ok, head}
  defp apply_safe(:tl, [[_head | tail]]), do: {:ok, tail}

  defp apply_safe({String, :length}, [value]) when is_binary(value),
    do: {:ok, String.length(value)}

  defp apply_safe({String, :downcase}, [value]) when is_binary(value),
    do: {:ok, String.downcase(value)}

  defp apply_safe({String, :upcase}, [value]) when is_binary(value),
    do: {:ok, String.upcase(value)}

  defp apply_safe({String, :trim}, [value]) when is_binary(value), do: {:ok, String.trim(value)}

  defp apply_safe({String, :contains?}, [value, needle]) when is_binary(value),
    do: {:ok, String.contains?(value, needle)}

  defp apply_safe({String, :split}, [value]) when is_binary(value), do: {:ok, String.split(value)}
  defp apply_safe(name, args), do: {:error, {:unsafe_call, name, args}}
end
