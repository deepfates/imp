defmodule LiveProviderTest do
  use ExUnit.Case

  @tag :live
  test "OpenAI-compatible live provider completes a DSPy prediction" do
    api_key = System.get_env("OPENAI_API_KEY")
    model = System.get_env("OPENAI_MODEL") || "gpt-4o-mini"

    assert is_binary(api_key) and byte_size(api_key) > 0

    lm = DSPy.Clients.OpenAI.new(model, opts: [temperature: 0, max_completion_tokens: 20])
    program = DSPy.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             DSPy.Predict.Predict.call(program, %{
               question: "Reply with exactly this single word and no punctuation: pong"
             })

    answer =
      prediction
      |> DSPy.Prediction.get(:answer, "")
      |> to_string()
      |> String.downcase()

    assert String.contains?(answer, "pong")
  end
end
