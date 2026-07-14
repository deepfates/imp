defmodule Imp.Optimizer.Playbook.EquationSearch do
  @moduledoc false

  @operators ["+", "-", "*", "/"]
  @max_input_bytes 256
  @max_numbers 8
  @max_abs_value 10_000_000

  @doc false
  def solve_tool(arguments) when is_map(arguments) do
    equation = Map.get(arguments, :equation, Map.get(arguments, "equation"))
    numbers = Map.get(arguments, :numbers, Map.get(arguments, "numbers"))
    target = Map.get(arguments, :target, Map.get(arguments, "target"))

    result =
      cond do
        is_binary(equation) -> solve(equation)
        is_list(numbers) and is_integer(target) -> solve_parts(numbers, target)
        true -> {:error, :missing_equation}
      end

    case result do
      {:ok, answer} -> answer
      {:error, reason} -> {:error, reason}
    end
  end

  def solve_tool(_arguments), do: {:error, :invalid_tool_arguments}

  @doc false
  def solve(input) when is_binary(input) do
    with :ok <- validate_input_bound(input),
         {:ok, numbers, target} <- input_parts(input),
         do: solve_parts(numbers, target)
  end

  def solve(_input), do: {:error, :invalid_equation_type}

  @doc false
  def solve_parts(numbers, target) when is_list(numbers) and is_integer(target) do
    with :ok <- validate_search_bound(numbers, target) do
      numbers
      |> operator_tuples(length(numbers) - 1)
      |> Enum.find_value({:error, :no_solution}, fn operators ->
        case evaluate_fraction(numbers, operators) do
          {:ok, {^target, 1}} -> {:ok, render(numbers, operators, target)}
          _ -> false
        end
      end)
    end
  end

  def solve_parts(_numbers, _target), do: {:error, :invalid_search_terms}

  @doc false
  def validate(input, answer, target_value)
      when is_binary(input) and is_binary(answer) and is_integer(target_value) do
    with {:ok, input_numbers, input_target} <- input_parts(input),
         true <- input_target == target_value,
         {:ok, answer_numbers, operators, rhs} <- answer_parts(answer),
         true <- input_numbers == answer_numbers,
         true <- rhs == target_value,
         {:ok, value} <- evaluate_fraction(answer_numbers, operators),
         true <- value == {target_value, 1} do
      :ok
    else
      false -> {:error, :equation_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def validate(_input, _answer, _target), do: {:error, :invalid_equation_types}

  defp input_parts(input) do
    case Regex.run(~r/^\s*(.*?)\s*=\s*(-?\d+)\s*$/, input) do
      [_, lhs, rhs] ->
        numbers = Regex.scan(~r/-?\d+/, lhs) |> List.flatten() |> Enum.map(&String.to_integer/1)

        if numbers == [],
          do: {:error, :input_has_no_numbers},
          else: {:ok, numbers, String.to_integer(rhs)}

      _ ->
        {:error, :invalid_input_equation}
    end
  end

  defp answer_parts(answer) do
    answer =
      answer
      |> String.trim()
      |> String.replace_prefix("```", "")
      |> String.replace_suffix("```", "")
      |> String.trim()

    case Regex.run(~r/^\s*(-?\d+(?:\s*[+\-*\/]\s*-?\d+)*)\s*=\s*(-?\d+)\s*$/, answer) do
      [_, lhs, rhs] ->
        number_spans = Regex.scan(~r/-?\d+/, lhs, return: :index) |> List.flatten()

        numbers =
          Enum.map(number_spans, fn {start, length} ->
            lhs |> binary_part(start, length) |> String.to_integer()
          end)

        operators =
          number_spans
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [{left_start, left_length}, {right_start, _right_length}] ->
            lhs
            |> binary_part(left_start + left_length, right_start - left_start - left_length)
            |> String.trim()
          end)

        if length(operators) == length(numbers) - 1 and
             Enum.all?(operators, &(&1 in @operators)),
           do: {:ok, numbers, operators, String.to_integer(rhs)},
           else: {:error, :operator_count_mismatch}

      _ ->
        {:error, :invalid_answer_equation}
    end
  end

  defp operator_tuples(_numbers, 0), do: [[]]

  defp operator_tuples(numbers, count) when count > 0 do
    for operator <- @operators,
        suffix <- operator_tuples(numbers, count - 1),
        do: [operator | suffix]
  end

  defp evaluate_fraction([first | rest], operators) do
    Enum.zip(operators, rest)
    |> Enum.reduce_while({:ok, [{first, 1}], []}, fn
      {operator, value}, {:ok, [current | remaining], sums} when operator in ["*", "/"] ->
        case fraction_op(current, {value, 1}, operator) do
          {:ok, product} -> {:cont, {:ok, [product | remaining], sums}}
          error -> {:halt, error}
        end

      {operator, value}, {:ok, current_terms, sums} when operator in ["+", "-"] ->
        signed = if operator == "+", do: {value, 1}, else: {-value, 1}
        {:cont, {:ok, [signed], Enum.reverse(current_terms) ++ sums}}
    end)
    |> case do
      {:ok, current, sums} ->
        Enum.reduce(Enum.reverse(current) ++ sums, {:ok, {0, 1}}, fn value, {:ok, total} ->
          fraction_op(total, value, "+")
        end)

      error ->
        error
    end
  end

  defp fraction_op({left_n, left_d}, {right_n, right_d}, operator) do
    case operator do
      "+" -> normalize_fraction(left_n * right_d + right_n * left_d, left_d * right_d)
      "*" -> normalize_fraction(left_n * right_n, left_d * right_d)
      "/" when right_n != 0 -> normalize_fraction(left_n * right_d, left_d * right_n)
      "/" -> {:error, :division_by_zero}
    end
  end

  defp normalize_fraction(numerator, denominator) when denominator != 0 do
    sign = if denominator < 0, do: -1, else: 1
    divisor = Integer.gcd(abs(numerator), abs(denominator))
    {:ok, {div(numerator * sign, divisor), div(abs(denominator), divisor)}}
  end

  defp render([first | rest], operators, target) do
    lhs =
      Enum.zip(operators, rest)
      |> Enum.reduce(Integer.to_string(first), fn {operator, number}, acc ->
        acc <> " " <> operator <> " " <> Integer.to_string(number)
      end)

    lhs <> " = " <> Integer.to_string(target)
  end

  defp validate_input_bound(input) do
    if byte_size(input) <= @max_input_bytes,
      do: :ok,
      else: {:error, :search_bound_exceeded}
  end

  defp validate_search_bound(numbers, target) do
    bounded_values? =
      numbers != [] and
        Enum.all?([target | numbers], &(is_integer(&1) and abs(&1) <= @max_abs_value))

    if length(numbers) <= @max_numbers and bounded_values?,
      do: :ok,
      else: {:error, :search_bound_exceeded}
  end
end
