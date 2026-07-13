defmodule DSEx.ProgramParametersTest do
  use ExUnit.Case, async: true

  alias DSEx.ProgramParameters

  defmodule TwoStage do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}
  end

  defmodule DuplicateNames do
    defstruct [:predictor]
    def optimizer_predictors(program), do: [same: program.predictor, same: program.predictor]
  end

  test "built-in wrappers expose a stable main predictor lens" do
    program = DSEx.chain_of_thought("question -> answer")

    assert [%{name: :main}] = ProgramParameters.predictors(program)

    updated = ProgramParameters.put_instruction(program, :main, "Answer exactly.")

    assert hd(ProgramParameters.predictors(updated)).predictor.signature.instructions ==
             "Answer exactly."
  end

  test "custom programs expose independently mutable named predictors" do
    program = %TwoStage{
      first: DSEx.predict("question -> hint"),
      second: DSEx.predict("question, hint -> answer")
    }

    updated =
      program
      |> ProgramParameters.put_instruction(:first, "Produce a concise hint.")
      |> ProgramParameters.put_instruction(:second, "Use the hint to answer.")

    assert [first, second] = ProgramParameters.predictors(updated)
    assert first.predictor.signature.instructions == "Produce a concise hint."
    assert second.predictor.signature.instructions == "Use the hint to answer."
  end

  test "custom predictor names must be unique" do
    assert_raise ArgumentError, ~r/must be unique/, fn ->
      ProgramParameters.predictors(%DuplicateNames{predictor: DSEx.predict("x -> y")})
    end
  end
end
