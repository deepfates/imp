defmodule Imp.ConstructorOptionsTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(&Imp.Settings.reset/0)
  end

  describe "Imp.predict/2" do
    test "refuses an unknown option" do
      error =
        assert_raise ArgumentError, fn -> Imp.predict("question -> answer", adaptor: :chat) end

      assert Exception.message(error) =~ "Imp.Predict.Predict.new/2"
      assert Exception.message(error) =~ "unknown options [:adaptor]"
    end

    test "refuses a top-level request option and names config:" do
      error =
        assert_raise ArgumentError, fn ->
          Imp.predict("question -> answer", temperature: 0, max_tokens: 10)
        end

      assert Exception.message(error) =~ "under config:"
      assert Exception.message(error) =~ "config: [temperature: 0, max_tokens: 10]"
    end

    test "keeps request options given under config:" do
      program = Imp.predict("question -> answer", config: [temperature: 0, n: 2])
      assert program.config == [temperature: 0, n: 2]
    end
  end

  describe "Imp.chain_of_thought/2" do
    test "refuses an unknown option" do
      error =
        assert_raise ArgumentError, fn ->
          Imp.chain_of_thought("question -> answer", rationale: :why)
        end

      assert Exception.message(error) =~ "Imp.Predict.ChainOfThought.new/2"
      assert Exception.message(error) =~ "unknown options [:rationale]"
    end

    test "refuses a top-level request option and names config:" do
      error =
        assert_raise ArgumentError, fn ->
          Imp.chain_of_thought("question -> answer", n: 3)
        end

      assert Exception.message(error) =~ "config: [n: 3]"
    end

    test "takes its own options beside Predict's" do
      program =
        Imp.chain_of_thought("question -> answer",
          rationale_field_type: :reasoning,
          config: [temperature: 0]
        )

      assert program.predict.config == [temperature: 0]
      assert hd(program.predict.signature.outputs).type == :reasoning
    end

    test "an explicit nil rationale_field means the default reasoning field" do
      program = Imp.chain_of_thought("question -> answer", rationale_field: nil)
      assert hd(program.predict.signature.outputs).name == :reasoning
    end
  end

  describe "Imp.configure/1" do
    test "refuses an unknown setting and stores nothing" do
      error =
        assert_raise ArgumentError, fn ->
          Imp.configure(lm: :configured, temprature: 0)
        end

      assert Exception.message(error) =~ "Imp.configure/1"
      assert Exception.message(error) =~ "unknown settings [:temprature]"
      refute Map.has_key?(Imp.settings(), :temprature)
      assert Imp.settings().lm == nil
    end

    test "refuses an unknown string key" do
      assert_raise ArgumentError, ~r/unknown settings \["temprature"\]/, fn ->
        Imp.configure(%{"lm" => :configured, "temprature" => 0})
      end
    end

    test "Imp.context/2 still carries settings of the caller's own" do
      assert Imp.context([request_id: "r-1"], fn -> Imp.settings().request_id end) == "r-1"
    end
  end
end
