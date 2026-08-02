defmodule Imp.OperationalSafetyErrorTest do
  use ExUnit.Case, async: true

  alias Imp.OperationalSafetyError

  defmodule Program do
    defstruct [:handler]
    def call(%__MODULE__{handler: handler}, inputs), do: handler.(inputs)
  end

  test "improper provider diagnostics remain ordinary when they contain no safety guard" do
    diagnostic = [{:path, [0, 1]} | "messages"]

    assert OperationalSafetyError.find(diagnostic) == nil
    assert OperationalSafetyError.raise_if_present!(diagnostic) == :ok
  end

  test "improper provider diagnostics still surface a nested safety guard" do
    guard = OperationalSafetyError.exception(kind: :budget, message: "bounded")
    diagnostic = [{:ordinary, :failure}, %{nested: [guard | "messages"]} | "tail"]

    assert OperationalSafetyError.find(diagnostic) == guard

    assert_raise OperationalSafetyError, "bounded", fn ->
      OperationalSafetyError.raise_if_present!(diagnostic)
    end
  end

  test "Evaluate retains an improper ordinary provider diagnostic as a failed row" do
    diagnostic = [{:adapter, :missing_output_fields} | "messages"]
    program = %Program{handler: fn _inputs -> {:error, diagnostic} end}

    row =
      Imp.example(question: "2+2?", answer: "4")
      |> Imp.Example.with_inputs(:question)

    result =
      [row]
      |> Imp.Evaluate.new(Imp.Metrics.exact_match(:answer), max_errors: :infinity)
      |> Imp.Evaluate.run(program)

    assert result.score == 0.0
    assert [%{error: ^diagnostic, prediction: nil}] = result.rows
    assert [%{reason: ^diagnostic}] = result.errors
  end
end
