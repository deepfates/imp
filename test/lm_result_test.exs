defmodule DSEx.LM.ResultTest do
  use ExUnit.Case, async: true

  alias DSEx.LM.Result

  test "splits ordinary outputs without inventing metadata" do
    assert {:ok, "answer", %{}} = Result.split("answer")
    assert {:ok, %{answer: 42}, %{}} = Result.split(%{answer: 42})

    prediction = DSEx.Prediction.new(answer: "yes")
    assert {:ok, ^prediction, %{}} = Result.split(prediction)
  end

  test "splits atom and string provider envelopes" do
    assert {:ok, "answer", %{provider: "test"}} =
             Result.split(%{
               __dsex_lm_output__: "answer",
               __dsex_lm_metadata__: %{provider: "test"}
             })

    assert {:ok, %{"answer" => 42}, %{"provider" => "test"}} =
             Result.split(%{
               "__dsex_lm_output__" => %{"answer" => 42},
               "__dsex_lm_metadata__" => %{"provider" => "test"}
             })
  end

  test "unwrap preserves LM errors and rejects invalid result tuples" do
    assert {:ok, "answer"} =
             Result.unwrap(
               {:ok,
                %{
                  __dsex_lm_output__: "answer",
                  __dsex_lm_metadata__: %{provider: "test"}
                }}
             )

    assert {:error, :unavailable} = Result.unwrap({:error, :unavailable})
    assert {:error, {:invalid_lm_result, :invalid}} = Result.unwrap(:invalid)
  end

  test "rejects partial, mixed, extra-key, malformed, and nested envelopes" do
    invalid = [
      %{__dsex_lm_output__: "answer"},
      %{"__dsex_lm_metadata__" => %{}, __dsex_lm_output__: "answer"},
      %{__dsex_lm_output__: "answer", __dsex_lm_metadata__: %{}, extra: true},
      %{__dsex_lm_output__: "answer", __dsex_lm_metadata__: :invalid}
    ]

    for envelope <- invalid do
      assert {:error, {:invalid_lm_result_envelope, ^envelope}} = Result.split(envelope)
    end

    nested = %{
      __dsex_lm_output__: %{
        __dsex_lm_output__: "answer",
        __dsex_lm_metadata__: %{inner: true}
      },
      __dsex_lm_metadata__: %{outer: true}
    }

    assert {:error, {:nested_lm_result_envelope, _}} = Result.split(nested)
  end
end
