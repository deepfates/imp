defmodule DSEx.Predict.RLM.ProjectedValueBudgetTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias DSEx.Predict.RLM.Interpreter

  test "projects string concatenation and replacement before constructing results" do
    interpreter = new_interpreter(100)
    left = String.duplicate("a", 70)
    right = String.duplicate("b", 70)

    assert_budget_error(interpreter, inspect(left) <> " <> " <> inspect(right), 100)

    source =
      "String.replace(" <>
        inspect(String.duplicate("a", 60)) <> ", \"a\", \"bbbb\")"

    assert_budget_error(interpreter, source, 100)
  end

  test "projects list concatenation before copying the left list" do
    interpreter = new_interpreter(100)
    left = inspect(Enum.to_list(1..60), limit: :infinity, charlists: :as_lists)
    right = inspect(Enum.to_list(61..120), limit: :infinity, charlists: :as_lists)

    assert_budget_error(interpreter, left <> " ++ " <> right, 100)
  end

  test "projects String.split list overhead before materializing all parts" do
    interpreter = new_interpreter(100)
    input = Enum.join(List.duplicate("a", 40), ",")

    assert_budget_error(interpreter, "String.split(#{inspect(input)}, \",\")", 100)

    interpreter = new_interpreter(250)

    assert {:ok, parts, _} =
             Interpreter.execute(interpreter, "String.split(#{inspect(input)}, \",\")")

    assert :erlang.external_size(parts) == 247
  end

  test "projects Enum.concat across known lists and ranges" do
    interpreter = new_interpreter(150)

    assert_budget_error(interpreter, "Enum.concat([1..100, 1..100])", 150)

    interpreter = new_interpreter(210)
    assert {:ok, values, _} = Interpreter.execute(interpreter, "Enum.concat([1..100, 1..100])")
    assert :erlang.external_size(values) == 204
  end

  test "checks each comprehension append against the projected result size" do
    interpreter = new_interpreter(100, max_steps: 1_000)

    assert {:error, {:value_budget_exceeded, projected, 100}, interpreter} =
             Interpreter.execute(interpreter, "for x <- 1..100, do: x")

    assert projected > 100
    refute Map.has_key?(interpreter.vars, :x)

    interpreter = new_interpreter(110, max_steps: 1_000)
    assert {:ok, values, _} = Interpreter.execute(interpreter, "for x <- 1..100, do: x")
    assert values == Enum.to_list(1..100)
    assert :erlang.external_size(values) == 104
  end

  test "uses integer bit lengths to reject expanding multiplication" do
    integer = 1 <<< 800
    interpreter = new_interpreter(150, vars: %{integer: integer})

    assert_budget_error(interpreter, "integer * integer", 150)
  end

  test "preserves successful operation results and unsupported string multiplication" do
    interpreter = new_interpreter(1_000, max_steps: 1_000)

    assert {:ok, "abcd", _} = Interpreter.execute(interpreter, ~S|"ab" <> "cd"|)
    assert {:ok, [1, 2, 3], _} = Interpreter.execute(interpreter, "[1] ++ [2, 3]")

    assert {:ok, [1, 2, 3, 4], _} =
             Interpreter.execute(interpreter, "Enum.concat([1..2, [3, 4]])")

    assert {:ok, [1, 2, 3], _} = Interpreter.execute(interpreter, "for x <- 1..3, do: x")

    assert {:error, {:invalid_operands, :*}, _} =
             Interpreter.execute(interpreter, ~S|"ab" * 2|)
  end

  defp new_interpreter(max_value_bytes, opts \\ []) do
    vars = Keyword.get(opts, :vars, %{})
    options = opts |> Keyword.delete(:vars) |> Keyword.put(:max_value_bytes, max_value_bytes)
    Interpreter.new(vars, %{}, nil, options)
  end

  defp assert_budget_error(interpreter, source, max_value_bytes) do
    assert {:error, {:value_budget_exceeded, projected, ^max_value_bytes}, _} =
             Interpreter.execute(interpreter, source)

    assert projected > max_value_bytes
  end
end
