defmodule LMDeprecatedShapesTest do
  # async: false because the once-per-VM deprecation gate is global state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    Imp.LM.reset_deprecation_warnings()
    on_exit(fn -> Imp.LM.reset_deprecation_warnings() end)
    :ok
  end

  test "the %{module:, opts:} LM shape still works but warns loudly once" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}

    log =
      capture_log(fn ->
        assert {:ok, ^lm} = Imp.LM.validate_lm(lm)
        assert {:ok, %{answer: "ok"}} = Imp.LM.generate(lm, [%{role: :user, content: "hi"}])
      end)

    assert log =~ "%{module: module, opts: keyword} LM shape is deprecated"

    # The gate is once per VM: a second use is quiet.
    quiet =
      capture_log(fn ->
        assert {:ok, ^lm} = Imp.LM.validate_lm(lm)
      end)

    refute quiet =~ "deprecated"
  end

  test "a bare arity-2 function LM still works but warns loudly once" do
    fun = fn _messages, _opts -> {:ok, %{answer: "ok"}} end

    log =
      capture_log(fn ->
        assert {:ok, _} = Imp.LM.validate_lm(fun)
        assert {:ok, %{answer: "ok"}} = Imp.LM.generate(fun, [%{role: :user, content: "hi"}])
      end)

    assert log =~ "bare arity-2 function as an LM is deprecated"
  end

  test "the blessed shapes stay quiet: module and struct" do
    log =
      capture_log(fn ->
        assert {:ok, Imp.LM.Static} = Imp.LM.validate_lm(Imp.LM.Static)

        static = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
        assert {:ok, ^static} = Imp.LM.validate_lm(static)

        assert {:ok, %{answer: "ok"}} =
                 Imp.LM.generate(static, [%{role: :user, content: "hi"}])
      end)

    refute log =~ "deprecated"
  end

  test "unsupported shapes get the collapsed error message" do
    assert {:error, "expected nil, an LM module, or an LM struct"} = Imp.LM.validate_lm(42)
  end
end
