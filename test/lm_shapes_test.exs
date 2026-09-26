defmodule LMShapesTest do
  use ExUnit.Case, async: true

  defmodule ModuleLM do
    @behaviour Imp.LM

    @impl true
    def generate(lm, _messages, opts), do: {:ok, %{answer: inspect(lm), n: opts[:n]}}
  end

  test "an LM is a struct or a module, and generate/3 receives it first" do
    static = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
    assert {:ok, ^static} = Imp.LM.validate_lm(static)
    assert {:ok, %{answer: "ok"}} = Imp.LM.generate(static, [%{role: :user, content: "hi"}])

    assert {:ok, ModuleLM} = Imp.LM.validate_lm(ModuleLM)

    assert {:ok, %{answer: "LMShapesTest.ModuleLM", n: 2}} =
             Imp.LM.generate(ModuleLM, [%{role: :user, content: "hi"}], n: 2)
  end

  test "the %{module:, opts:} map and a bare function are not LMs" do
    map = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}
    fun = fn _messages, _opts -> {:ok, %{answer: "ok"}} end

    for lm <- [map, fun] do
      assert {:error, message} = Imp.LM.validate_lm(lm)
      assert message =~ "implementing Imp.LM generate/3"
      assert {:error, {:not_an_lm, ^lm}} = Imp.LM.generate(lm, [%{role: :user, content: "hi"}])
    end
  end

  test "a module with only the old generate/2 is not an LM" do
    defmodule OldShape do
      def generate(_messages, _opts), do: {:ok, %{answer: "old"}}
    end

    assert {:error, _message} = Imp.LM.validate_lm(OldShape)
    assert {:error, _message} = Imp.LM.validate_lm(42)
  end
end
