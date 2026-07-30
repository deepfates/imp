defmodule Imp.ProgramParametersTest do
  use ExUnit.Case, async: true

  alias Imp.ProgramParameters

  defmodule TwoStage do
    @behaviour Imp.Module
    defstruct [:first, :second]

    @impl true
    def call(_program, _inputs), do: {:ok, Imp.Prediction.new(%{})}

    @impl true
    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    @impl true
    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}
  end

  defmodule DuplicateNames do
    defstruct [:predictor]
    def optimizer_predictors(program), do: [same: program.predictor, same: program.predictor]

    def update_optimizer_predictor(program, :same, update),
      do: %{program | predictor: update.(program.predictor)}
  end

  defmodule MissingUpdater do
    defstruct [:predictor]
    def optimizer_predictors(program), do: [main: program.predictor]
  end

  defmodule MissingPredictors do
    defstruct [:predictor]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | predictor: update.(program.predictor)}
  end

  defmodule WrongUpdateStruct do
    defstruct [:predictor]
    def optimizer_predictors(program), do: [main: program.predictor]
    def update_optimizer_predictor(_program, :main, update), do: update.(Imp.predict("x -> y"))
  end

  test "built-in wrappers expose a stable main predictor lens" do
    program = Imp.chain_of_thought("question -> answer")

    assert [%{name: :main}] = ProgramParameters.predictors(program)

    updated = ProgramParameters.put_instruction(program, :main, "Answer exactly.")

    assert hd(ProgramParameters.predictors(updated)).predictor.signature.instructions ==
             "Answer exactly."
  end

  test "custom programs expose independently mutable named predictors" do
    program = %TwoStage{
      first: Imp.predict("question -> hint"),
      second: Imp.predict("question, hint -> answer")
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
      ProgramParameters.predictors(%DuplicateNames{predictor: Imp.predict("x -> y")})
    end
  end

  test "custom multi-stage programs must implement the paired Imp.Module callbacks" do
    predictor = Imp.predict("x -> y")

    assert_raise ArgumentError,
                 ~r/missing the paired Imp.Module update_optimizer_predictor\/3/,
                 fn ->
                   ProgramParameters.predictors(%MissingUpdater{predictor: predictor})
                 end

    assert_raise ArgumentError, ~r/missing the paired Imp.Module optimizer_predictors\/1/, fn ->
      ProgramParameters.predictors(%MissingPredictors{predictor: predictor})
    end
  end

  test "custom predictor updates retain the consumer program struct and named lens" do
    assert_raise ArgumentError, ~r/must return the same program struct/, fn ->
      ProgramParameters.put_instruction(
        %WrongUpdateStruct{predictor: Imp.predict("x -> y")},
        :main,
        "Changed"
      )
    end
  end
end
